#!/usr/bin/env bash
set -euo pipefail


usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -o, --out PATH     Path to save fully free nodes list (default: ./free_nodes.txt or \$OUT)
  -h, --help         Show this help

Examples:
  $0
  $0 -o /tmp/free_nodes.txt
  OUT=/data/free_nodes.txt $0
EOF
}

# Defaults (env var still supported)
OUT_DEFAULT="${OUT:-./free_nodes.txt}"
OUT_PATH="$OUT_DEFAULT"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for $1" >&2; usage; exit 2; }
      OUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# Ensure output directory exists (if a directory was provided)
OUT_DIR="$(dirname "$OUT_PATH")"
mkdir -p "$OUT_DIR"

: > "$OUT_PATH"   # truncate output file

# Build: node -> used GPUs (sum of per-pod effective GPU request)
USED_JSON="$(
  kubectl get pods -A -o json | jq -c '
    reduce (
      .items[]
      | select(.spec.nodeName? != null)
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | {
          node: .spec.nodeName,
          app: (
            ([ .spec.containers[]? | (.resources.requests["nvidia.com/gpu"] // "0") ] | map(tonumber) | add) // 0
          ),
          init: (
            ([ .spec.initContainers[]? | (.resources.requests["nvidia.com/gpu"] // "0") ] | map(tonumber) | max) // 0
          )
        }
      | .g = (if .app > .init then .app else .init end)
    ) as $p ({}; .[$p.node] = ((.[$p.node] // 0) + $p.g))
  '
)"

tcap=0; talloc=0; tused=0; tfree=0

while read -r n cap alloc; do
  cap=${cap:-0};     [[ "$cap"   == "<none>" ]] && cap=0
  alloc=${alloc:-0}; [[ "$alloc" == "<none>" ]] && alloc=0

  used="$(jq -r --arg n "$n" '.[$n] // 0' <<<"$USED_JSON")"
  free=$(( alloc - used ))

  printf "%-45s  cap=%3d  alloc=%3d  used=%3d  free=%3d\n" "$n" "$cap" "$alloc" "$used" "$free"

  # Save fully free nodes (no GPU usage at all)
  if [[ "$alloc" -gt 0 && "$used" -eq 0 ]]; then
    echo "$n" >> "$OUT_PATH"
  fi

  tcap=$((tcap+cap)); talloc=$((talloc+alloc)); tused=$((tused+used)); tfree=$((tfree+free))
done < <(
  kubectl get nodes --no-headers \
    -o custom-columns="NAME:.metadata.name,CAP:.status.capacity.nvidia\.com/gpu,ALLOC:.status.allocatable.nvidia\.com/gpu" \
  | grep hgx
)

echo
echo "TOTAL: cap=$tcap  alloc=$talloc  used=$tused  free=$tfree"
echo "Fully free nodes saved to: $OUT_PATH"

