mkdir -p /data/continuous_validation/test1/$GCRNODE
echo "test1.sh executed" | tee /data/continuous_validation/test1/$GCRNODE/test1-$GCRNODE-$GCRTIME.log
export gcr_test_result="pass"


