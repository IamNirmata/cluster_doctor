echo "test1.sh executed"
export gcr_test_result="pass"

python cluster_doctor/utils/functions.py add-result \
    "$GCRNODE" \
    "test1" \
    "pass" \
    --db-path /data/continuous_validation/metadata/validation.db
