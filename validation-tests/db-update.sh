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

#storage DB update
echo "Updating storage db with test results"
python3 /workspace/c-val/utils/functions.py add-storage-result \
    "$GCRNODE" \
    "$GCRTIME" \
    "$STORAGE_OUTPUT_DIR" \
    --db-path /data/continuous_validation/metadata/test-storage.db
echo "Storage DB update completed."


#nccl DB update
NCCL_LOG_FILE="$NCCL_OUTPUT_DIR/nccl-$GCRNODE-$GCRTIME.log"
export GCR_LATENCY=$(grep "Latency:" "$LOG_FILE" | tail -n 1 | awk '{print $2}')
export GCR_ALGBW=$(grep "AlgBW:" "$LOG_FILE" | tail -n 1 | awk '{print $2}')
export GCR_BUSBW=$(grep "BusBW:" "$LOG_FILE" | tail -n 1 | awk '{print $2}')

python3 /workspace/c-val/utils/functions.py add-nccl-result \
    "$GCRNODE" \
    "$GCRTIME" \
    "$GCR_BUSBW" \
    "$GCR_LATENCY" \
    --db-path /data/continuous_validation/metadata/test-nccl.db

echo "DB update completed."