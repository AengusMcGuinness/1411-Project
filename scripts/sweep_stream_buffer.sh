#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sweep_stream_buffer.sh [-o output.csv] trace1 [trace2 ...]

Runs the standalone stream-buffer simulator over a grid of parameter values
and prints a CSV table ranked by the selected configuration fields.

Environment knobs:
  BIN                     Simulator binary to run (default: ./build/stream_buffer_sim)
  LINE_SIZE               Cache-line size in bytes (default: 64)
  DEMAND_CACHE_LINES      Demand-cache capacity (default: 4096)
  PREFETCH_BUFFER_LINES    Prefetch-buffer capacity (default: 16)
  PREFETCH_LATENCY        Prefetch arrival latency (default: 8)
  MISS_LATENCY            Demand-miss latency (default: 80)
  HIT_LATENCY             Cache-hit latency (default: 1)
  WRITE_LATENCY           Write-hit latency (default: 1)
  BASE_COST               Per-reference overhead (default: 1)

  POLICIES                Space-separated policy list (default: adaptive)
  STREAM_SLOTS_LIST       Space-separated list (default: 4 8 16)
  MAX_STREAM_LENGTHS      Space-separated list (default: 8 16)
  EPOCH_READS_LIST        Space-separated list (default: 1000 2000 4000)
  STREAM_LIFETIMES        Space-separated list (default: 128 256)
  MAX_PREFETCH_DEPTHS     Space-separated list (default: 1 2 4)
  BOOTSTRAPS              Space-separated list of 0/1 values (default: 1 0)

Tip: keep the cache-size and latency knobs fixed while sweeping the adaptive
policy knobs first. That usually gives a much more meaningful search.
EOF
}

output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 1
            fi
            output_file="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

BIN=${BIN:-./build/stream_buffer_sim}
if [[ ! -x "$BIN" ]]; then
    echo "Simulator binary not found or not executable: $BIN" >&2
    exit 1
fi

LINE_SIZE=${LINE_SIZE:-64}
DEMAND_CACHE_LINES=${DEMAND_CACHE_LINES:-4096}
PREFETCH_BUFFER_LINES=${PREFETCH_BUFFER_LINES:-16}
PREFETCH_LATENCY=${PREFETCH_LATENCY:-8}
MISS_LATENCY=${MISS_LATENCY:-80}
HIT_LATENCY=${HIT_LATENCY:-1}
WRITE_LATENCY=${WRITE_LATENCY:-1}
BASE_COST=${BASE_COST:-1}

POLICIES=${POLICIES:-"adaptive"}
STREAM_SLOTS_LIST=${STREAM_SLOTS_LIST:-"4 8 16"}
MAX_STREAM_LENGTHS=${MAX_STREAM_LENGTHS:-"8 16"}
EPOCH_READS_LIST=${EPOCH_READS_LIST:-"1000 2000 4000"}
STREAM_LIFETIMES=${STREAM_LIFETIMES:-"128 256"}
MAX_PREFETCH_DEPTHS=${MAX_PREFETCH_DEPTHS:-"1 2 4"}
BOOTSTRAPS=${BOOTSTRAPS:-"1 0"}

traces=("$@")

if [[ -n "$output_file" ]]; then
    exec >"$output_file"
fi

printf '%s\n' \
    'policy,line_size,demand_cache_lines,prefetch_buffer_lines,stream_slots,max_stream_length,epoch_reads,stream_lifetime,prefetch_latency,miss_latency,hit_latency,write_latency,base_cost,max_prefetch_depth,bootstrap_next_line,avg_speedup,avg_selected_cycles,avg_baseline_cycles'

run_one() {
    local policy="$1"
    local stream_slots="$2"
    local max_stream_length="$3"
    local epoch_reads="$4"
    local stream_lifetime="$5"
    local max_prefetch_depth="$6"
    local bootstrap="$7"
    local trace="$8"

    local args=(
        "$BIN"
        --policy "$policy"
        --line-size "$LINE_SIZE"
        --demand-cache-lines "$DEMAND_CACHE_LINES"
        --prefetch-buffer-lines "$PREFETCH_BUFFER_LINES"
        --stream-slots "$stream_slots"
        --max-stream-length "$max_stream_length"
        --epoch-reads "$epoch_reads"
        --stream-lifetime "$stream_lifetime"
        --prefetch-latency "$PREFETCH_LATENCY"
        --miss-latency "$MISS_LATENCY"
        --hit-latency "$HIT_LATENCY"
        --write-latency "$WRITE_LATENCY"
        --base-cost "$BASE_COST"
        --max-prefetch-depth "$max_prefetch_depth"
    )

    if [[ "$bootstrap" != "1" && "$bootstrap" != "true" && "$bootstrap" != "TRUE" ]]; then
        args+=(--no-bootstrap)
    fi

    args+=("$trace")

    local out selected_cycles baseline_cycles speedup
    out="$("${args[@]}")"
    selected_cycles=$(awk -F': ' '/^  selected cycles:/ {print $2; exit}' <<<"$out")
    baseline_cycles=$(awk -F': ' '/^  baseline cycles:/ {print $2; exit}' <<<"$out")
    speedup=$(awk -F': ' '/^  speedup vs baseline:/ {gsub(/x$/, "", $2); print $2; exit}' <<<"$out")

    if [[ -z "$selected_cycles" || -z "$baseline_cycles" || -z "$speedup" ]]; then
        echo "Failed to parse simulator output for trace: $trace" >&2
        exit 1
    fi

    printf '%s\t%s\t%s\n' "$selected_cycles" "$baseline_cycles" "$speedup"
}

best_speedup=-1
best_row=""

for policy in $POLICIES; do
    for stream_slots in $STREAM_SLOTS_LIST; do
        for max_stream_length in $MAX_STREAM_LENGTHS; do
            for epoch_reads in $EPOCH_READS_LIST; do
                for stream_lifetime in $STREAM_LIFETIMES; do
                    for max_prefetch_depth in $MAX_PREFETCH_DEPTHS; do
                        for bootstrap in $BOOTSTRAPS; do
                            selected_sum=0
                            baseline_sum=0
                            speedup_logs=()

                            for trace in "${traces[@]}"; do
                                IFS=$'\t' read -r selected_cycles baseline_cycles speedup < <(
                                    run_one \
                                        "$policy" \
                                        "$stream_slots" \
                                        "$max_stream_length" \
                                        "$epoch_reads" \
                                        "$stream_lifetime" \
                                        "$max_prefetch_depth" \
                                        "$bootstrap" \
                                        "$trace"
                                )

                                selected_sum=$((selected_sum + selected_cycles))
                                baseline_sum=$((baseline_sum + baseline_cycles))
                                speedup_logs+=("$speedup")
                            done

                            avg_speedup=$(printf '%s\n' "${speedup_logs[@]}" | awk '
                                {
                                    sum += log($1);
                                    count += 1;
                                }
                                END {
                                    if (count == 0) {
                                        printf "0";
                                    } else {
                                        printf "%.6f", exp(sum / count);
                                    }
                                }
                            ')
                            avg_selected_cycles=$(awk -v sum="$selected_sum" -v count="${#traces[@]}" 'BEGIN { printf "%.2f", sum / count }')
                            avg_baseline_cycles=$(awk -v sum="$baseline_sum" -v count="${#traces[@]}" 'BEGIN { printf "%.2f", sum / count }')

                            row="$policy,$LINE_SIZE,$DEMAND_CACHE_LINES,$PREFETCH_BUFFER_LINES,$stream_slots,$max_stream_length,$epoch_reads,$stream_lifetime,$PREFETCH_LATENCY,$MISS_LATENCY,$HIT_LATENCY,$WRITE_LATENCY,$BASE_COST,$max_prefetch_depth,$bootstrap,$avg_speedup,$avg_selected_cycles,$avg_baseline_cycles"
                            printf '%s\n' "$row"

                            if awk -v cur="$avg_speedup" -v best="$best_speedup" 'BEGIN { exit !(cur > best) }'; then
                                best_speedup="$avg_speedup"
                                best_row="$row"
                            fi
                        done
                    done
                done
            done
        done
    done
done

printf 'Best config by geometric-mean speedup: %s\n' "$best_row" >&2
