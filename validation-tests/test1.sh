mkdir -p /data/continuous_validation/storage/$GCRNODE
apt-get update && apt-get install -y fio

bash /workspace//validation-tests/storage.sh | tee /data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME.log
export gcr_test_result="pass"


