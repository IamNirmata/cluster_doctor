mkdir -p /data/continuous_validation/storage/$GCRNODE
apt-get update && apt-get install -y fio

bash  | tee /data/continuous_validation/storage/$GCRNODE/test1-$GCRNODE-$GCRTIME.log
export gcr_test_result="pass"


