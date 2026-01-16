#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: allpair.sh failed at line $LINENO" >&2' ERR

if [[ "${ALLPAIR_DEBUG:-0}" == "1" ]]; then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------- CONFIG (edit) --------------------------
DEFAULT_HOSTFILE="$SCRIPT_DIR/test_files/hostfile"
DEFAULT_GEN_SCRIPT="$SCRIPT_DIR/generate_permutations.py"
DEFAULT_LOGDIR="$SCRIPT_DIR/logs"
DEFAULT_NET_IFACE="${NET_IFACE:-eth0}"

HOSTFILE="${HOSTFILE:-$DEFAULT_HOSTFILE}"
GEN_SCRIPT="${GEN_SCRIPT:-$DEFAULT_GEN_SCRIPT}"  # path to the Python generator
NPERNODE="${NPERNODE:-8}"         # processes per node
NP_TOTAL="${NP_TOTAL:-$((2 * NPERNODE))}"   # -np (total ranks across both nodes)
LOGDIR="${LOGDIR:-$DEFAULT_LOGDIR}" # where per-pair logs go
MASTER_PORT_BASE="${MASTER_PORT_BASE:-45566}" # will use BASE + job_idx per round
EXTRA_MPI_ARGS="${EXTRA_MPI_ARGS:-}" # e.g., "--mca pml ucx --mca btl ^openib"
NET_IFACE="${NET_IFACE:-$DEFAULT_NET_IFACE}"

# Allow resuming from a specific round (default 0)
START_ROUND="${START_ROUND:-0}"

# TIMEOUT CONFIGURATION
# Default: 600 seconds (10 minutes).
# The -k option kills the process if it's still running 10s after the timeout.
JOB_TIMEOUT_SEC="${JOB_TIMEOUT_SEC:-600}"

# Example NCCL/other envs; add/remove as needed:
export NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
export LOCAL_WORLD="${LOCAL_WORLD:-$NPERNODE}"
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-$NET_IFACE}"

if [[ -n "${APP_CMD_OVERRIDE:-}" ]]; then
  # Allow overriding the application command via APP_CMD_OVERRIDE="python myscript.py --flag"
  read -r -a APP_CMD <<<"${APP_CMD_OVERRIDE}"
else
  APP_CMD=(
    python "$SCRIPT_DIR/npairs.py"
  )
fi
# ------------------------------------------------------------------

mkdir -p "$LOGDIR"

# Cleanly stop all children on exit/ctrl-c
cleanup() {
  pkill -P $$ || true
}
trap cleanup EXIT INT TERM

# -------------------------- INPUTS --------------------------

# 1) Load nodes from hostfile (first column)
if [[ ! -f "$HOSTFILE" ]]; then
  echo "ERROR: Hostfile not found at: $HOSTFILE" >&2
  exit 1
fi

# shellcheck disable=SC2207
mapfile -t NODES < <(awk '{print $1}' "$HOSTFILE" | sed '/^\s*$/d')

N="${#NODES[@]}"
if (( N < 2 )); then
  echo "ERROR: Need at least 2 nodes in $HOSTFILE; found $N" >&2
  exit 1
fi

echo "Loaded $N nodes from $HOSTFILE"
# Optional: show them
printf '  %s\n' "${NODES[@]}"

# 2) Generate the per-round all-pair schedule and load into combinations[]
#    We strip the leading spaces and surrounding quotes to get a clean line.
if [[ ! -x "$GEN_SCRIPT" && ! -f "$GEN_SCRIPT" ]]; then
  echo "ERROR: Generator script not found: $GEN_SCRIPT" >&2
  exit 1
fi

# shellcheck disable=SC2207
mapfile -t combinations < <(
  python3 "$GEN_SCRIPT" --nitems "$N" --format text \
    | sed 's/^[[:space:]]*//; s/^"//; s/"$//'
)

if (( ${#combinations[@]} == 0 )); then
  echo "ERROR: No combinations produced by generator." >&2
  exit 1
fi

echo "Schedule has ${#combinations[@]} rounds; ~$(($N/2)) pairs per round."

# print all combinations (optional)
for combo in "${combinations[@]}"; do
  echo "  $combo"
done

# -------------------------- RUN ROUNDS --------------------------
round_idx=0
for combo in "${combinations[@]}"; do
  
  # --- RESUME LOGIC: Fast-forward if START_ROUND is set ---
  if (( round_idx < START_ROUND )); then
      ((round_idx++)) || true
      continue
  fi

  echo
  echo "=== Round $round_idx ==="
  
  # --- DIRECTORY ORGANIZATION START ---
  # Create a specific directory for this round
  ROUND_DIR="${LOGDIR}/round${round_idx}"
  mkdir -p "$ROUND_DIR"
  # ------------------------------------

  # combo format: '0 9 | 1 8 | 2 7 | ...'
  IFS='|' read -r -a pairs <<< "$combo"

  job_idx=0
  pids=()
  round_logs=()

  for pair in "${pairs[@]}"; do
    # trim spaces & split indices
    pair=$(echo "$pair" | xargs)
    # shellcheck disable=SC2206
    idx=($pair)
    if (( ${#idx[@]} != 2 )); then
      echo "WARN: malformed pair: '$pair' (skipping)" >&2
      continue
    fi

    i="${idx[0]}"
    j="${idx[1]}"
    node1="${NODES[$i]}"
    node2="${NODES[$j]}"
    # print node names for debugging
    echo "  Pair: $i($node1) & $j($node2)"
    if [[ -z "${node1:-}" || -z "${node2:-}" ]]; then
      echo "WARN: index out of range in pair '$pair' (skipping)" >&2
      continue
    fi

    # Unique-ish port per job in a round
    master_port=$((MASTER_PORT_BASE + job_idx))
    echo "    Master port: $master_port"

    # Save log file INSIDE the round directory
    log_file="${ROUND_DIR}/round${round_idx}_job${job_idx}_${node1}--${node2}.log"

    # Checkpoint check: if log exists and contains "busbw:", assume success and skip
    if [[ -f "$log_file" ]] && grep -q "busbw:" "$log_file"; then
        echo "Skipping Round $round_idx Job $job_idx ($node1 & $node2) - already completed."
        ((job_idx++)) || true
        continue
    fi

    echo "Launching Job${job_idx}: $node1 & $node2  -> $log_file"


    # Kick off MPI job in background
    # Build optional extras array from string
    extras=()
    if [[ -n "${EXTRA_MPI_ARGS:-}" ]]; then
      # shellcheck disable=SC2206
      extras=($EXTRA_MPI_ARGS)
    fi

    # Compose command with TIMEOUT
    # We wrap mpirun in 'timeout'. 
    # If it runs longer than JOB_TIMEOUT_SEC, it sends SIGTERM.
    # If it ignores that for 10 more seconds, it sends SIGKILL (-k).
    mp_cmd=(
      timeout 
      -k "$((JOB_TIMEOUT_SEC + 10))" 
      "$JOB_TIMEOUT_SEC"
      mpirun
      --tag-output
      --display-map
      --allow-run-as-root
      --bind-to none
      --mca btl_tcp_if_include "${NET_IFACE}"
      --mca oob_tcp_if_include "${NET_IFACE}"
      -np "$NP_TOTAL"
      -H "${node1}:${NPERNODE},${node2}:${NPERNODE}"
      -x LOCAL_WORLD
      -x NCCL_DEBUG
      -x NCCL_SOCKET_IFNAME
      -x "MASTER_ADDR=${node1}"
      -x "MASTER_PORT=${master_port}"
      "${extras[@]}"
      "${APP_CMD[@]}"
    )

    echo "    Log file: $log_file"
    : >"$log_file"  # touch/clear log file

    # Run in background with logging and capture PID for round coordination
    "${mp_cmd[@]}" >>"$log_file" 2>&1 &
    pid=$!
    pids+=("$pid")
    round_logs+=("$log_file")

    # Optionally show the command for debugging.
    echo "    Running: ${mp_cmd[*]}"
    ((job_idx++)) || true
  done

  
  # Wait for all jobs in this round to finish
  fail=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      fail=1
    fi
  done

  if (( fail != 0 )); then
    echo "Round $round_idx: one or more jobs failed/timed-out (see logs in $LOGDIR)" >&2
    # We continue to the next round even if jobs failed
  else
    echo "Round $round_idx: all jobs completed successfully."
  fi

  if (( ${#round_logs[@]} > 0 )); then
    echo "Round $round_idx logs:"
    for lf in "${round_logs[@]}"; do
      echo "  $lf"
    done
  fi
  ((round_idx++)) || true
done

echo
echo "All rounds complete. Logs in: $LOGDIR"