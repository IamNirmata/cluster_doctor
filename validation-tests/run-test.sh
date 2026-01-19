#!/bin/bash

#prep
apt-get update > /dev/null 2>&1 && apt-get install -y fio > /dev/null 2>&1 

echo "STORAGE_OUTPUT_DIR: $STORAGE_OUTPUT_DIR"
echo "NCCL_OUTPUT_DIR: $NCCL_OUTPUT_DIR"

echo "STORAGE_LOG_FILE: $STORAGE_LOG_FILE"
echo "STORAGE_SUMMARY_FILE: $STORAGE_SUMMARY_FILE"

echo "NCCL_LOG_FILE: $NCCL_LOG_FILE"
echo "NCCL_SUMMARY_FILE: $NCCL_SUMMARY_FILE"



echo "#########################################################################"
echo "Running tests on node: $GCRNODE at time: $GCRTIME"
echo "Storage output dir: $STORAGE_OUTPUT_DIR"
echo "NCCL output dir: $NCCL_OUTPUT_DIR"
echo "#########################################################################"

#storage test
storage-log-file= "$storage_dir/storage-$GCRNODE-$GCRTIME.log"
bash /workspace/c-val/validation-tests/storage/storage.sh | tee "$storage-log-file"
echo "Storage test is complete. Log file: $storage-log-file"
export GCRRESULT1=pass

#nccl test
nccl-log-file= "$nccl_dir/nccl-$GCRNODE-$GCRTIME.log"
nccl-summary-file= "$nccl_dir/nccl-summary-$GCRNODE-$GCRTIME.json"
nccl-test-command="/workspace/c-val/validation-tests/nccl/single-node-allreduce.py --result-file $nccl-summary-file"
NCCL_NET=IB  NCCL_P2P_DISABLE=1 NCCL_SHM_DISABLE=1 NCCL_DEBUG=INFO torchrun --nproc_per_node=8 "$nccl-test-command" | tee "$nccl-log-file"
echo "NCCL test is complete. Log file: $nccl-log-file Summary file: $nccl-summary-file"
export GCRRESULT2=pass
echo "All tests completed."