# cluster_doctor
*Last updated:* Tuesday, December 23, 2025 — 4:23 PM

Continuous validation methods for largescale GPU clusters. This runs health checks on each nodes periodically and prioritized manner. 


## Structure
- `cluster_doctor/` - main code directory
- `cluster_management/` - cluster management code (job submission, node status checking, etc)
- `results_management/` - results fetching and metadata table of all test results
- `tests/` - all test categories and test scripts

## Directory layout

- **Logs Directory**
  - **Storage ( sample test category )**
    - `Node_001/`
      - `Storage_node001_timestamp1.log`
      - `Storage_Node001_timestamp2.log`
    - `Node_002/`
      - `Storage_Node002_timestamp1.log`
      - `Storage_Node002_timestamp2.log`
  - **DL_test ( sample test category )**
    - `Node_001/`
      - `DL_test_node001_timestamp1.log`
      - `DL_test_Node001_timestamp2.log`
    - `Node_002/`
      - `DL_test_Node002_timestamp1.log`
      - `DL_test_Node002_timestamp2.log`

- **Test Results Metadata**
  1) **Status metadata view** (SQLlite view)

     | node | test        | timestamp        | result                              |
     |-----:|-------------|-----------------:|-------------------------------------|
     | 001  | DL unit test| 0897089098       | Pass                                |
     | 002  | DL unit test| 0897089erer      | pass                                |

  2) **History metadata table**

     | node | test        | timestamp   | result                              |
     |-----:|-------------|------------:|-------------------------------------|
     | 001  | DL unit test| 0897089098  | Pass                                |
     | 001  | DL unit test| 089708sdfgd | fail                                |
     | 002  | storage     | 0897082323  | pass                                |



## Workflow

### 1) An orchestrator python script runs periodically (e.g., every hour)

### 2) Get Cluster status
- Get free nodes from cluster manager
- Save the list into a file
- Keep checking and updating the file every x minutes

### 3) Fetch results metadata
- [optionally] Create directory structure and result tables if not exist using results management module add function
- fetch latest test results metadata from status metadata view
- Save the metadata table into a file

### 3) Build priority queue of nodes to test

a) For each node in the free nodes list:
  - Check the latest test result timestamp from the metadata table
  - Check if the latest test result timestamp is older than the defined threshold (e.g., 7 days), if yes, add to priority queue

b) Build the priority queue based on the following criteria:
  - Qualification to be added to the queue:
    - Nodes that have never been tested
    - Nodes with test results older than the defined threshold
  - Priority criteria:
    - Nodes with shorter threshold delta have higher priority

### 4) Job submission
a) Thresholds:
- Max concurrent jobs: **2**
- Max queue time before cancellation: **30 mins**
- Job pending timeout: **20 mins**
- Frequency of checking node availability: **5 mins**

b) Process:
- While there are free slots for concurrent jobs and nodes in the priority queue:
  - Submit jobs using orchestrator script
  - Keep track of submitted jobs and their statuses
  - Cancel jobs if
    - Node becomes unavailable
    - Job exceeds timeout
    - Job waits more than pending timeout

###
Submit jobs in **reverse order of status metadata timestamp**:
- Oldest timestamped node first  
- cutoff for timestamp delta

---

### 4) Keep checking if the nodes are free every x minutes

a) If not: cancel the particular node job  

---

### 5) Pending timeout

If one job waits more than **5 mins** to start from pending, cancel the job.

---

### 6) Post-run handling (for every job)

As long as the node went to **running** state and executed the test script (regardless of outcome):

a) Save logs at PVC directory  
b) Add new row to history metadata table  
c) Update status metadata table  
