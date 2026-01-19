#!/bin/bash

#prep
apt-get update > /dev/null 2>&1 && apt-get install -y fio > /dev/null 2>&1 

#create dirs
storage_dir="/data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/"
nccl_dir="/data/continuous_validation/nccl/$GCRNODE/nccl-$GCRNODE-$GCRTIME/"
mkdir -p "$storage_dir"
mkdir -p "$nccl_dir"

echo "#########################################################################"
echo "Running tests on node: $GCRNODE at time: $GCRTIME"
echo "Storage output dir: $storage_dir"
echo "NCCL output dir: $nccl_dir"
echo "#########################################################################"

#storage test
storage-log-file= "$storage_dir/storage-$GCRNODE-$GCRTIME.log"
bash /workspace/c-val/validation-tests/storage/storage.sh | tee "$storage-log-file"
echo "Storage test is complete. Log file: $storage-log-file"
export GCRRESULT1=pass

#nccl test
nccl-log-file= "$nccl_dir/nccl-$GCRNODE-$GCRTIME.log"
nccl-test-file="/workspace/c-val/validation-tests/nccl/single-node-allreduce.py"
NCCL_NET=IB  NCCL_P2P_DISABLE=1 NCCL_SHM_DISABLE=1 NCCL_DEBUG=INFO torchrun --nproc_per_node=8 
echo "NCCL test is complete. Log file: $nccl-log-file"
export GCRRESULT2=pass


