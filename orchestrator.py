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
