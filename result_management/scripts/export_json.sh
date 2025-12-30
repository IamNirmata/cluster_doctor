#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

POD="${POD:-gcr-admin-pvc-access}"
NAMESPACE="${NAMESPACE:-gcr-admin}"
OUT="${1:-./status.json}"

echo "Exporting JSON remotely from pod ${POD} (ns: ${NAMESPACE}) to ${OUT}..."
python3 "${REPO_ROOT}/result_manager.py" --remote --pod "$POD" --namespace "$NAMESPACE" export-json --out "$OUT"
