# cluster_doctor
Continuous validation methods for largescale GPU clusters. This runs health checks on each nodes periodically and prioritized manner. 


Steps
    1. Fetch results history from PVC directory
        a. Create/ fetch status metadata table
        Node	Test	Timestamp	Pass/ Fail/ Failed to complete test
        001	DL unit test	0897089098	pass
        b. Directory structure - /data
            i. Storage
                1) Node_001
                    a) Storage_node001_timestamp1.log
                    b) Storage_Node001_timestamp2.log
                2) Node_002
                    a) Storage_Node002_timestamp1.log
                    b) Storage_Node002_timestamp2.log
            ii. DL_test ( same format and files as storage example above)
            iii. Collective
            iv. IB
            v. Metadata
                1) Status metadata ( one node has one row per test type only)
                Node	Test	Latest_Timestamp	Pass/ Fail/ Failed to complete test
                001	DL unit test	0897089098	Pass
                002	DL unit test	0897089erer	pass
                2) History metadata
                Node	Test	Timestamp	Pass/ Fail/ Failed to complete test
                001	DL unit test	0897089098	Pass
                001	DL unit test	089708sdfgd	fail
                002	storage	0897082323	pass
                
    2. Fetch nodes list
        a. Free nodes ???
        b. Save the list into a file
        c. Keep checking and updating the file every 10 minutes
    3. Submit jobs to free nodes ( reverse order of status metadata timestamp- oldest timestamped node first + cutoff for timestamp delta)
    4. Keep checking if the nodes are free every x minutes
        a. If not:  cancel the particular node job
    5. If one job waits more than 5 mins to start from pending , cancel the job
    6. Every job ( as long as the node went to running state and executed the test script, regardless of outcome)
        a. Save logs at PVC directory
        b. Add new row to history metadata table
        c. Update status metadata table
  