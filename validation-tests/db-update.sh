# main db update
python /workspace/c-val/utils/functions.py add-result \
    "$GCRNODE" \
    "storage" \
    "pass" \
    "$GCRTIME" \
    --db-path /data/continuous_validation/metadata/validation.db