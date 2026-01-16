# main db update
echo "Updating main db with storage test result"
OUTPUT_DIR="/data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME"
echo "Output dir: $OUTPUT_DIR"

python /workspace/c-val/utils/functions.py add-result \
    "$GCRNODE" \
    "all" \
    "pass" \
    "$GCRTIME" \
    --db-path /data/continuous_validation/metadata/validation.db

python3 /workspace/c-val/utils/functions.py add-storage-result \
    "$GCRNODE" \
    "$GCRTIME" \
    "$OUTPUT_DIR" \
    --db-path /data/continuous_validation/metadata/test-storage.db

echo "DB update complete"