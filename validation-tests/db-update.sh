# main db update
echo "Updating main db with all test results"
STORAGE_OUTPUT_DIR="/data/continuous_validation/storage/$GCRNODE/storage-$GCRNODE-$GCRTIME"
echo "Storage Output dir: $STORAGE_OUTPUT_DIR"
NCCL_OUTPUT_DIR="/data/continuous_validation/nccl/$GCRNODE/nccl-$GCRNODE-$GCRTIME"
echo "NCCL Output dir: $NCCL_OUTPUT_DIR"

#main DB update
python /workspace/c-val/utils/functions.py add-result \
    "$GCRNODE" \
    "all" \
    "pass" \
    "$GCRTIME" \
    --db-path /data/continuous_validation/metadata/validation.db


python3 /workspace/c-val/utils/functions.py add-storage-result \
    "$GCRNODE" \
    "$GCRTIME" \
    "$STORAGE_OUTPUT_DIR" \
    --db-path /data/continuous_validation/metadata/test-storage.db

python3 /workspace/c-val/utils/functions.py add-nccl-result \
    "$GCRNODE" \
    "$GCRTIME" \
    "$NCCl_OUTPUT_DIR" \