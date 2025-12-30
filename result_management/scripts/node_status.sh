#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node_id>"
  echo "Example: $0 slc01-cl02-hgx-0453"
  exit 1
fi

NODE="$1"
POD="${POD:-gcr-admin-pvc-access}"
NAMESPACE="${NAMESPACE:-gcr-admin}"

echo "Fetching status for node ${NODE} remotely from pod ${POD} (ns: ${NAMESPACE})..."
python3 "${REPO_ROOT}/result_manager.py" --remote --pod "$POD" --namespace "$NAMESPACE" status --node "$NODE"
