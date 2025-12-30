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


### 1) Fetch results history from PVC directory

#### a) Create / fetch **status metadata** view

Example:

| node | test        | timestamp   | result |
|-----:|-------------|------------:|-------------------------------------|
| 001  | DL unit test| 0897089098  | pass                                |

#### b) Directory structure — `/data`



---

### 2) Fetch nodes list

a) get free nodes from cluster manager  
b) Save the list into a file  
c) Keep checking and updating the file every 10 minutes  

---

### 3) Submit jobs to free nodes

Submit jobs in **reverse order of status metadata timestamp**:
- Oldest timestamped node first  
- + cutoff for timestamp delta

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
