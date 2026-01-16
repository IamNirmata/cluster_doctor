#!/bin/bash
set -e

LOGDIR=$1
NODE_COUNT=$2
OUTPUT_FILE="${LOGDIR}/allpair_${NODE_COUNT}_nodes.csv"

if [[ ! -d "$LOGDIR" ]]; then
    echo "Error: Log directory $LOGDIR does not exist."
    exit 1
fi

echo "round number, pair 1, node 1, pair 2, node 2, latency, busbw" > "$OUTPUT_FILE"

# Find all round csvs sorted by version number (so round_2 comes after round_1, not round_10)
mapfile -t round_files < <(find "$LOGDIR" -maxdepth 1 -name "round_*_results.csv" | sort -V)

for round_csv in "${round_files[@]}"; do
    # Extract round number from filename: round_0_results.csv -> 0
    fname=$(basename "$round_csv")
    # Use regex to extract the number between 'round_' and '_results.csv'
    if [[ $fname =~ round_([0-9]+)_results.csv ]]; then
        r_num="${BASH_REMATCH[1]}"
    else
        r_num="unknown"
    fi
    
    # Read lines, skip header (line 1)
    # We use tail -n +2 to output starting from line 2
    if [[ -f "$round_csv" ]]; then
        tail -n +2 "$round_csv" | while IFS= read -r line; do
            # line is like: node1, gcrnode1, node2, gcrnode2, lat, bw
            # We prepend round number
            echo "$r_num, $line" >> "$OUTPUT_FILE"
        done
    fi
done

echo "Aggregated results generated at $OUTPUT_FILE"
cat "$OUTPUT_FILE"
