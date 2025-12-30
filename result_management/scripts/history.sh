#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

TAIL="${1:-20}"

echo "Fetching history remotely (tail=${TAIL})..."
python3 "${REPO_ROOT}/result_manager.py" --remote history --tail "$TAIL"
