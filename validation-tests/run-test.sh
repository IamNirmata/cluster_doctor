mkdir -p /data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/
mkdir -p /data/continuous_validation/nccl-loopback/$GCRNODE/
apt-get update && apt-get install -y fio

bash /workspace/c-val/validation-tests/storage/storage.sh | tee /data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/storage-$GCRNODE-$GCRTIME.log
$GCRRESULT1=pass

NCCL_NET=IB  NCCL_P2P_DISABLE=1 NCCL_SHM_DISABLE=1 NCCL_DEBUG=INFO torchrun --nproc_per_node=8 single-node-allreduce.py 2>&1 | tee /data/continuous_validation/nccl-loopback/$GCRNODE/nccl-loopback-$GCRNODE-$GCRTIME.log


