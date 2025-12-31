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

class ClusterDoctorOrchestrator:
    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path
        self.conn = None
        self.job_queue = queue.PriorityQueue()
        self.running_jobs = {}  # job_id -> (node, start_time)

    def connect_db(self) -> sqlite3.Connection:
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        return conn

    def init_db(self) -> None:
        """Initialize the database with required tables and views."""
        if not self.conn:
            self.conn = self.connect_db()
        
        cur = self.conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL;")
        cur.execute("PRAGMA synchronous=NORMAL;")
        
        # Create runs table with Unix timestamp
        cur.execute("""
            CREATE TABLE IF NOT EXISTS runs (
                node TEXT NOT NULL,
                test TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                result TEXT NOT NULL CHECK (result IN ('pass','fail','incomplete'))
            );
        """)
        
        cur.execute("CREATE INDEX IF NOT EXISTS idx_runs_node_test_ts ON runs(node, test, timestamp);")
        
        # Create latest_status view
        cur.execute("""
            CREATE VIEW IF NOT EXISTS latest_status AS 
            SELECT r.node, r.test, r.timestamp AS latest_timestamp, r.result 
            FROM runs r 
            JOIN (
                SELECT node, test, MAX(timestamp) AS max_ts 
                FROM runs 
                GROUP BY node, test
            ) x ON r.node=x.node AND r.test=x.test AND r.timestamp=x.max_ts;
        """)
        
        self.conn.commit()
        logger.info(f"Database initialized at {self.db_path}")

    def insert_run(self, node: str, test: str, result: str, timestamp: int = None) -> None:
        """Insert a run result into the database."""
        if timestamp is None:
            timestamp = int(time.time())
            
        if not self.conn:
            self.conn = self.connect_db()
            
        try:
            self.conn.execute(
                "INSERT INTO runs(node, test, timestamp, result) VALUES (?,?,?,?)", 
                (node, test, timestamp, result)
            )
            self.conn.commit()
            logger.info(f"Recorded run: {node} {test} {result} {timestamp}")
        except sqlite3.Error as e:
            logger.error(f"Failed to insert run: {e}")

    def get_free_nodes(self) -> List[str]:
        """Get list of free nodes using the shell script."""
        try:
            subprocess.run([FREE_NODES_SCRIPT], check=True, capture_output=True)
            if os.path.exists(FREE_NODES_FILE):
                with open(FREE_NODES_FILE, 'r') as f:
                    nodes = [line.strip() for line in f if line.strip()]
                return nodes
            return []
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to get free nodes: {e}")
            return []

    def run(self):
        """Main orchestration loop."""
        self.init_db()
        logger.info("Starting Cluster Doctor Orchestrator...")
        
        while True:
            try:
                free_nodes = self.get_free_nodes()
                logger.info(f"Found {len(free_nodes)} free nodes")
                
                # Logic to schedule jobs would go here
                # For now, just sleep
                time.sleep(NODE_CHECK_INTERVAL_MINS * 60)
                
            except KeyboardInterrupt:
                logger.info("Stopping orchestrator...")
                break
            except Exception as e:
                logger.error(f"Unexpected error: {e}")
                time.sleep(60)

if __name__ == "__main__":
    orchestrator = ClusterDoctorOrchestrator()
    orchestrator.run()
