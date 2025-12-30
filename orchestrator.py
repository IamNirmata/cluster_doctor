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

# Add result_management to sys.path
sys.path.append(os.path.join(os.path.dirname(__file__), 'result_management'))
try:
    import result_manager
except ImportError:
    print("Error: Could not import result_manager. Make sure result_management/result_manager.py exists.")
    sys.exit(1)

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
        conn = result_manager.connect(DB_PATH)
        result_manager.init_db(conn)
        rows = result_manager.query_latest_status(conn)
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

    conn = result_manager.connect(DB_PATH)
    result_manager.init_db(conn)
    
    # Get existing runs to avoid duplicates (simple cache)
    # For a large DB, this is inefficient. Better to query max timestamp per node/test.
    # But result_manager doesn't expose that easily without raw SQL.
    # We'll use query_latest_status to get the high water mark.
    latest_status = { (r['node'], r['test']): r['latest_timestamp'] for r in result_manager.query_latest_status(conn) }
    
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
                result_manager.insert_run(conn, node, test_name, timestamp, result)
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

def submit_job(node: str):
    """
    Submit job for the node.
    """
    logger.info(f"Submitting job for node {node}...")
    # TODO: Implement actual job submission logic
    # This might involve creating a yaml file and running kubectl apply
    # For now, we'll simulate it.
    time.sleep(1) # Simulate submission time
    return True

def main():
    logger.info("Starting Cluster Doctor Orchestrator")
    
    while True:
        try:
            # 2) Get Cluster status
            free_nodes = get_free_nodes()
            
            # 3) Fetch results metadata
            latest_results = get_latest_results()
            
            # 3) Build priority queue
            node_queue = build_priority_queue(free_nodes, latest_results)
            
            # 4) Job submission
            # We need to manage concurrent jobs.
            # For simplicity in this step, let's just print what we would do.
            
            active_jobs = 0 # Placeholder
            
            for node in node_queue:
                if active_jobs < MAX_CONCURRENT_JOBS:
                    if submit_job(node):
                        active_jobs += 1
                else:
                    break
            
            logger.info(f"Sleeping for {NODE_CHECK_INTERVAL_MINS} minutes...")
            time.sleep(NODE_CHECK_INTERVAL_MINS * 60)
            
        except KeyboardInterrupt:
            logger.info("Stopping orchestrator...")
            break
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
            time.sleep(60) # Wait a bit before retrying

if __name__ == "__main__":
    main()
