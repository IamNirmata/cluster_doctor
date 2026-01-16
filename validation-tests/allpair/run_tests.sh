#!/usr/bin/env bash
# Sample harness for running allpair.sh locally. Adjust the variables for your environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Update these paths to match your hostfile and desired log folder.
HOSTFILE=${HOSTFILE:-/opt/hostfile}
LOGDIR=${LOGDIR:-/tmp/allpairs_logs}
MASTER_PORT_BASE=${MASTER_PORT_BASE:-47000}
NPERNODE=${NPERNODE:-8}

mkdir -p "$LOGDIR"

HOSTFILE="$HOSTFILE" \
NPERNODE="$NPERNODE" \
LOGDIR="$LOGDIR" \
MASTER_PORT_BASE="$MASTER_PORT_BASE" \
bash "$SCRIPT_DIR/allpair.sh"