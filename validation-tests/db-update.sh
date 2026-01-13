# main db update
python /workspace/c-val/utils/functions.py add-result \
    "$GCRNODE" \
    "storage" \
    "pass" \
    "$GCRTIME" \
    --db-path /data/continuous_validation/metadata/validation.db

python3 /workspace/c-val/utils/functions.py add-storage-result \
    "$GCRNODE" \
    "$GCRTIME" \
    "$OUTPUT_DIR" \
    --db-path /data/continuous_validation/metadata/test-storage.db