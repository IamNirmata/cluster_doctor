# cluster_doctor
*Last updated:* Thursday, January 08, 2026

Continuous validation framework for large-scale GPU clusters. This system orchestrates health checks on free nodes in a prioritized manner, ensuring comprehensive coverage and automated result tracking via a Kubernetes-based workflow.

## Structure
- `cluster_doctor/` - Main repository root.
- `job-runner.ipynb` - **Main Orchestrator**: Jupyter notebook that drives the end-to-end workflow (node discovery, queue building, submission, monitoring).
- `kubectl/`
    - `functions.py` - Core logic library (contains `get_free_node_list`, `add_result_local`, etc.).
- `ymls/` - Kubernetes job templates.
    - `specific-node-job.yml` - Template for single-node validation jobs.
- `results_management/` - Results fetching and metadata handling.
- `tests/` - Test scripts and categories.
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
- **Function:** `get_free_node_list()` from `kubectl/functions.py`.
- **Action:** Queries the cluster manager for currently available nodes.
- **Output:** Saves to list `get_free_node_list[]`.

### 2. Get DB Latest Status
- **Context:** Accesses `validation.db` via the `gcr-admin-pvc-access` pod.
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

  