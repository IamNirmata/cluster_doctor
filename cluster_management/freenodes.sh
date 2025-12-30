# #!/usr/bin/env bash
# set -euo pipefail

# # Build: node -> used GPUs (sum of per-pod effective GPU request)
# USED_JSON="$(
#   kubectl get pods -A -o json | jq -c '
#     reduce (
#       .items[]
#       | select(.spec.nodeName? != null)
#       | select(.status.phase != "Succeeded" and .status.phase != "Failed")
#       | {
#           node: .spec.nodeName,
#           app: (
#             ([ .spec.containers[]? | (.resources.requests["nvidia.com/gpu"] // "0") ] | map(tonumber) | add) // 0
#           ),
#           init: (
#             ([ .spec.initContainers[]? | (.resources.requests["nvidia.com/gpu"] // "0") ] | map(tonumber) | max) // 0
#           )
#         }
#       | .g = (if .app > .init then .app else .init end)
#     ) as $p ({}; .[$p.node] = ((.[$p.node] // 0) + $p.g))
#   '
# )"

# tcap=0; talloc=0; tused=0; tfree=0

# while read -r n cap alloc; do
#   cap=${cap:-0};   [[ "$cap"   == "<none>" ]] && cap=0
#   alloc=${alloc:-0}; [[ "$alloc" == "<none>" ]] && alloc=0

#   used="$(jq -r --arg n "$n" '.[$n] // 0' <<<"$USED_JSON")"
#   free=$(( alloc - used ))

#   printf "%-45s  cap=%3d  alloc=%3d  used=%3d  free=%3d\n" "$n" "$cap" "$alloc" "$used" "$free"

#   tcap=$((tcap+cap)); talloc=$((talloc+alloc)); tused=$((tused+used)); tfree=$((tfree+free))
# done < <(
#   kubectl get nodes --no-headers \
#     -o custom-columns="NAME:.metadata.name,CAP:.status.capacity.nvidia\.com/gpu,ALLOC:.status.allocatable.nvidia\.com/gpu" \
#   | grep hgx
# )

# echo
# echo "TOTAL: cap=$tcap  alloc=$talloc  used=$tused  free=$tfree"


#!/usr/bin/env bash
set -euo pipefail

PAR=${PAR:-12}          # parallelism (try 8/12/16)
CHUNK=${CHUNK:-5000}

declare -A USED

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# 1) Fetch pods per-namespace in parallel and emit: node<TAB>gpus
kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
| xargs -n1 -P "$PAR" -I{} bash -c '
  ns="$1"
  kubectl get pods -n "$ns" \
    --field-selector=spec.nodeName!=,status.phase!=Succeeded,status.phase!=Failed \
    --chunk-size='"$CHUNK"' \
    -o json 2>/dev/null \
  | jq -r "
      .items[]
      | .spec.nodeName as \$n
      | (
          ([.spec.containers[]?     | (.resources.requests[\"nvidia.com/gpu\"] // \"0\")]
           | map(tonumber) | add) // 0
        ) as \$app
      | (
          ([.spec.initContainers[]? | (.resources.requests[\"nvidia.com/gpu\"] // \"0\")]
           | map(tonumber) | max) // 0
        ) as \$init
      | (\$app, \$init | max) as \$g
      | select(\$g > 0)
      | \"\(\$n)\t\(\$g)\"
    "
' _ {} >> "$tmp"

# 2) Aggregate node GPU usage (single pass)
while IFS=$'\t' read -r node used; do
  USED["$node"]="$used"
done < <(
  awk -F'\t' '{u[$1]+=$2} END{for (n in u) print n "\t" u[n]}' "$tmp"
)

tcap=0; talloc=0; tused=0; tfree=0

# 3) Print nodes
while read -r n cap alloc; do
  cap=${cap:-0};     [[ "$cap"   == "<none>" ]] && cap=0
  alloc=${alloc:-0}; [[ "$alloc" == "<none>" ]] && alloc=0

  used=${USED["$n"]:-0}
  free=$(( alloc - used ))

  printf "%-45s  cap=%3d  alloc=%3d  used=%3d  free=%3d\n" "$n" "$cap" "$alloc" "$used" "$free"

  tcap=$((tcap+cap)); talloc=$((talloc+alloc)); tused=$((tused+used)); tfree=$((tfree+free))
done < <(
  kubectl get nodes --no-headers \
    -o custom-columns="NAME:.metadata.name,CAP:.status.capacity.nvidia\.com/gpu,ALLOC:.status.allocatable.nvidia\.com/gpu" \
  | grep hgx
)

echo
echo "TOTAL: cap=$tcap  alloc=$talloc  used=$tused  free=$tfree"
