#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

OUT="${1:-./status.csv}"

echo "Exporting CSV remotely to ${OUT}..."
python3 "${REPO_ROOT}/result_manager.py" --remote export-csv --out "$OUT"
