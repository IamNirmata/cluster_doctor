
#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_FIFO="/tmp/allpair_control"
SSHD_PID=""
signal_sent=0


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

  # UPDATED: find recursively to handle round subdirectories
  mapfile -t log_files < <(find "$LOGDIR" -type f -name 'round*_job*.log' | sort)
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

  # INCREMENTAL UPDATE LOGIC
  # We use a tracking file to remember which logs we have already parsed.
  local tracking_file="${LOGDIR}/.processed_logs_tracker"
  touch "$tracking_file"
  
  # Load tracked files into a map for O(1) lookup
  declare -A processed_map
  while IFS= read -r line; do
    processed_map["$line"]=1
  done < "$tracking_file"

  # Find all log files RECURSIVELY (using -type f) to check subdirectories
  # This enables it to find logs inside LOGDIR/round1/, LOGDIR/round2/, etc.
  
  while IFS= read -r log_file; do
    # 1. Check if we have already processed this file
    if [[ -z "${processed_map[$log_file]}" ]]; then
        
        # 2. Check if the job is actually complete (has results)
        # We look for "busbw:" which indicates the benchmark finished.
        if grep -q "busbw:" "$log_file"; then
            
            local filename=$(basename "$log_file")
            # filename format: round<R>_job<J>_<node1>--<node2>.log
            
            # Extract round number
            local round_part="${filename%%_*}" # round0
            local round_num="${round_part#round}" # 0
            
            # We store the CSV in the root LOGDIR to keep aggregation simple
            local round_csv="${LOGDIR}/round_${round_num}_results.csv"
            
            # Create Header if the CSV doesn't exist yet
            if [[ ! -f "$round_csv" ]]; then
                echo "pair 1, pair 1 gcrnode, pair 2, pair 2 gcrnode, latency, busbw" > "$round_csv"
            fi

            # Parse Filename info
            # Remove prefix roundX_jobY_
            local temp="${filename#round*_job*_}"
            # Remove suffix .log
            temp="${temp%.log}"
            
            # Split by --
            local node1="${temp%--*}"
            local node2="${temp##*--}"
            
            # Extract Metrics
            # Calculate average latency
            local avg_latency=$(grep "latency:" "$log_file" | awk -F'latency: ' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; n++} END {if (n>0) printf "%.8f", sum/n; else print "0"}')
            
            # Calculate average busbw
            local avg_busbw=$(grep "busbw:" "$log_file" | awk -F'busbw: ' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; n++} END {if (n>0) printf "%.8f", sum/n; else print "0"}')
            
            # Lookup gcrnode names
            local gcrnode1="${node_map[$node1]:-unknown}"
            local gcrnode2="${node_map[$node2]:-unknown}"

            # Append to CSV
            echo "$node1, $gcrnode1, $node2, $gcrnode2, $avg_latency, $avg_busbw" >> "$round_csv"
            
            # Mark as processed so we don't scan it again
            echo "$log_file" >> "$tracking_file"
        fi
    fi
  done < <(find "$LOGDIR" -type f -name 'round*_job*.log' | sort)
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

trap 'code=$?; trap - EXIT; cleanup "$code"' EXIT



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



# Generate Hostfile
for host in ${VC_SERVER_HOSTS//,/ }; do
  echo "$host slots=8"
done > /opt/hostfile
for host in ${VC_CLIENT_HOSTS//,/ }; do
  echo "$host slots=8"
done >> /opt/hostfile

echo "Hostfile generated at /opt/hostfile"
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

# Use persistent storage for logs if available, to support checkpointing/resuming
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# LOGDIR LOGIC:
# 1. If LOGDIR is already set (e.g. from YAML env var), use it (Resume scenario).
# 2. If not set, create a new timestamped directory.
if [[ -z "${LOGDIR:-}" ]]; then
    if [[ -d "/data" ]]; then
        export LOGDIR="/data/allpair-logs/${TIMESTAMP}"
    else
        export LOGDIR="/opt/allpair-logs/${TIMESTAMP}"
    fi
    echo "LOGDIR was not set. Created new log directory: $LOGDIR"
else
    echo "LOGDIR is explicitly set. Resuming/Using directory: $LOGDIR"
fi

mkdir -p "$LOGDIR"

wait_for_clients

# Generate node_map.csv
echo "Generating node_map.csv..."
NODE_MAP_FILE="/opt/node_map.csv"
echo "pod_name,gcrnode" > "$NODE_MAP_FILE"

# Read hosts from hostfile
mapfile -t HOSTS < <(awk '{print $1}' "$HOSTFILE")

for host in "${HOSTS[@]}"; do
  # Run mpirun to get gcrnode from the remote host
  gcrnode=$(mpirun --allow-run-as-root -np 1 -H "$host" bash -c "cat /proc/1/environ | tr '\0' '\n' | grep ^gcrnode= | cut -d= -f2")
  
  if [[ -n "$gcrnode" ]]; then
      echo "$host,$gcrnode" >> "$NODE_MAP_FILE"
      echo "Mapped $host to $gcrnode"
  else
      echo "WARN: Could not retrieve gcrnode for $host"
      echo "$host,unknown" >> "$NODE_MAP_FILE"
  fi
done

echo "node_map.csv generated:"
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

echo "Starting automatic allpair run via $SCRIPT_DIR/allpair.sh"
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