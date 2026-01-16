#!/usr/bin/env bash
set -eo pipefail

CONTROL_FIFO="/tmp/allpair_control"
SSHD_PID=""

cleanup() {
  local code=${1:-0}
  set +e
  if [[ -n "${SSHD_PID:-}" ]]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  rm -f "$CONTROL_FIFO"
  set -e
  exit "$code"
}

trap 'code=$?; trap - EXIT; cleanup "$code"' EXIT

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

SERVER_HOST="$(tr ',' '\n' < /etc/volcano/VC_SERVER_HOSTS | head -n1)"
echo "Waiting for server host to be reachable: ${SERVER_HOST}"


if [[ -z "${SERVER_HOST}" ]]; then
  echo "VC_SERVER_HOSTS empty or missing" >&2
  exit 1
fi
echo "Server host: ${SERVER_HOST}"
for _ in $(seq 1 600); do
  if getent hosts "${SERVER_HOST}" >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for DNS ${SERVER_HOST}"
  sleep 2
done

for host in ${VC_SERVER_HOSTS//,/ }; do
  echo "$host slots=8"
done > /opt/hostfile
for host in ${VC_CLIENT_HOSTS//,/ }; do
  echo "$host slots=8"
done >> /opt/hostfile

echo "#########################Hostfile#########################"
cat /opt/hostfile
echo "##########################################################"

if [[ ! -d /opt/Cluster-Validation-Runbook/.git ]]; then
  git clone https://github.com/IamNirmata/Cluster-Validation-Runbook.git /opt/Cluster-Validation-Runbook
else
  echo "Cluster-Validation-Runbook already present at /opt; skipping clone."
fi
rm -f "$CONTROL_FIFO"
mkfifo "$CONTROL_FIFO"
chmod 600 "$CONTROL_FIFO"

echo "Client waiting for completion marker at $CONTROL_FIFO"
if read -r completion_msg <"$CONTROL_FIFO"; then
  echo "Completion marker received: $completion_msg"
else
  echo "WARN: Completion channel closed without marker" >&2
fi

echo "Client received shutdown signal; exiting."
