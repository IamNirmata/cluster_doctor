# cluster_doctor
*Last updated:* Thursday, January 08, 2026

Continuous validation framework for large-scale GPU clusters. This system orchestrates health checks on free nodes in a prioritized manner, ensuring comprehensive coverage and automated result tracking via a Kubernetes-based workflow.

## Structure
- `cluster_doctor/` - Main repository root.
- `job-runner.ipynb` - **Main Orchestrator**: Jupyter notebook that drives the end-to-end workflow (node discovery, queue building, submission, monitoring).
- `utils/`
    - `functions.py` - Core utility functions for Kubernetes interactions, database handling, and job management.
- `kubectl/` - Shell scripts for Kubernetes operations.
- `ymls/` - Kubernetes job templates.
    - `specific-node-job.yml` - Template for single-node validation jobs.
- `validation-tests/` - Test scripts and categories.
- `gitignored/reports/` - Generated daily reports.

## Directory Layout & Data Persistence
All test metadata and logs are stored in a predefined directory structure on a PVC/NFS mount accessible by all nodes (and the orchestrator via `gcr-admin-pvc-access` pod) at `/data/continuous_validation/`.

### 1. Logs Directory
Follows the structure: `/data/continuous_validation/<test-name>/<node-name>/`

- **Storage (sample category)**
  - `Node_001/`
    - `Storage_node001_timestamp1.log`
  - `Node_002/`
    - `Storage_Node002_timestamp1.log`

### 2. Test Results Metadata
**Database File:** `/data/continuous_validation/metadata/validation.db`

The database tracks the latest status per node/per test.

| node | test | timestamp | result |
|-----:|------|----------:|--------|
| 001 | DL unit test | 1736367000 | Pass |
| 002 | DL unit test | 1736367000 | Fail |

## Workflow

The orchestration is handled by `job-runner.ipynb` implementing the following logic:

### 1. Get Free Node List
- **Function:** `get_free_node_list()` from `utils/functions.py`.
- **Action:** Queries the cluster manager for currently available nodes.
- **Output:** Saves to list `get_free_node_list[]`.

### 2. Get DB Latest Status
- **Context:** Accesses `validation.db` via the `gcr-admin-pvc-access` pod using `get_db_latest_status()` from `utils/functions.py`.
- **Action:** Retrieves the latest test timestamp for every node in the database.
- **Logic:**
    - If a node has no history, it is marked with a "very old" timestamp (highest priority).
    - Maps: `Node -> Test -> Latest Timestamp`.

### 3. Build Priority Queue
- **Function:** `build_priority_queue(free_nodes_list, db_latest_status, Z_days_threshold)`
- **Logic:**
    1.  **Filter:** Only considers nodes currently in the `free_nodes_list`.
    2.  **Qualify:** Skips nodes where the latest test result is *newer* than `Z` days.
    3.  **Sort:** Orders by timestamp (oldest = highest priority).
- **Output:** `job_priority_queue_list`
  ```python
  [
      [node1, 1, True],  # [nodename, priority_order, job_submission_status]
      [node2, 2, False],
      ...
  ]

  ```



### 5. submit jobs and Monitor Job Status
run_batch(node_name, job_name, template_path, dry_run=False, batch_size=N, monitor_interval=X):
  while priority queue has unsubmitted jobs (false status):
    submit next N jobs from queue
      - inputs: node name, job name, template path

    monitor job status every X minutes
    update job status in queue
    handle timeouts for pending jobs
### 4. Batch Job Submission
**Inputs:**
- **Batch Size:** `N` jobs.
- **Queue:** `job_priority_queue_list`.
- **Template:** `/home/hari/b200/validation/cluster_doctor/ymls/specific-node-job.yml`.

**Process (per batch):**
1.  Read the YAML template.
2.  Inject node name (`<node-name>`).
3.  Inject job name: `hari-gcr-ceval-<node-name>-<timestamp>`.
4.  Submit to K8s cluster using create_job() function from `utils/functions.py`.

  
    - Submit next `N` jobs as per step 4.
- **Action:** Tracks the status of submitted batches using `get_job_status()` from `utils/functions.py` every `X` minutes in a the run_batch() function loop.
- **Updates:** Modifies `job_submission_status` in `job_priority_queue_list` based on job completion status ( pending, running, succeeded, failed).
- **Timeout Logic:**
    - If a job remains `Pending` > `X` minutes:
        - Cancel the job using delete_job() from `utils/functions.py`.
        - Update `job_submission_status` to `timeout` in the queue list.

### 6. Job Execution (Inside the Job Pod)
Once the job is scheduled on the specific node:
1.  **Setup:** Git clones `cluster_doctor` to `/opt/cluster_doctor`.
2.  **Execute:** Runs validation tests, piping output via `tee`.
3.  **Log Archival:** Saves STDOUT/STDERR to: `/data/continuous_validation/<test-name>/<node-name>/<node-name>-<testname>-<timestamp>.log`
4.  **DB Update:** Calls `add_result_local()` (from `/opt/cluster_doctor/utils/functions.py`) to update `validation.db` with the new timestamp and pass/fail status.

### 7. Generate Daily Report
- **Action:** Summarizes the run statistics.
- **Content:**
    - Summary of nodes tested.
    - Summary of pass/fail results.
    - List of nodes never tested.
- **Output:** Saved to `./gitignored/reports/daily_report_<date>.txt`.

## Requirements
- **Python 3.x** with Jupyter Notebook support.
- **Kubernetes Access:** `kubectl` configured with cluster admin rights.
- **PVC Access:** `gcr-admin-pvc-access` pod running for DB file access.
- **Volcano/Scheduler:** For specific node targeting.
- **Database:** SQLite (`validation.db`).