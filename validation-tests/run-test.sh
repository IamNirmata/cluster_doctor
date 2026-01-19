#create dirs
storage_dir="/data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/"
nccl_dir="/data/continuous_validation/nccl/$GCRNODE/nccl-$GCRNODE-$GCRTIME/"

mkdir -p "$storage_dir"
mkdir -p "$nccl_dir"
apt-get update && apt-get install -y fio

#storage test
bash /workspace/c-val/validation-tests/storage/storage.sh | tee /data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/storage-$GCRNODE-$GCRTIME.log
export GCRRESULT1=pass

#nccl test
NCCL_NET=IB  NCCL_P2P_DISABLE=1 NCCL_SHM_DISABLE=1 NCCL_DEBUG=INFO torchrun --nproc_per_node=8 /workspace/c-val/validation-tests/nccl/single-node-allreduce.py 2>&1 | tee /data/continuous_validation/nccl/$GCRNODE/nccl-$GCRNODE-$GCRTIME/nccl-$GCRNODE-$GCRTIME.log
export GCRRESULT2=pass


