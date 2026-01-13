# Continuous Validation Framework for GPU Clusters
*Last updated:* January 13, 2026

This is a continuous validation framework designed for large-scale GPU clusters. It orchestrates health checks on currently free nodes in a prioritized manner, ensuring comprehensive coverage and automated result tracking over time.

## Assumptions & Design Philosophy
This framework operates based on several key assumptions about cluster management and failure modes:

- **Targeted Random Sampling**: [needs improvemnt While random sampling provides a representative statistical view of cluster health, it may miss specific failing nodes. This system prioritizes complete coverage of all nodes over time rather than just statistical sampling.
- **Node Availability Heuristic**: "Bad" nodes are statistically more likely to be free than "good" nodes. This is based on the observation that jobs scheduled on faulty nodes tend to crash or fail quickly, releasing the resource back to the pool. Prioritizing free nodes naturally targets potential problem areas.
- **Cost-Benefit Balance**: Performing full online validation (pre-flight or post-flight) for every user job is  expensive in terms of time and compute resources. An out-of-band continuous validation loop balances deep validation coverage with cluster utilization.
- **Application-Level Validation**: Standard infrastructure monitoring (e.g., Kubernetes Node Problem Detector) often misses subtle ecosystem instabilities. This framework validates the stack at the level user workloads operate, running Deep Learning unit tests, NCCL tests, and storage benchmarks.
- **Non-Interference**: The system explicitly targets "free" nodes to minimize interference with actual user workloads, assuming that checking idle resources is the safest path to validation.

## Requirements
Before running the orchestrator, ensure the following are in place:

- **Environment**:
    - **Python 3.x** with Jupyter Notebook support.
    - **Kubernetes Access**: `kubectl` configured with cluster admin rights. (Context must be active).
    - **Volcano/Scheduler**: Required for specific node targeting features used in job templates.
- **Infrastructure**:
    - **Shared Storage**: A PVC/NFS mount accessible by all nodes at `/data/continuous_validation/`.
    - **Metadata Service**: `gcr-admin-pvc-access` pod must be running to facilitate database file access for the orchestrator.
    - **Database**: A SQLite database initialized at `/data/continuous_validation/metadata/validation.db`.

## Quick Start
1.  **Configure Environment**: Ensure your local `kubectl` context is pointing to the target cluster.
2.  **Launch Orchestrator**: Open `job-runner.ipynb` in a Jupyter environment.
3.  **Run Validation**: Execute the cells strictly in order. The notebook will:
    -   Discover free nodes.
    -   Check the database for testing history.
    -   Prioritize nodes that haven't been tested recently.
    -   Submit batch validation jobs to the cluster.
    -   Monitor job progress and update the database.

## Repository Structure
- `c-eval/` - Main repository root.
- `job-runner.ipynb` - **Main Orchestrator**: Interactive notebook that drives the end-to-end workflow.
- `utils/`
    - `functions.py` - Core utility functions for Kubernetes interactions, database handling, and job lifecycle management.
- `kubectl/` - Shell scripts for helper Kubernetes operations.
- `ymls/` - Kubernetes job templates.
    - `specific-node-job.yml` - Template for targeted single-node validation jobs.
- `validation-tests/` - Test scripts and validation logic run inside the pods.
- `gitignored/reports/` - Generated daily summaries and reports.

## Directory Layout & Data Persistence
All test metadata and logs are centralized on the shared PVC to ensure persistence across pod restarts.

### 1. Logs Directory
Logs are organized by test type and node name:
`/data/continuous_validation/<test-name>/<node-name>/`

**Example:**
`/data/continuous_validation/Storage/Node_001/Storage_node001_1736367000.log`

### 2. Test Results Metadata
The central source of truth is the SQLite database:
`/data/continuous_validation/metadata/validation.db`

It tracks the latest validation timestamp and result for every node-test pair:

| Node | Test Name | Timestamp | Result |
|-----:|-----------|----------:|--------|
| 001 | DL unit test | 1736367000 | Pass |
| 002 | DL unit test | 1736367000 | Fail |

## Workflow Internals

The orchestration logic in `job-runner.ipynb` follows these steps:

### 1. Discovery
- **Function:** `get_free_node_list()`
- **Action:** Queries the cluster scheduler to identify nodes that are currently idle and schedulable.

### 2. History Lookup
- **Function:** `get_db_latest_status()`
- **Action:** Reads the `validation.db` (via the helper pod) to retrieve the last known validation timestamp for every node. Nodes with no history are treated as having a "very old" timestamp.

### 3. Prioritization
- **Function:** `build_priority_queue(free_nodes_list, db_latest_status, Z_days_threshold)`
- **Logic:**
    1.  **Filter:** Intersect free nodes with the history.
    2.  **Qualify:** Select nodes where the last test is older than `Z` days.
    3.  **Sort:** Order by timestamp ascending (oldest tested -> highest priority).
- **Output:** A priority queue of nodes requiring validation.

### 4. Batch Execution
- **Function:** `run_batch()`
- **Logic:** Submits jobs in strictly controlled batches (e.g., 5 jobs at a time) to avoid swamping the scheduler.
    - **Job Creation:** Hydrates `specific-node-job.yml` with the target node name and test parameters.
    - **Monitoring:** Polls job status every `X` minutes.
    - **Timeouts:** Automatically cancels jobs that stick in `Pending` state for too long to free up the slot.

### 5. In-Pod Execution
Once scheduled, the validation pod:
1.  Clones the latest test scripts.
2.  Runs the specified validation suite (network, storage, or compute).
3.  Streams logs to the shared PVC.
4.  Updates the `validation.db` directly with the `Pass`/`Fail` outcome.

### 6. Reporting
The system generates a daily text summary in `./gitignored/reports/daily_report_<date>.txt` highlighting:
- Total nodes tested today.
- Nodes that failed validation.
- Nodes that have never been successfully validated.
