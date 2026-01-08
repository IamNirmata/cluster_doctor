import subprocess
import json
import os
import sys
import textwrap
import logging

# Configuration variables
DEFAULT_NAMESPACE = "gcr-admin"
DEFAULT_POD = "gcr-admin-pvc-access"
DEFAULT_DB_PATH = "/data/continuous_validation/metadata/validation.db"
JOB_GROUP_LABEL = "hari-gcr-cluster-validation"


def run_command(command, shell=False, check=True):
    """Executes a shell command and returns stdout."""
    try:
        if shell:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True, check=check)
        else:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)
        return result.stdout.decode('utf-8').strip()
    except subprocess.CalledProcessError as e:
        print(f"Error executing command: {command}")
        print(f"Stderr: {e.stderr.decode('utf-8')}")
        raise e

# --- Cluster Functions ---

#1 Get free nodes list
def get_free_node_list():
    """
    Returns a list of node names that have ALL GPUs free.
    Strictly returns nodes where free count == allocatable count (e.g., 8/8 free).
    """
    nodes, _ = get_free_nodes()
    # STRICT FILTER: Only return nodes where free == alloc (completely empty)
    return [n['node'] for n in nodes if n['free'] == n['alloc'] and n['alloc'] > 0]

#2 






def get_cordoned_nodes():
    """
    Returns a list of cordoned nodes.
    Equivalent to: kubectl/cluster/cordoned_nodes.sh
    """
    cmd = 'kubectl get nodes -o wide | grep -E "NAME|SchedulingDisabled|Ready.*SchedulingDisabled"'
    return run_command(cmd, shell=True, check=False)


def get_free_nodes(verbose=False):
    """
    Returns details about free nodes (capacity, allocated, used, free).
    Equivalent to: kubectl/cluster/freenodes.sh
    """
    # 1. Get Pods JSON
    cmd_pods = ["kubectl", "get", "pods", "-A", "-o", "json"]
    pods_json = json.loads(run_command(cmd_pods))
    
    node_usage = {}
    
    for pod in pods_json.get('items', []):
        node_name = pod.get('spec', {}).get('nodeName')
        if not node_name:
            continue
        
        phase = pod.get('status', {}).get('phase')
        if phase in ["Succeeded", "Failed"]:
            continue
            
        containers = pod.get('spec', {}).get('containers', [])
        init_containers = pod.get('spec', {}).get('initContainers', [])
        
        app_req = sum(int(c.get('resources', {}).get('requests', {}).get('nvidia.com/gpu', 0)) for c in containers)
        # Handle init containers (use max)
        init_reqs = [int(c.get('resources', {}).get('requests', {}).get('nvidia.com/gpu', 0)) for c in init_containers]
        init_req = max(init_reqs) if init_reqs else 0
        
        # Effective GPU usage for the pod is max(app_req, init_req)
        usage = max(app_req, init_req)
        node_usage[node_name] = node_usage.get(node_name, 0) + usage

    # 2. Get Nodes and calculate free
    # NOTE: Used raw string r"" here to fix SyntaxWarning with backslashes
    cmd_nodes = ["kubectl", "get", "nodes", "--no-headers", "-o", r"custom-columns=NAME:.metadata.name,CAP:.status.capacity.nvidia\.com/gpu,ALLOC:.status.allocatable.nvidia\.com/gpu"]
    # We use check=False because if no nodes match or grep fails elsewhere it could throw
    nodes_output = run_command(cmd_nodes, check=False) 
    
    results = []
    totals = {'cap': 0, 'alloc': 0, 'used': 0, 'free': 0}
    
    for line in nodes_output.split('\n'):
        if not line.strip():
            continue
        
        # Original script greps for 'hgx'. We can do that here.
        if 'hgx' not in line: 
            continue
            
        parts = line.split()
        if len(parts) < 3:
            continue
            
        name = parts[0]
        # Handle <none> or missing values
        cap_str = parts[1]
        cap = int(cap_str) if cap_str.isdigit() else 0

        alloc_str = parts[2]
        alloc = int(alloc_str) if alloc_str.isdigit() else 0
        
        used = node_usage.get(name, 0)
        free = alloc - used
        
        # Add to results
        results.append({
            'node': name, 'cap': cap, 'alloc': alloc, 'used': used, 'free': free
        })
        totals['cap'] += cap
        totals['alloc'] += alloc
        totals['used'] += used
        totals['free'] += free
            
    return results, totals

# --- Job Functions ---

def create_job(yaml_file):
    """
    Creates a Kubernetes job from a YAML file.
    Equivalent to: kubectl/job/create.sh
    """
    if not os.path.exists(yaml_file):
        raise FileNotFoundError(f"File '{yaml_file}' does not exist")
    return run_command(["kubectl", "create", "-f", yaml_file])

def delete_job(job_name, namespace=DEFAULT_NAMESPACE):
    """
    Deletes a specific vcjob.
    Equivalent to: kubectl/job/delete-job.sh
    """
    return run_command(["kubectl", "delete", "vcjob", "-n", namespace, job_name])

def delete_all_validation_jobs(confirm=False, namespace=DEFAULT_NAMESPACE):
    """
    Deletes all validation jobs (containing 'hari-gcr-cluster-validation').
    Equivalent to: kubectl/job/delete_all_jobs.sh
    """
    cmd_list = f'kubectl get vcjob -n {namespace} --no-headers -o custom-columns=NAME:.metadata.name | grep "{JOB_GROUP_LABEL}"'
    try:
        jobs = run_command(cmd_list, shell=True).split('\n')
        jobs = [j.strip() for j in jobs if j.strip()]
    except subprocess.CalledProcessError:
        print("No jobs found to delete.")
        return

    if not jobs:
        print("No jobs found.")
        return

    print("Found jobs to delete:", jobs)
    if not confirm:
        response = input("Do you want to delete these jobs? (y/N): ")
        if response.lower() != 'y':
            print("Operation cancelled.")
            return

    for job in jobs:
        print(f"Deleting job: {job}")
        try:
            run_command(["kubectl", "delete", "vcjob", "-n", namespace, job])
        except Exception as e:
            print(f"Failed to delete {job}: {e}")
    print("Deletion completed.")

def exec_pod(pod_name, namespace=DEFAULT_NAMESPACE):
    """
    Start interactive shell in pod (Wrapper).
    Equivalent to: kubectl/job/exec.sh
    NOTE: This requires an interactive terminal and cannot be fully automated in this script.
    """
    print(f"Starting interactive session in {pod_name}...")
    subprocess.call(["kubectl", "exec", "-it", pod_name, "-n", namespace, "--", "/bin/bash"])

# --- Result Functions (Remote Execution) ---

def _exec_python_on_pod(python_code, pod, namespace, args=None):
    """Helper to execute python code inside a pod."""
    cmd = ["kubectl", "exec", "-n", namespace, pod, "--", "python3", "-c", python_code]
    if args:
        cmd.extend([str(a) for a in args])
    return run_command(cmd)

def get_db_latest_status(pod=DEFAULT_POD, namespace=DEFAULT_NAMESPACE, db_path=DEFAULT_DB_PATH):
    """
    Fetches status from the database inside the pod.
    Equivalent to: kubectl/result/status.sh
    """
    code = textwrap.dedent(f"""
    import sqlite3, datetime, sys
    db_path = '{db_path}'
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        rows = conn.execute('SELECT node, test, latest_timestamp, result FROM latest_status ORDER BY node, test').fetchall()

        print('node\\ttest\\tlatest_timestamp_num\\tlatest_timestamp\\tresult')
        for r in rows:
            ts_num = int(r['latest_timestamp']) if r['latest_timestamp'] is not None else ''
            ts_iso = ''
            if r['latest_timestamp'] is not None:
                ts_iso = datetime.datetime.fromtimestamp(
                    r['latest_timestamp'],
                    tz=datetime.timezone.utc
                ).replace(microsecond=0).isoformat().replace('+00:00', 'Z')

            print(f"{{r['node']}}\\t{{r['test']}}\\t{{ts_num}}\\t{{ts_iso}}\\t{{r['result']}}")
    except Exception as e:
        print(f'Error: {{e}}', file=sys.stderr)
        sys.exit(1)
    """)
    return _exec_python_on_pod(code, pod, namespace)

def get_node_status(node, pod=DEFAULT_POD, namespace=DEFAULT_NAMESPACE, db_path=DEFAULT_DB_PATH):
    """
    Fetches status for a specific node.
    Equivalent to: kubectl/result/node_status.sh
    """
    code = textwrap.dedent(f"""
    import sqlite3, datetime, sys
    db_path = '{db_path}'
    node_filter = sys.argv[1]
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        q = 'SELECT node, test, latest_timestamp, result FROM latest_status WHERE node = ? ORDER BY node, test'
        rows = conn.execute(q, (node_filter,)).fetchall()
        print('node\\ttest\\tlatest_timestamp\\tresult')
        for r in rows:
            ts = datetime.datetime.fromtimestamp(r['latest_timestamp'], tz=datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
            print(f"{{r['node']}}\\t{{r['test']}}\\t{{ts}}\\t{{r['result']}}")
    except Exception as e:
        print(f'Error: {{e}}', file=sys.stderr)
        sys.exit(1)
    """)
    return _exec_python_on_pod(code, pod, namespace, args=[node])

def get_history(limit=20, pod=DEFAULT_POD, namespace=DEFAULT_NAMESPACE, db_path=DEFAULT_DB_PATH):
    """
    Fetches run history.
    Equivalent to: kubectl/result/history.sh
    """
    code = textwrap.dedent(f"""
    import sqlite3, datetime, sys
    db_path = '{db_path}'
    limit = int(sys.argv[1])
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        rows = conn.execute('SELECT node, test, timestamp, result FROM runs ORDER BY timestamp DESC LIMIT ?', (limit,)).fetchall()
        print('node\\ttest\\ttimestamp\\tresult')
        for r in rows:
            ts = datetime.datetime.fromtimestamp(r['timestamp'], tz=datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
            print(f"{{r['node']}}\\t{{r['test']}}\\t{{ts}}\\t{{r['result']}}")
    except Exception as e:
        print(f'Error: {{e}}', file=sys.stderr)
        sys.exit(1)
    """)
    return _exec_python_on_pod(code, pod, namespace, args=[limit])

def add_result_local(node, test, result, timestamp=None, db_path=DEFAULT_DB_PATH):
    """
    Adds a result to the database (Local Execution).
    Equivalent to: kubectl/result/add.sh
    """
    import sqlite3, datetime
    
    if timestamp is None:
        timestamp = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    else:
        # Handle if timestamp is string (ISO) or already int
        if isinstance(timestamp, str):
             if timestamp.isdigit():
                 timestamp = int(timestamp)
             else:
                 # Minimal parsing attempt
                 if timestamp.endswith('Z'): 
                    timestamp = timestamp[:-1] + '+00:00'
                 d = datetime.datetime.fromisoformat(timestamp)
                 # Ensure UTC
                 if d.tzinfo is None: d = d.replace(tzinfo=datetime.timezone.utc)
                 timestamp = int(d.timestamp())

    try:
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        conn = sqlite3.connect(db_path)
        # Ensure tables exist just in case
        conn.execute("CREATE TABLE IF NOT EXISTS runs (node TEXT NOT NULL, test TEXT NOT NULL, timestamp INTEGER NOT NULL, result TEXT NOT NULL CHECK (result IN ('pass','fail','incomplete')));")
        conn.execute("INSERT INTO runs(node, test, timestamp, result) VALUES (?,?,?,?)", (node, test, timestamp, result))
        conn.commit()
        print(f'Added: {node} {test} {result} {timestamp}')
    except Exception as e:
        print(f"Error adding result: {e}")
        raise e

def list_pod_files(target_dir="/data/continuous_validation", pod=DEFAULT_POD, namespace=DEFAULT_NAMESPACE):
    """
    Lists files in a remote directory.
    Equivalent to: kubectl/ls.sh
    """
    return run_command(["kubectl", "-n", namespace, "exec", pod, "--", "ls", "-F", target_dir])

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Cluster Doctor Kubectl Functions")
    subparsers = parser.add_subparsers(dest="command")

    # Example: Exec into pod
    p_exec = subparsers.add_parser("exec", help="Exec into a pod")
    p_exec.add_argument("pod_name", help="Name of the pod to exec into")
    p_exec.add_argument("--namespace", "-n", default=DEFAULT_NAMESPACE, help="Namespace")

    # Example: Get Free Nodes
    p_free = subparsers.add_parser("freenodes", help="List free nodes")

    # Example: List Remote Files
    p_ls = subparsers.add_parser("ls", help="List remote files")
    p_ls.add_argument("path", nargs="?", default="/data/continuous_validation", help="Remote path to list")

    args = parser.parse_args()

    if args.command == "exec":
        exec_pod(args.pod_name, namespace=args.namespace)
    
    elif args.command == "freenodes":
        # Get nodes and totals (get_free_nodes returns a tuple)
        nodes, totals = get_free_nodes()
        
        # Define table format
        fmt = "{:<30} {:<6} {:<6} {:<6} {:<6}"
        
        # Print Header
        print("\n" + fmt.format("NODE NAME", "CAP", "ALLOC", "USED", "FREE"))
        print("-" * 60)
        
        if not nodes:
            print("No free nodes found.")
        else:
            for n in nodes:
                # OPTIONAL: Filter logic for the TABLE VIEW
                # We show nodes with ANY free GPUs here so you can see fragmentation.
                # (Unlike get_free_node_list() which is strictly for empty nodes)
                if n['free'] >= 0:
                    print(fmt.format(n['node'], n['cap'], n['alloc'], n['used'], n['free']))
            
            print("-" * 60)
            print(fmt.format("TOTAL", totals['cap'], totals['alloc'], totals['used'], totals['free']) + "\n")
            
    elif args.command == "ls":
        print(list_pod_files(target_dir=args.path))
        
    else:
        print("No command specified. Showing sample usage:")
        print("-" * 50)
        print("OPTION 1: Import in Python script")
        print("  import functions")
        print("  functions.exec_pod('pod123')")
        print("  # Returns strictly empty nodes for jobs:")
        print("  empty_nodes = functions.get_free_node_list()")
        print("  # Returns all nodes with status details:")
        print("  all_nodes, totals = functions.get_free_nodes()")
        print("-" * 50)
        print("OPTION 2: Run directly from terminal")
        print("  python3 functions.py exec pod123")
        print("  python3 functions.py freenodes")
        print("  python3 functions.py ls /tmp")