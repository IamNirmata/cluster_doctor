#!/usr/bin/env bash
set -euo pipefail

# pod-age.sh (GPU pods only, RUNNING only)
# Requires: kubectl, jq, coreutils (date, sort, head, awk, cut, wc, mktemp)
#
# What it does:
#  1) Lists ONLY pods across all namespaces that request/limit nvidia.com/gpu (>0)
#  2) Considers ONLY Running pods
#  3) Computes age stats (avg, stddev, min, max, median, p90, p99)
#  4) Prints an age histogram + Top N oldest GPU pods

KUBECTL="${KUBECTL:-kubectl}"
RESOURCE_KEY="${RESOURCE_KEY:-nvidia.com/gpu}"
TOP_N="${TOP_N:-50}"

now_epoch="$(date -u +%s)"

tmp_tsv="$(mktemp -t gpu_pods_age.XXXXXX.tsv)"
ages_sorted="$(mktemp -t gpu_pods_age.XXXXXX.ages)"
trap 'rm -f "$tmp_tsv" "$ages_sorted"' EXIT

# Emit TSV:
# age_sec \t ns \t pod \t node \t phase \t gpu_total \t created_ts
"$KUBECTL" get pods -A -o json | jq -r --arg rk "$RESOURCE_KEY" --argjson now "$now_epoch" '
  def to_num(x): (x // "0") | (if type=="number" then . else (tostring|tonumber) end);
  def c_gpu(c):
    (to_num(c.resources.requests[$rk]) // 0) as $req |
    (to_num(c.resources.limits[$rk])   // 0) as $lim |
    (if $req > $lim then $req else $lim end);
  def pod_uses_gpu(p):
    (
      ([ p.spec.containers[]?     | c_gpu(.) ] | add) // 0
    ) as $app |
    (
      ([ p.spec.initContainers[]? | c_gpu(.) ] | max) // 0
    ) as $init |
    # "effective" GPU for this pod: app sum + init max (init can run sequentially)
    (if ($app > 0) or ($init > 0) then ($app + $init) else 0 end);

  .items[]
  | select(.status.phase == "Running")
  | . as $p
  | (pod_uses_gpu($p)) as $g
  | select($g > 0)
  | ($p.metadata.creationTimestamp // "") as $cts
  | ($cts | fromdateiso8601) as $created_epoch
  | ($now - $created_epoch) as $age
  | [
      $age,
      ($p.metadata.namespace // "-"),
      ($p.metadata.name // "-"),
      ($p.spec.nodeName // "-"),
      ($p.status.phase // "-"),
      $g,
      $cts
    ]
  | @tsv
' > "$tmp_tsv"

count="$(wc -l < "$tmp_tsv" | tr -d ' ')"

if [[ "$count" == "0" ]]; then
  echo "No RUNNING GPU pods found (resource key: $RESOURCE_KEY)."
  exit 0
fi

echo "RUNNING GPU pods found: $count  (resource key: $RESOURCE_KEY)"
echo

# ---- Stats: avg/stddev/min/max ----
awk -F'\t' '
  function human(sec,  d,h,m,s,out) {
    d=int(sec/86400); sec%=86400;
    h=int(sec/3600);  sec%=3600;
    m=int(sec/60);    s=sec%60;
    out="";
    if (d>0) out=out d "d ";
    if (h>0 || d>0) out=out h "h ";
    if (m>0 || h>0 || d>0) out=out m "m ";
    out=out s "s";
    return out;
  }
  BEGIN { n=0; mean=0; m2=0; min=1e18; max=0; }
  {
    x=$1+0;
    n++;
    if (x<min) min=x;
    if (x>max) max=x;
    delta = x - mean;
    mean += delta / n;
    m2   += delta * (x - mean);
  }
  END {
    var = (n>1) ? (m2/(n-1)) : 0;
    sd  = sqrt(var);
    printf("Age stats (seconds):\n");
    printf("  avg     = %.2f  (%s)\n", mean, human(mean));
    printf("  stddev  = %.2f  (%s)\n", sd,   human(sd));
    printf("  min     = %d    (%s)\n", min,  human(min));
    printf("  max     = %d    (%s)\n", max,  human(max));
  }
' "$tmp_tsv"

echo

# ---- Percentiles (median/p90/p99) ----
cut -f1 "$tmp_tsv" | sort -n > "$ages_sorted"

get_pct() {
  local pct="$1"
  local n rank
  n="$(wc -l < "$ages_sorted" | tr -d ' ')"
  rank="$(awk -v p="$pct" -v n="$n" 'BEGIN{
    r=int((p/100.0)*n);
    if ((p/100.0)*n > r) r++;   # ceil
    if (r<1) r=1;
    if (r>n) r=n;
    print r;
  }')"
  awk -v r="$rank" 'NR==r{print $1; exit}' "$ages_sorted"
}

humanize_sec() {
  awk -v sec="$1" 'BEGIN{
    d=int(sec/86400); sec%=86400;
    h=int(sec/3600);  sec%=3600;
    m=int(sec/60);    s=sec%60;
    out="";
    if (d>0) out=out d "d ";
    if (h>0 || d>0) out=out h "h ";
    if (m>0 || h>0 || d>0) out=out m "m ";
    out=out s "s";
    print out;
  }'
}

p50="$(get_pct 50)"
p90="$(get_pct 90)"
p99="$(get_pct 99)"

echo "Percentiles (nearest-rank):"
echo "  median (p50) = ${p50}s  ($(humanize_sec "$p50"))"
echo "  p90          = ${p90}s  ($(humanize_sec "$p90"))"
echo "  p99          = ${p99}s  ($(humanize_sec "$p99"))"
echo

# ---- Histogram ----
echo "Age histogram:"
awk -F'\t' '
  function bucket(sec){
    if (sec < 3600) return "<1h";
    if (sec < 21600) return "1-6h";
    if (sec < 86400) return "6-24h";
    if (sec < 259200) return "1-3d";
    if (sec < 604800) return "3-7d";
    return ">=7d";
  }
  { b=bucket($1+0); c[b]++; total++; }
  END{
    order[1]="<1h"; order[2]="1-6h"; order[3]="6-24h"; order[4]="1-3d"; order[5]="3-7d"; order[6]=">=7d";
    for(i=1;i<=6;i++){
      k=order[i];
      v=(k in c)?c[k]:0;
      pct=(total>0)?(100.0*v/total):0;
      printf("  %-6s : %6d (%.1f%%)\n", k, v, pct);
    }
  }
' "$tmp_tsv"
echo

# ---- Top N oldest ----
echo "Top ${TOP_N} oldest RUNNING GPU pods:"
echo -e "AGE\tNAMESPACE\tPOD\tNODE\tPHASE\tGPU\tCREATED"

sort -t$'\t' -k1,1nr "$tmp_tsv" \
  | head -n "$TOP_N" \
  | awk -F'\t' '
      function human(sec,  d,h,m,s,out) {
        d=int(sec/86400); sec%=86400;
        h=int(sec/3600);  sec%=3600;
        m=int(sec/60);    s=sec%60;
        out="";
        if (d>0) out=out d "d ";
        if (h>0 || d>0) out=out h "h ";
        if (m>0 || h>0 || d>0) out=out m "m ";
        out=out s "s";
        return out;
      }
      {
        age=$1+0;
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", human(age), $2, $3, $4, $5, $6, $7;
      }
    '
