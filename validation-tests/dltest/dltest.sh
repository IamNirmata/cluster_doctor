#!/usr/bin/env bash

echo "Running DL Test on node: $GCRNODE at time: $GCRTIME"
DLTEST_COMMAND="/data/continuous_validation/deeplearning_unit_test/main.py"



torchrun --nnodes=1 --nproc-per-node "$1" "$DLTEST_COMMAND" \
  --test_plan 80gb-b200 \
  --baseline_test_id b200-pt2.8.0-cuda12.9 \
  --iterations 20 \
  >"$DLTEST_LOG_FILE" 2>&1
rc=$?

