#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

POD="${POD:-gcr-admin-pvc-access}"
NAMESPACE="${NAMESPACE:-gcr-admin}"
TAIL="${1:-20}"

echo "Fetching history remotely from pod ${POD} (ns: ${NAMESPACE}) (tail=${TAIL})..."
python3 "${REPO_ROOT}/result_manager.py" --remote --pod "$POD" --namespace "$NAMESPACE" history --tail "$TAIL"
