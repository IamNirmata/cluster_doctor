#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <node> <test> <result> [timestamp]"
  echo "Example: $0 slc01-cl02-hgx-0453 dl_test pass"
  exit 1
fi

NODE="$1"
TEST="$2"
RESULT="$3"
TIMESTAMP="${4:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

echo "Adding result locally (in-pod)..."
python3 "${REPO_ROOT}/result_manager.py" add \
  --node "$NODE" \
  --test "$TEST" \
  --timestamp "$TIMESTAMP" \
  --result "$RESULT"
