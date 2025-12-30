# cluster_doctor
*Last updated:* Tuesday, December 23, 2025 — 4:23 PM
Continuous validation methods for largescale GPU clusters. This runs health checks on each nodes periodically and prioritized manner. 


## Steps

### 1) Fetch results history from PVC directory

#### a) Create / fetch **status metadata** table

Example:

| Node | Test        | Timestamp   | Pass/ Fail/ Failed to complete test |
|-----:|-------------|------------:|-------------------------------------|
| 001  | DL unit test| 0897089098  | pass                                |

#### b) Directory structure — `/data`

- **Storage**
  - `Node_001/`
    - `Storage_node001_timestamp1.log`
    - `Storage_Node001_timestamp2.log`
  - `Node_002/`
    - `Storage_Node002_timestamp1.log`
    - `Storage_Node002_timestamp2.log`

- **DL_test** (same format and files as storage example above)
- **Collective**
- **IB**
- **Metadata**
  1) **Status metadata** (one node has one row per test type only)

     | Node | Test        | Latest_Timestamp | Pass/ Fail/ Failed to complete test |
     |-----:|-------------|-----------------:|-------------------------------------|
     | 001  | DL unit test| 0897089098       | Pass                                |
     | 002  | DL unit test| 0897089erer      | pass                                |

  2) **History metadata**

     | Node | Test        | Timestamp   | Pass/ Fail/ Failed to complete test |
     |-----:|-------------|------------:|-------------------------------------|
     | 001  | DL unit test| 0897089098  | Pass                                |
     | 001  | DL unit test| 089708sdfgd | fail                                |
     | 002  | storage     | 0897082323  | pass                                |

---

### 2) Fetch nodes list

a) Free nodes ???  
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
