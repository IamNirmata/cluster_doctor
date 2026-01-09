echo "test1.sh executed"
export gcr_test_result="pass"

python cluster_doctor/utils/functions.py --add_result_local \
  --db_path /data/continuous_validation/metadata/validation.db \
  --node_name "$GCRNODE" \
  --test_name "test1" \
  --result "pass
