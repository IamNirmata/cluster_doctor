mkdir -p /data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/
apt-get update && apt-get install -y fio

bash /workspace/c-val/validation-tests/storage/storage.sh | tee /data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME/storage-$GCRNODE-$GCRTIME.log
$GCRRESULT1=pass


