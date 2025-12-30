#!/usr/bin/env python3
import os
import sys
import time
import logging
import subprocess
import datetime
import sqlite3
from typing import List, Dict, Set, Tuple
import queue

# Configuration
CLUSTER_MANAGEMENT_DIR = os.path.join(os.path.dirname(__file__), 'cluster_management')
FREE_NODES_SCRIPT = os.path.join(CLUSTER_MANAGEMENT_DIR, 'freenodes.sh')
FREE_NODES_FILE = os.path.join(CLUSTER_MANAGEMENT_DIR, 'free.txt')
DB_PATH = os.environ.get('CV_DB_PATH', './validation.db')
LOGS_DIR = os.environ.get('CV_LOGS_DIR', './logs')

# Thresholds
MAX_CONCURRENT_JOBS = 2
MAX_QUEUE_TIME_MINS = 30
JOB_PENDING_TIMEOUT_MINS = 20
NODE_CHECK_INTERVAL_MINS = 5
TEST_AGE_THRESHOLD_DAYS = 7

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('orchestrator.log')
    ]
)
logger = logging.getLogger(__name__)

# -----------------------
# DB Helpers
# -----------------------
def connect_db(db_path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn

def init_db(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()
    cur.execute("PRAGMA journal_mode=WAL;")
    cur.execute("PRAGMA synchronous=NORMAL;")
    cur.execute("""
      CREATE TABLE IF NOT EXISTS runs (
        node      TEXT NOT NULL,
        test      TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        result    TEXT NOT NULL CHECK (result IN ('pass','fail','incomplete'))
      );
    """)
    cur.execute("""
      CREATE INDEX IF NOT EXISTS idx_runs_node_test_ts
      ON runs(node, test, timestamp);
    """)
    cur.execute("""
      CREATE VIEW IF NOT EXISTS latest_status AS
      SELECT r.node, r.test, r.timestamp AS latest_timestamp, r.result
      FROM runs r
      JOIN (
        SELECT node, test, MAX(timestamp) AS max_ts
        FROM runs
        GROUP BY node, test
      ) x
      ON r.node=x.node AND r.test=x.test AND r.timestamp=x.max_ts;
    """)
    conn.commit()

def insert_run(conn: sqlite3.Connection, node: str, test: str, epoch_ts: int, result: str) -> None:
    conn.execute(
        "INSERT INTO runs(node, test, timestamp, result) VALUES (?,?,?,?)",
        (node, test, epoch_ts, result),
    )
    conn.commit()

def query_latest_status(conn: sqlite3.Connection) -> List[sqlite3.Row]:
    return conn.execute(
        "SELECT node, test, latest_timestamp, result FROM latest_status ORDER BY node, test"
    ).fetchall()

def get_free_nodes() -> Set[str]:
    """
    Get free nodes from cluster manager using freenodes.sh
    """
    try:
        # Run freenodes.sh to update the free nodes file
        cmd = [FREE_NODES_SCRIPT, '-o', FREE_NODES_FILE]
        subprocess.run(cmd, check=True, capture_output=True)
        
        if not os.path.exists(FREE_NODES_FILE):
            logger.warning(f"Free nodes file {FREE_NODES_FILE} not found.")
            return set()
            
        with open(FREE_NODES_FILE, 'r') as f:
            nodes = {line.strip() for line in f if line.strip()}
        
        logger.info(f"Found {len(nodes)} free nodes.")
        return nodes
    except subprocess.CalledProcessError as e:
        logger.error(f"Error running freenodes.sh: {e}")
        return set()
    except Exception as e:
        logger.error(f"Error getting free nodes: {e}")
        return set()

def get_latest_results() -> Dict[str, Dict]:
    """
    Fetch latest test results metadata from status metadata view.
    Returns a dictionary: {node_name: {'timestamp': int, 'result': str, 'test': str}}
    """
    try:
        conn = connect_db(DB_PATH)
        init_db(conn)
        rows = query_latest_status(conn)
        conn.close()
        
        results = {}
        for row in rows:
            # Assuming one test type for now or taking the latest of any test
            # If multiple tests exist, we might need to handle them differently.
            # For now, let's store by node.
            node = row['node']
            results[node] = {
                'timestamp': row['latest_timestamp'],
                'result': row['result'],
                'test': row['test']
            }
        return results
    except Exception as e:
        logger.error(f"Error fetching results: {e}")
        return {}

def fetch_and_update_results():
    """
    Scan logs directory for new results and update the database.
    """
    logger.info("Fetching and updating results from logs...")
    if not os.path.exists(LOGS_DIR):
        logger.warning(f"Logs directory {LOGS_DIR} does not exist.")
        return

    conn = connect_db(DB_PATH)
    init_db(conn)
    
    # Get existing runs to avoid duplicates (simple cache)
    # For a large DB, this is inefficient. Better to query max timestamp per node/test.
    # But result_manager doesn't expose that easily without raw SQL.
    # We'll use query_latest_status to get the high water mark.
    latest_status = { (r['node'], r['test']): r['latest_timestamp'] for r in query_latest_status(conn) }
    
    # Walk through the logs directory
    # Structure: LOGS_DIR / TestCategory / Node_XXX / LogFile
    for root, dirs, files in os.walk(LOGS_DIR):
        for file in files:
            if not file.endswith('.log'):
                continue
                
            # Example filename: Storage_node001_timestamp1.log
            # We need to parse this. Let's assume: TestName_NodeName_Timestamp.log
            # Or use the directory structure.
            # Parent dir: Node_XXX
            # Grandparent dir: TestCategory
            
            path_parts = root.split(os.sep)
            if len(path_parts) < 2:
                continue
                
            node_dir = path_parts[-1] # Node_001
            test_category = path_parts[-2] # Storage
            
            # Extract node name from directory or filename
            # Let's assume node_dir is "Node_001" -> node "001"
            if node_dir.lower().startswith("node_"):
                node = node_dir[5:]
            else:
                node = node_dir
                
            # Extract timestamp from filename
            # Storage_node001_1234567890.log
            try:
                base_name = os.path.splitext(file)[0]
                parts = base_name.split('_')
                timestamp_str = parts[-1]
                timestamp = int(timestamp_str)
            except ValueError:
                logger.warning(f"Could not parse timestamp from filename: {file}")
                continue
                
            test_name = test_category
            
            # Check if we already have this result or newer
            if (node, test_name) in latest_status:
                if timestamp <= latest_status[(node, test_name)]:
                    continue
            
            # Read result from file
            file_path = os.path.join(root, file)
            result = "incomplete"
            try:
                with open(file_path, 'r') as f:
                    content = f.read().lower()
                    if "pass" in content:
                        result = "pass"
                    elif "fail" in content:
                        result = "fail"
            except Exception as e:
                logger.error(f"Error reading log file {file_path}: {e}")
                continue
                
            # Insert into DB
            try:
                logger.info(f"Adding new result: Node={node}, Test={test_name}, TS={timestamp}, Result={result}")
                insert_run(conn, node, test_name, timestamp, result)
                # Update local cache
                latest_status[(node, test_name)] = timestamp
            except Exception as e:
                logger.error(f"Error inserting run into DB: {e}")

    conn.close()

def build_priority_queue(free_nodes: Set[str], latest_results: Dict[str, Dict]) -> List[str]:
    """
    Build priority queue of nodes to test.
    """
    priority_list = []
    current_time = int(time.time())
    threshold_seconds = TEST_AGE_THRESHOLD_DAYS * 24 * 3600
    
    for node in free_nodes:
        if node not in latest_results:
            # Never tested, highest priority (or treat as very old)
            # We can use a very old timestamp to represent "never tested"
            priority_list.append((float('inf'), node)) # Higher score = higher priority? No, let's use delta.
            # README: "Nodes with shorter threshold delta have higher priority"
            # Wait, "shorter threshold delta"? 
            # If threshold is 7 days.
            # Node A tested 8 days ago. Delta = 1 day.
            # Node B tested 100 days ago. Delta = 93 days.
            # Usually, the one tested longest ago should have higher priority.
            # But "shorter threshold delta" might mean something else.
            # Let's assume: Older test = Higher priority.
            # So we sort by timestamp ascending (older first).
            # For never tested, we can use 0.
            pass
        else:
            last_ts = latest_results[node]['timestamp']
            age = current_time - last_ts
            if age > threshold_seconds:
                priority_list.append((last_ts, node))
    
    # Add never tested nodes
    never_tested = [node for node in free_nodes if node not in latest_results]
    
    # Sort: Never tested first, then by timestamp (oldest first)
    # We can assign timestamp 0 to never tested to make them come first
    final_queue = []
    for node in never_tested:
        final_queue.append(node)
        
    # Sort the rest by timestamp
    priority_list.sort(key=lambda x: x[0])
    for _, node in priority_list:
        final_queue.append(node)
        
    logger.info(f"Priority queue built with {len(final_queue)} nodes.")
    return final_queue

def submit_job(node: str) -> str:
    """
    Submit job for the node. Returns job ID.
    """
    logger.info(f"Submitting job for node {node}...")
    # TODO: Implement actual job submission logic
    # This might involve creating a yaml file and running kubectl apply
    # For now, we'll simulate it.
    job_id = f"job-{node}-{int(time.time())}"
    time.sleep(1) # Simulate submission time
    return job_id

def cancel_job(node: str, job_id: str):
    """
    Cancel the job for the node.
    """
    logger.info(f"Cancelling job {job_id} for node {node}...")
    # TODO: Implement actual job cancellation logic (e.g., kubectl delete)
    pass

def check_job_status(node: str, job_id: str) -> str:
    """
    Check status of the job. Returns 'running', 'completed', 'failed', 'pending'.
    """
    # TODO: Implement actual status check
    # For simulation, let's say it completes after 10 seconds
    # In real life, we might check kubectl get pods or similar
    import random
    if random.random() < 0.1:
        return 'completed'
    return 'running'

def main():
    logger.info("Starting Cluster Doctor Orchestrator")
    
    active_jobs: Dict[str, Dict] = {} # node -> {'job_id': str, 'submitted_at': float}
    
    while True:
        try:
            logger.info("--- Starting new orchestration cycle ---")
            current_time = time.time()
            
            # 5) Fetch results (and update DB)
            logger.info("Phase 1: Fetching and updating results...")
            fetch_and_update_results()
            
            # Check active jobs
            logger.info(f"Phase 2: Checking active jobs (Count: {len(active_jobs)})...")
            nodes_to_remove = []
            for node, job_info in active_jobs.items():
                job_id = job_info['job_id']
                submitted_at = job_info['submitted_at']
                
                # Check timeouts
                duration_mins = (current_time - submitted_at) / 60
                if duration_mins > MAX_QUEUE_TIME_MINS:
                    logger.warning(f"Job {job_id} for node {node} timed out (queue time). Cancelling.")
                    cancel_job(node, job_id)
                    nodes_to_remove.append(node)
                    continue
                
                status = check_job_status(node, job_id)
                logger.info(f"  Node {node}: Job {job_id} status is {status}")
                if status in ['completed', 'failed']:
                    logger.info(f"Job {job_id} for node {node} finished with status {status}.")
                    nodes_to_remove.append(node)
                
                # TODO: Check pending timeout if we can distinguish pending vs running
            
            for node in nodes_to_remove:
                del active_jobs[node]
            
            # 2) Get Cluster status
            logger.info("Phase 3: Getting cluster status (free nodes)...")
            free_nodes = get_free_nodes()
            
            # 3) Fetch results metadata (refresh)
            logger.info("Phase 4: Fetching latest results metadata...")
            latest_results = get_latest_results()
            
            # 3) Build priority queue
            logger.info("Phase 5: Building priority queue...")
            # Filter out nodes that already have active jobs
            available_nodes = {n for n in free_nodes if n not in active_jobs}
            node_queue = build_priority_queue(available_nodes, latest_results)
            
            # 4) Job submission
            logger.info("Phase 6: Job submission...")
            free_slots = MAX_CONCURRENT_JOBS - len(active_jobs)
            
            if free_slots > 0 and node_queue:
                logger.info(f"Found {free_slots} free slots. Queue length: {len(node_queue)}")
                for node in node_queue:
                    if free_slots <= 0:
                        break
                    
                    try:
                        job_id = submit_job(node)
                        active_jobs[node] = {
                            'job_id': job_id,
                            'submitted_at': time.time()
                        }
                        free_slots -= 1
                    except Exception as e:
                        logger.error(f"Failed to submit job for node {node}: {e}")
            else:
                logger.info(f"No free slots or empty queue. Active jobs: {len(active_jobs)}")
            
            logger.info(f"Cycle complete. Sleeping for {NODE_CHECK_INTERVAL_MINS} minutes...")
            time.sleep(NODE_CHECK_INTERVAL_MINS * 60)
            
        except KeyboardInterrupt:
            logger.info("Stopping orchestrator...")
            break
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
            time.sleep(60) # Wait a bit before retrying

if __name__ == "__main__":
    main()
