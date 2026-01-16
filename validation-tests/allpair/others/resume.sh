#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_FIFO="/tmp/allpair_control"
SSHD_PID=""
signal_sent=0

# Allow resuming from a specific round (0-based). Default = 0 (start from beginning)
START_ROUND="${START_ROUND:-0}"
export START_ROUND

if (( START_ROUND > 0 )); then
  RESUME_MODE=1
  echo "Resume mode enabled (START_ROUND=${START_ROUND})"
else
  RESUME_MODE=0
fi
export RESUME_MODE

#SSH - wait for clients to be reachable via ssh
wait_for_clients() {
  if [[ -z "${VC_CLIENT_HOSTS:-}" ]]; then
    return 0
  fi

  IFS=',' read -ra raw_clients <<< "${VC_CLIENT_HOSTS}"
  for raw_host in "${raw_clients[@]}"; do
    local host
    host="$(echo "$raw_host" | xargs)"
    if [[ -z "$host" ]]; then
      continue
    fi

    echo "Waiting for SSH on $host ..."
    local ready=0
    for attempt in {1..600}; do
      if ssh -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            "$host" true >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 2
    done

    if (( ready == 0 )); then
      echo "ERROR: Unable to reach $host via SSH after waiting" >&2
      return 1
    fi
  done
}

# Print summary of all per-pair logs
print_log_summary() {
  if [[ ! -d "$LOGDIR" ]]; then
    echo "No log directory $LOGDIR found."
    return
  fi

  mapfile -t log_files < <(find "$LOGDIR" -maxdepth 1 -type f -name 'round*_job*.log' | sort)
  if (( ${#log_files[@]} == 0 )); then
    echo "No per-pair logs were generated in $LOGDIR."
    return
  fi

  echo "=== AllReduce log summary ($LOGDIR) ==="
  for log_file in "${log_files[@]}"; do
    echo "--- ${log_file} ---"
    if [[ -s "$log_file" ]]; then
      tail -n 20 "$log_file" || true
    else
      echo "(empty log)"
    fi
  done
  echo "=== End of log summary ==="
}

# Generate CSV report from logs
generate_csv_report() {
  if [[ ! -d "$LOGDIR" ]]; then
    return
  fi

  # Read node map into associative array
  declare -A node_map
  local node_map_file="/opt/node_map.csv"
  if [[ -f "$node_map_file" ]]; then
      while IFS=, read -r pod gcrnode; do
          if [[ "$pod" != "pod_name" ]]; then
              node_map["$pod"]="$gcrnode"
          fi
      done < "$node_map_file"
  fi

  # Clear existing round results to avoid duplicates during updates
  rm -f "${LOGDIR}/round_"*"_results.csv" 2>/dev/null || true

  mapfile -t log_files < <(find "$LOGDIR" -maxdepth 1 -type f -name 'round*_job*.log' | sort)

  for log_file in "${log_files[@]}"; do
    local filename
    filename=$(basename "$log_file")
    # filename format: round<R>_job<J>_<node1>--<node2>.log

    # Extract round number
    local round_part
    round_part="${filename%%_*}" # round0
    local round_num
    round_num="${round_part#round}" # 0
    local round_csv="${LOGDIR}/round_${round_num}_results.csv"

    if [[ ! -f "$round_csv" ]]; then
        echo "pair 1, pair 1 gcrnode, pair 2, pair 2 gcrnode, latency, busbw" > "$round_csv"
    fi

    # Remove prefix roundX_jobY_
    local temp
    temp="${filename#round*_job*_}"
    # Remove suffix .log
    temp="${temp%.log}"

    # Split by --
    local node1
    local node2
    node1="${temp%--*}"
    node2="${temp##*--}"

    # Calculate average latency
    local avg_latency
    avg_latency=$(grep "latency:" "$log_file" | awk -F'latency: ' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; n++} END {if (n>0) printf "%.8f", sum/n; else print "0"}')

    # Calculate average busbw
    local avg_busbw
    avg_busbw=$(grep "busbw:" "$log_file" | awk -F'busbw: ' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; n++} END {if (n>0) printf "%.8f", sum/n; else print "0"}')

    # Lookup gcrnode names
    local gcrnode1
    local gcrnode2
    gcrnode1="${node_map[$node1]:-unknown}"
    gcrnode2="${node_map[$node2]:-unknown}"

    echo "$node1, $gcrnode1, $node2, $gcrnode2, $avg_latency, $avg_busbw" >> "$round_csv"
  done
}

# Send completion signal to all clients
send_completion() {
  local code=${1:-0}
  if (( signal_sent == 1 )); then
    return
  fi

  if [[ -z "${VC_CLIENT_HOSTS:-}" ]]; then
    signal_sent=1
    return
  fi

  IFS=',' read -ra raw_clients <<< "${VC_CLIENT_HOSTS}"
  local clients=()
  for host in "${raw_clients[@]}"; do
    host="${host//[[:space:]]/}"
    if [[ -n "$host" ]]; then
      clients+=("$host")
    fi
  done

  local count=${#clients[@]}
  if (( count == 0 )); then
    signal_sent=1
    return
  fi

  local hostlist
  hostlist=$(IFS=','; echo "${clients[*]}")

  local message="done"
  if (( code != 0 )); then
    message="failed"
  fi

  export COMPLETION_MESSAGE="$message"
  export ALLPAIR_CONTROL_FIFO="$CONTROL_FIFO"

  set +e
  mpirun \
    --allow-run-as-root \
    --tag-output \
    --map-by ppr:1:node \
    -np "$count" \
    --host "$hostlist" \
    -x COMPLETION_MESSAGE \
    -x ALLPAIR_CONTROL_FIFO \
    bash -lc 'printf "%s\n" "${COMPLETION_MESSAGE:-done}" > "${ALLPAIR_CONTROL_FIFO:-/tmp/allpair_control}"'
  if [[ $? -ne 0 ]]; then
    echo "WARN: Unable to broadcast completion marker via mpirun" >&2
  fi
  set -e

  signal_sent=1
}

# Cleanup function to handle script termination
cleanup() {
  local code=${1:-0}

  if (( signal_sent == 0 )); then
    send_completion "$code"
  fi

  set +e
  if [[ -n "${SSHD_PID:-}" ]]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  rm -f "$CONTROL_FIFO"
  set -e
}

trap 'code=$?; trap - EXIT; cleanup "$code"; exit "$code"' EXIT

# Set up environment
export DEBIAN_FRONTEND=noninteractive

for i in {1..5}; do apt-get update -y && break || sleep 15; done
apt-get install -y --no-install-recommends \
  openssh-server \
  openssh-client \
  ca-certificates \
  ibverbs-utils \
  rdmacm-utils \
  perftest \
  infiniband-diags

mkdir -p /run/sshd
ssh-keygen -A
/usr/sbin/sshd -D -e &
SSHD_PID=$!

rm -f "$CONTROL_FIFO"
mkfifo "$CONTROL_FIFO"

# --- Hostfile setup (skippable in resume mode if already present) ---
if (( RESUME_MODE == 0 )); then
  echo "Generating /opt/hostfile (fresh run)..."
  for host in ${VC_SERVER_HOSTS//,/ }; do
    echo "$host slots=8"
  done > /opt/hostfile
  for host in ${VC_CLIENT_HOSTS//,/ }; do
    echo "$host slots=8"
  done >> /opt/hostfile
else
  if [[ -f /opt/hostfile ]]; then
    echo "Resume mode: using existing /opt/hostfile"
  else
    echo "Resume mode: /opt/hostfile missing; regenerating..."
    for host in ${VC_SERVER_HOSTS//,/ }; do
      echo "$host slots=8"
    done > /opt/hostfile
    for host in ${VC_CLIENT_HOSTS//,/ }; do
      echo "$host slots=8"
    done >> /opt/hostfile
  fi
fi

echo "Hostfile at /opt/hostfile"
echo "#########################Hostfile#########################"
cat /opt/hostfile
echo "##########################################################"

# Clone Cluster Validation Runbook repository if it is not already present
if [[ ! -d /opt/Cluster-Validation-Runbook/.git ]]; then
  git clone https://github.com/IamNirmata/Cluster-Validation-Runbook.git /opt/Cluster-Validation-Runbook
else
  echo "Cluster-Validation-Runbook already present at /opt; skipping clone."
fi

echo "#########################Hostfile#########################"
cat /opt/hostfile
echo "##########################################################"

export HOSTFILE=/opt/hostfile

# Use persistent storage for logs if available, and allow reusing an existing LOGDIR
if [[ -n "${LOGDIR:-}" ]]; then
    echo "Using existing LOGDIR: $LOGDIR"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [[ -d "/data" ]]; then
        LOGDIR="/data/allpair-logs/${TIMESTAMP}"
    else
        LOGDIR="/opt/allpair-logs/${TIMESTAMP}"
    fi
    echo "LOGDIR was not set; using new directory: $LOGDIR"
fi

export LOGDIR
mkdir -p "$LOGDIR"
echo "Logs will be written to: $LOGDIR"

wait_for_clients

# --- node_map.csv (skippable in resume mode if already present) ---
echo "Generating or reusing node_map.csv..."
NODE_MAP_FILE="/opt/node_map.csv"

if (( RESUME_MODE == 1 )) && [[ -f "$NODE_MAP_FILE" ]]; then
  echo "Resume mode: using existing $NODE_MAP_FILE"
else
  echo "pod_name,gcrnode" > "$NODE_MAP_FILE"

  # Read hosts from hostfile
  mapfile -t HOSTS < <(awk '{print $1}' "$HOSTFILE")

  for host in "${HOSTS[@]}"; do
    # We assume 'gcrnode' env var is available on the remote host
    gcrnode=$(mpirun --allow-run-as-root -np 1 -H "$host" bash -c "cat /proc/1/environ | tr '\0' '\n' | grep ^gcrnode= | cut -d= -f2")

    if [[ -n "$gcrnode" ]]; then
        echo "$host,$gcrnode" >> "$NODE_MAP_FILE"
        echo "Mapped $host to $gcrnode"
    else
        echo "WARN: Could not retrieve gcrnode for $host"
        echo "$host,unknown" >> "$NODE_MAP_FILE"
    fi
  done
fi

echo "node_map.csv:"
echo "##### Contents of $NODE_MAP_FILE #####"
cat "$NODE_MAP_FILE"
echo "##### End of $NODE_MAP_FILE #####"

# Start a background process to update results.csv periodically
(
  while true; do
    sleep 30
    generate_csv_report
  done
) &
REPORT_PID=$!

echo "Starting automatic allpair run via $SCRIPT_DIR/allpair.sh (START_ROUND=${START_ROUND}, RESUME_MODE=${RESUME_MODE})"
if bash "$SCRIPT_DIR/allpair.sh"; then
  kill "$REPORT_PID" || true
  print_log_summary
  generate_csv_report
else
  status=$?
  kill "$REPORT_PID" || true
  echo "allpair.sh exited with status $status" >&2
  print_log_summary
  generate_csv_report
  exit "$status"
fi
