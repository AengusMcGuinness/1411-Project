#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_PIN_TOOL="$REPO_ROOT/pintool/obj-intel64/adaptive_stream_buffer_pintool.so"
DEFAULT_BENCHMARK_ROOT="$REPO_ROOT/benchmarks"

usage() {
    cat <<'EOF'
Usage: sweep_stream_buffer.sh [-o output.csv] [-j jobs]

Run the adaptive stream-buffer Pintool against libquantum and hmmer while
sweeping any combination of parameter value lists.

The script builds a Cartesian product across every configured value list, then
runs up to four Pin processes at once using background jobs.

Options:
  -o, --out FILE     Write the CSV results to FILE instead of stdout.
  -j, --jobs N       Maximum concurrent Pin jobs (default: 4, capped at 4).
  -h, --help         Show this help text.

Environment variables:
  PIN_ROOT                 Root of your Intel Pin installation.
  PIN_BIN                  Pin launcher path (default: $PIN_ROOT/pin).
  PIN_TOOL                 Pintool .so path (default: repo pintool output).
  BENCHMARK_ROOT           Directory that contains the benchmark binaries.
  LIBQUANTUM_BIN           libquantum executable path.
  HMMER_BIN                hmmer executable path.
  LIBQUANTUM_ARGS          Extra libquantum arguments (default: "400 25").
  HMMER_ARGS               Extra hmmer arguments (default: empty).
  MAX_INSTRUCTIONS         Stop each benchmark after this many instructions per thread.
                           Set to 0 to disable the cutoff (default: 0).

  BENCHMARK_VALUES         Benchmark names to sweep (default: "libquantum hmmer").
  POLICY_VALUES             Prefetch policies to sweep (default: "adaptive").
  LINE_SIZE_VALUES          Cache-line sizes in bytes.
  DEMAND_CACHE_LINES_VALUES Demand-cache capacities.
  PREFETCH_BUFFER_LINES_VALUES
                            Prefetch-buffer capacities.
  STREAM_SLOTS_VALUES       Stream-table sizes.
  MAX_STREAM_LENGTH_VALUES  Histogram caps.
  EPOCH_READS_VALUES        Read-miss epoch lengths.
  STREAM_LIFETIME_VALUES    Stream lifetimes.
  PREFETCH_LATENCY_VALUES   Prefetch latency values.
  MISS_LATENCY_VALUES       Demand-miss latency values.
  HIT_LATENCY_VALUES        Hit latency values.
  WRITE_LATENCY_VALUES      Write latency values.
  BASE_COST_VALUES          Per-access bookkeeping costs.
  MAX_PREFETCH_DEPTH_VALUES Maximum prefetch depths.
  BOOTSTRAP_VALUES          Bootstrap flags (0/1, true/false, etc.).

Example:
  POLICY_VALUES="off nextline adaptive" \
  STREAM_SLOTS_VALUES="4 8 16" \
  MAX_PREFETCH_DEPTH_VALUES="1 2 4" \
  MAX_INSTRUCTIONS=1000000 \
  MAX_JOBS=4 \
  ./scripts/sweep_stream_buffer.sh -o results.csv

Notes:
  - The output metrics are the modeled selected/baseline cycles reported by
    the Pintool, not wall-clock runtime.
  - Set one of the value lists to a single value to hold that knob fixed.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

normalize_bool() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON)
            printf '1\n'
            ;;
        0|false|FALSE|no|NO|off|OFF)
            printf '0\n'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

emit_csv_row() {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$1"  "$2"  "$3"  "$4"  "$5"  "$6"  "$7"  "$8"  "$9"  \
        "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" "${16}" "${17}" "${18}" "${19}" "${20}" "${21}"
}

extract_selected_cycles() {
    awk '
        $0 == "selected" { in_selected = 1; next }
        in_selected && $0 == "baseline" { exit }
        in_selected && /^  modeled cycles:/ { print $3; exit }
    '
}

extract_baseline_cycles() {
    awk '
        $0 == "baseline" { in_baseline = 1; next }
        in_baseline && /^  modeled cycles:/ { print $3; exit }
    '
}

values_for_key() {
    case "$1" in
        benchmark) printf '%s\n' "${BENCHMARK_VALUES_ARR[@]}" ;;
        policy) printf '%s\n' "${POLICY_VALUES_ARR[@]}" ;;
        line_size) printf '%s\n' "${LINE_SIZE_VALUES_ARR[@]}" ;;
        demand_cache_lines) printf '%s\n' "${DEMAND_CACHE_LINES_VALUES_ARR[@]}" ;;
        prefetch_buffer_lines) printf '%s\n' "${PREFETCH_BUFFER_LINES_VALUES_ARR[@]}" ;;
        stream_slots) printf '%s\n' "${STREAM_SLOTS_VALUES_ARR[@]}" ;;
        max_stream_length) printf '%s\n' "${MAX_STREAM_LENGTH_VALUES_ARR[@]}" ;;
        epoch_reads) printf '%s\n' "${EPOCH_READS_VALUES_ARR[@]}" ;;
        stream_lifetime) printf '%s\n' "${STREAM_LIFETIME_VALUES_ARR[@]}" ;;
        prefetch_latency) printf '%s\n' "${PREFETCH_LATENCY_VALUES_ARR[@]}" ;;
        miss_latency) printf '%s\n' "${MISS_LATENCY_VALUES_ARR[@]}" ;;
        hit_latency) printf '%s\n' "${HIT_LATENCY_VALUES_ARR[@]}" ;;
        write_latency) printf '%s\n' "${WRITE_LATENCY_VALUES_ARR[@]}" ;;
        base_cost) printf '%s\n' "${BASE_COST_VALUES_ARR[@]}" ;;
        max_prefetch_depth) printf '%s\n' "${MAX_PREFETCH_DEPTH_VALUES_ARR[@]}" ;;
        bootstrap_next_line) printf '%s\n' "${BOOTSTRAP_VALUES_ARR[@]}" ;;
        *) return 1 ;;
    esac
}

assign_current_value() {
    case "$1" in
        benchmark) CURRENT_BENCHMARK="$2" ;;
        policy) CURRENT_POLICY="$2" ;;
        line_size) CURRENT_LINE_SIZE="$2" ;;
        demand_cache_lines) CURRENT_DEMAND_CACHE_LINES="$2" ;;
        prefetch_buffer_lines) CURRENT_PREFETCH_BUFFER_LINES="$2" ;;
        stream_slots) CURRENT_STREAM_SLOTS="$2" ;;
        max_stream_length) CURRENT_MAX_STREAM_LENGTH="$2" ;;
        epoch_reads) CURRENT_EPOCH_READS="$2" ;;
        stream_lifetime) CURRENT_STREAM_LIFETIME="$2" ;;
        prefetch_latency) CURRENT_PREFETCH_LATENCY="$2" ;;
        miss_latency) CURRENT_MISS_LATENCY="$2" ;;
        hit_latency) CURRENT_HIT_LATENCY="$2" ;;
        write_latency) CURRENT_WRITE_LATENCY="$2" ;;
        base_cost) CURRENT_BASE_COST="$2" ;;
        max_prefetch_depth) CURRENT_MAX_PREFETCH_DEPTH="$2" ;;
        bootstrap_next_line) CURRENT_BOOTSTRAP_NEXT_LINE="$2" ;;
        *) return 1 ;;
    esac
}

count_values_for_key() {
    case "$1" in
        benchmark) printf '%s\n' "${#BENCHMARK_VALUES_ARR[@]}" ;;
        policy) printf '%s\n' "${#POLICY_VALUES_ARR[@]}" ;;
        line_size) printf '%s\n' "${#LINE_SIZE_VALUES_ARR[@]}" ;;
        demand_cache_lines) printf '%s\n' "${#DEMAND_CACHE_LINES_VALUES_ARR[@]}" ;;
        prefetch_buffer_lines) printf '%s\n' "${#PREFETCH_BUFFER_LINES_VALUES_ARR[@]}" ;;
        stream_slots) printf '%s\n' "${#STREAM_SLOTS_VALUES_ARR[@]}" ;;
        max_stream_length) printf '%s\n' "${#MAX_STREAM_LENGTH_VALUES_ARR[@]}" ;;
        epoch_reads) printf '%s\n' "${#EPOCH_READS_VALUES_ARR[@]}" ;;
        stream_lifetime) printf '%s\n' "${#STREAM_LIFETIME_VALUES_ARR[@]}" ;;
        prefetch_latency) printf '%s\n' "${#PREFETCH_LATENCY_VALUES_ARR[@]}" ;;
        miss_latency) printf '%s\n' "${#MISS_LATENCY_VALUES_ARR[@]}" ;;
        hit_latency) printf '%s\n' "${#HIT_LATENCY_VALUES_ARR[@]}" ;;
        write_latency) printf '%s\n' "${#WRITE_LATENCY_VALUES_ARR[@]}" ;;
        base_cost) printf '%s\n' "${#BASE_COST_VALUES_ARR[@]}" ;;
        max_prefetch_depth) printf '%s\n' "${#MAX_PREFETCH_DEPTH_VALUES_ARR[@]}" ;;
        bootstrap_next_line) printf '%s\n' "${#BOOTSTRAP_VALUES_ARR[@]}" ;;
        *) return 1 ;;
    esac
}

format_job_label() {
    printf 'benchmark=%s policy=%s stream_slots=%s max_stream_length=%s max_depth=%s bootstrap=%s' \
        "$1" "$2" "$3" "$4" "$5" "$6"
}

log_progress() {
    local action="$1"
    local completed="$2"
    local running="$3"
    local label="$4"
    printf 'progress: %s %d/%d (running=%d/%d) %s\n' \
        "$action" "$completed" "$total_jobs" "$running" "$MAX_JOBS" "$label" >&2
}

reap_finished_jobs() {
    local i pid status
    local -a remaining_pids=()
    local -a remaining_labels=()
    local reaped_any=1

    for i in "${!pids[@]}"; do
        pid="${pids[$i]}"
        status="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
        case "$status" in
            *Z*)
                wait "$pid" || true
                completed_jobs=$((completed_jobs + 1))
                active_jobs=$((active_jobs - 1))
                log_progress "completed" "$completed_jobs" "$active_jobs" "${job_labels[$i]}"
                reaped_any=0
                ;;
            *)
                remaining_pids+=("$pid")
                remaining_labels+=("${job_labels[$i]}")
                ;;
        esac
    done

    pids=("${remaining_pids[@]}")
    job_labels=("${remaining_labels[@]}")
    active_jobs="${#pids[@]}"

    return "$reaped_any"
}

wait_for_slot() {
    while [ "$active_jobs" -ge "$MAX_JOBS" ]; do
        if reap_finished_jobs; then
            continue
        fi
        sleep "${PROGRESS_POLL_INTERVAL:-0.25}"
    done
}

run_one() {
    local row_file="$1"
    local benchmark="$2"
    local policy="$3"
    local line_size="$4"
    local demand_cache_lines="$5"
    local prefetch_buffer_lines="$6"
    local stream_slots="$7"
    local max_stream_length="$8"
    local epoch_reads="$9"
    local stream_lifetime="${10}"
    local prefetch_latency="${11}"
    local miss_latency="${12}"
    local hit_latency="${13}"
    local write_latency="${14}"
    local base_cost="${15}"
    local max_prefetch_depth="${16}"
    local bootstrap_next_line="${17}"

    local -a benchmark_cmd=()
    case "$benchmark" in
        libquantum)
            benchmark_cmd=("$LIBQUANTUM_BIN")
            if [ "${#LIBQUANTUM_ARGS_ARR[@]}" -gt 0 ]; then
                benchmark_cmd+=("${LIBQUANTUM_ARGS_ARR[@]}")
            fi
            ;;
        hmmer)
            benchmark_cmd=("$HMMER_BIN")
            if [ "${#HMMER_ARGS_ARR[@]}" -gt 0 ]; then
                benchmark_cmd+=("${HMMER_ARGS_ARR[@]}")
            fi
            ;;
        *)
            emit_csv_row \
                "$benchmark" \
                "error" \
                "unknown_benchmark" \
                "$policy" \
                "$line_size" \
                "$demand_cache_lines" \
                "$prefetch_buffer_lines" \
                "$stream_slots" \
                "$max_stream_length" \
                "$epoch_reads" \
                "$stream_lifetime" \
                "$prefetch_latency" \
                "$miss_latency" \
                "$hit_latency" \
                "$write_latency" \
                "$base_cost" \
                "$max_prefetch_depth" \
                "$bootstrap_next_line" \
                "0" \
                "0" \
                "0.000000" >"$row_file"
            return 0
            ;;
    esac

    local bootstrap_knob
    bootstrap_knob="$(normalize_bool "$bootstrap_next_line")"

    local -a pin_cmd=(
        "$PIN_BIN"
        -t "$PIN_TOOL"
        -policy "$policy"
        -line_size "$line_size"
        -demand_cache_lines "$demand_cache_lines"
        -prefetch_buffer_lines "$prefetch_buffer_lines"
        -stream_slots "$stream_slots"
        -max_stream_length "$max_stream_length"
        -epoch_reads "$epoch_reads"
        -stream_lifetime "$stream_lifetime"
        -prefetch_latency "$prefetch_latency"
        -miss_latency "$miss_latency"
        -hit_latency "$hit_latency"
        -write_latency "$write_latency"
        -base_cost "$base_cost"
        -max_prefetch_depth "$max_prefetch_depth"
        -bootstrap_next_line "$bootstrap_knob"
        -max_instructions "$MAX_INSTRUCTIONS"
        --
    )
    pin_cmd+=("${benchmark_cmd[@]}")

    local raw_output
    if ! raw_output="$("${pin_cmd[@]}" 2>&1)"; then
        printf '%s\n' "Pin run failed for benchmark=$benchmark policy=$policy" >&2
        printf '%s\n' "$raw_output" >&2
        emit_csv_row \
            "$benchmark" \
            "error" \
            "pin_failed" \
            "$policy" \
            "$line_size" \
            "$demand_cache_lines" \
            "$prefetch_buffer_lines" \
            "$stream_slots" \
            "$max_stream_length" \
            "$epoch_reads" \
            "$stream_lifetime" \
            "$prefetch_latency" \
            "$miss_latency" \
            "$hit_latency" \
            "$write_latency" \
            "$base_cost" \
            "$max_prefetch_depth" \
            "$bootstrap_knob" \
            "0" \
            "0" \
            "0.000000" >"$row_file"
        return 0
    fi

    local selected_cycles baseline_cycles speedup
    selected_cycles="$(extract_selected_cycles <<<"$raw_output")"
    baseline_cycles="$(extract_baseline_cycles <<<"$raw_output")"

    if [ -z "$selected_cycles" ] || [ -z "$baseline_cycles" ]; then
        printf '%s\n' "Failed to parse Pin output for benchmark=$benchmark policy=$policy" >&2
        printf '%s\n' "$raw_output" >&2
        emit_csv_row \
            "$benchmark" \
            "error" \
            "parse_failed" \
            "$policy" \
            "$line_size" \
            "$demand_cache_lines" \
            "$prefetch_buffer_lines" \
            "$stream_slots" \
            "$max_stream_length" \
            "$epoch_reads" \
            "$stream_lifetime" \
            "$prefetch_latency" \
            "$miss_latency" \
            "$hit_latency" \
            "$write_latency" \
            "$base_cost" \
            "$max_prefetch_depth" \
            "$bootstrap_knob" \
            "0" \
            "0" \
            "0.000000" >"$row_file"
        return 0
    fi

    speedup="$(awk -v selected="$selected_cycles" -v baseline="$baseline_cycles" '
        BEGIN {
            if (selected > 0) {
                printf "%.6f", baseline / selected
            } else {
                printf "0.000000"
            }
        }
    ')"

    emit_csv_row \
        "$benchmark" \
        "ok" \
        "ok" \
        "$policy" \
        "$line_size" \
        "$demand_cache_lines" \
        "$prefetch_buffer_lines" \
        "$stream_slots" \
        "$max_stream_length" \
        "$epoch_reads" \
        "$stream_lifetime" \
        "$prefetch_latency" \
        "$miss_latency" \
        "$hit_latency" \
        "$write_latency" \
        "$base_cost" \
        "$max_prefetch_depth" \
        "$bootstrap_knob" \
        "$selected_cycles" \
        "$baseline_cycles" \
        "$speedup" >"$row_file"
}

schedule_current_config() {
    wait_for_slot

    local row_file="$WORKDIR/row_${job_index}.csv"
    local job_label
    row_files+=("$row_file")
    job_label="$(format_job_label \
        "$CURRENT_BENCHMARK" \
        "$CURRENT_POLICY" \
        "$CURRENT_STREAM_SLOTS" \
        "$CURRENT_MAX_STREAM_LENGTH" \
        "$CURRENT_MAX_PREFETCH_DEPTH" \
        "$CURRENT_BOOTSTRAP_NEXT_LINE")"

    run_one \
        "$row_file" \
        "$CURRENT_BENCHMARK" \
        "$CURRENT_POLICY" \
        "$CURRENT_LINE_SIZE" \
        "$CURRENT_DEMAND_CACHE_LINES" \
        "$CURRENT_PREFETCH_BUFFER_LINES" \
        "$CURRENT_STREAM_SLOTS" \
        "$CURRENT_MAX_STREAM_LENGTH" \
        "$CURRENT_EPOCH_READS" \
        "$CURRENT_STREAM_LIFETIME" \
        "$CURRENT_PREFETCH_LATENCY" \
        "$CURRENT_MISS_LATENCY" \
        "$CURRENT_HIT_LATENCY" \
        "$CURRENT_WRITE_LATENCY" \
        "$CURRENT_BASE_COST" \
        "$CURRENT_MAX_PREFETCH_DEPTH" \
        "$CURRENT_BOOTSTRAP_NEXT_LINE" &

    pids+=("$!")
    job_labels+=("$job_label")
    active_jobs=$((active_jobs + 1))
    scheduled_jobs=$((scheduled_jobs + 1))
    log_progress "started" "$scheduled_jobs" "$active_jobs" "$job_label"
    job_index=$((job_index + 1))
}

walk_configs() {
    local idx="$1"
    if [ "$idx" -ge "${#PARAM_NAMES[@]}" ]; then
        schedule_current_config
        return
    fi

    local key="${PARAM_NAMES[$idx]}"
    local value
    while IFS= read -r value; do
        assign_current_value "$key" "$value"
        walk_configs $((idx + 1))
    done < <(values_for_key "$key")
}

print_summary() {
    local csv_file="$1"
    awk -F, '
        NR == 1 {
            for (i = 1; i <= NF; ++i) {
                col[$i] = i
            }
            next
        }
        $col["status"] != "ok" {
            next
        }
        {
            bench = $col["benchmark"]
            speed = $col["speedup"] + 0
            if (!(bench in best_speed) || speed > best_speed[bench]) {
                best_speed[bench] = speed
                best_row[bench] = $0
            }
            ok_count += 1
        }
        END {
            print "Sweep summary:" > "/dev/stderr"
            printf "  successful runs: %d\n", ok_count + 0 > "/dev/stderr"
            for (bench in best_row) {
                printf "  best %s: %s\n", bench, best_row[bench] > "/dev/stderr"
            }
            if (ok_count == 0) {
                print "  no successful runs completed" > "/dev/stderr"
            }
        }
    ' "$csv_file"
}

output_file=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--out)
            [ "$#" -ge 2 ] || die "missing value for $1"
            output_file="$2"
            shift 2
            ;;
        -j|--jobs)
            [ "$#" -ge 2 ] || die "missing value for $1"
            MAX_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ -z "${PIN_ROOT:-}" ]; then
    die "set PIN_ROOT to your Intel Pin installation root"
fi

PIN_BIN="${PIN_BIN:-$PIN_ROOT/pin}"
PIN_TOOL="${PIN_TOOL:-$DEFAULT_PIN_TOOL}"
BENCHMARK_ROOT="${BENCHMARK_ROOT:-$DEFAULT_BENCHMARK_ROOT}"
LIBQUANTUM_BIN="${LIBQUANTUM_BIN:-$BENCHMARK_ROOT/libquantum_O3}"
HMMER_BIN="${HMMER_BIN:-$BENCHMARK_ROOT/hmmer_O3}"

[ -x "$PIN_BIN" ] || die "Pin launcher not found or not executable: $PIN_BIN"
[ -f "$PIN_TOOL" ] || die "Pintool shared object not found: $PIN_TOOL"
[ -x "$LIBQUANTUM_BIN" ] || die "libquantum benchmark not found or not executable: $LIBQUANTUM_BIN"
[ -x "$HMMER_BIN" ] || die "hmmer benchmark not found or not executable: $HMMER_BIN"

MAX_JOBS="${MAX_JOBS:-4}"
MAX_INSTRUCTIONS="${MAX_INSTRUCTIONS:-0}"
case "$MAX_JOBS" in
    ''|*[!0-9]*)
        die "MAX_JOBS must be a positive integer"
        ;;
esac
if [ "$MAX_JOBS" -lt 1 ]; then
    MAX_JOBS=1
fi
if [ "$MAX_JOBS" -gt 4 ]; then
    MAX_JOBS=4
fi

case "$MAX_INSTRUCTIONS" in
    ''|*[!0-9]*)
        die "MAX_INSTRUCTIONS must be a non-negative integer"
        ;;
esac

BENCHMARK_VALUES_ARR=(${BENCHMARK_VALUES:-${BENCHMARKS:-libquantum hmmer}})
POLICY_VALUES_ARR=(${POLICY_VALUES:-${POLICIES:-adaptive}})
LINE_SIZE_VALUES_ARR=(${LINE_SIZE_VALUES:-${LINE_SIZES:-64}})
DEMAND_CACHE_LINES_VALUES_ARR=(${DEMAND_CACHE_LINES_VALUES:-${DEMAND_CACHE_LINES_LIST:-4096}})
PREFETCH_BUFFER_LINES_VALUES_ARR=(${PREFETCH_BUFFER_LINES_VALUES:-${PREFETCH_BUFFER_LINES_LIST:-16}})
STREAM_SLOTS_VALUES_ARR=(${STREAM_SLOTS_VALUES:-${STREAM_SLOTS_LIST:-8}})
MAX_STREAM_LENGTH_VALUES_ARR=(${MAX_STREAM_LENGTH_VALUES:-${MAX_STREAM_LENGTHS:-16}})
EPOCH_READS_VALUES_ARR=(${EPOCH_READS_VALUES:-${EPOCH_READS_LIST:-2000}})
STREAM_LIFETIME_VALUES_ARR=(${STREAM_LIFETIME_VALUES:-${STREAM_LIFETIMES:-256}})
PREFETCH_LATENCY_VALUES_ARR=(${PREFETCH_LATENCY_VALUES:-${PREFETCH_LATENCY_LIST:-8}})
MISS_LATENCY_VALUES_ARR=(${MISS_LATENCY_VALUES:-${MISS_LATENCY_LIST:-80}})
HIT_LATENCY_VALUES_ARR=(${HIT_LATENCY_VALUES:-${HIT_LATENCY_LIST:-1}})
WRITE_LATENCY_VALUES_ARR=(${WRITE_LATENCY_VALUES:-${WRITE_LATENCY_LIST:-1}})
BASE_COST_VALUES_ARR=(${BASE_COST_VALUES:-${BASE_COST_LIST:-1}})
MAX_PREFETCH_DEPTH_VALUES_ARR=(${MAX_PREFETCH_DEPTH_VALUES:-${MAX_PREFETCH_DEPTHS:-8}})
BOOTSTRAP_VALUES_ARR=(${BOOTSTRAP_VALUES:-${BOOTSTRAPS:-1}})

if [ -n "${LIBQUANTUM_ARGS:-}" ]; then
    LIBQUANTUM_ARGS_ARR=(${LIBQUANTUM_ARGS})
else
    LIBQUANTUM_ARGS_ARR=(400 25)
fi

if [ -n "${HMMER_ARGS:-}" ]; then
    HMMER_ARGS_ARR=(${HMMER_ARGS})
else
    HMMER_ARGS_ARR=()
fi

PARAM_NAMES=(
    benchmark
    policy
    line_size
    demand_cache_lines
    prefetch_buffer_lines
    stream_slots
    max_stream_length
    epoch_reads
    stream_lifetime
    prefetch_latency
    miss_latency
    hit_latency
    write_latency
    base_cost
    max_prefetch_depth
    bootstrap_next_line
)

total_jobs=1
for key in "${PARAM_NAMES[@]}"; do
    count="$(count_values_for_key "$key")"
    total_jobs=$((total_jobs * count))
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/asb-sweep.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

results_csv="$WORKDIR/results.csv"
row_files=()
pids=()
job_labels=()
active_jobs=0
scheduled_jobs=0
completed_jobs=0
job_index=0

CURRENT_BENCHMARK=""
CURRENT_POLICY=""
CURRENT_LINE_SIZE=""
CURRENT_DEMAND_CACHE_LINES=""
CURRENT_PREFETCH_BUFFER_LINES=""
CURRENT_STREAM_SLOTS=""
CURRENT_MAX_STREAM_LENGTH=""
CURRENT_EPOCH_READS=""
CURRENT_STREAM_LIFETIME=""
CURRENT_PREFETCH_LATENCY=""
CURRENT_MISS_LATENCY=""
CURRENT_HIT_LATENCY=""
CURRENT_WRITE_LATENCY=""
CURRENT_BASE_COST=""
CURRENT_MAX_PREFETCH_DEPTH=""
CURRENT_BOOTSTRAP_NEXT_LINE=""

printf 'sweeping %d configurations with up to %d concurrent jobs\n' "$total_jobs" "$MAX_JOBS" >&2

printf '%s\n' \
    'benchmark,status,reason,policy,line_size,demand_cache_lines,prefetch_buffer_lines,stream_slots,max_stream_length,epoch_reads,stream_lifetime,prefetch_latency,miss_latency,hit_latency,write_latency,base_cost,max_prefetch_depth,bootstrap_next_line,selected_cycles,baseline_cycles,speedup' \
    >"$results_csv"

walk_configs 0

while [ "$active_jobs" -gt 0 ]; do
    if reap_finished_jobs; then
        continue
    fi
    sleep "${PROGRESS_POLL_INTERVAL:-0.25}"
done

for row_file in "${row_files[@]}"; do
    cat "$row_file" >>"$results_csv"
done

if [ -n "$output_file" ]; then
    mkdir -p "$(dirname "$output_file")"
    cp "$results_csv" "$output_file"
    final_csv="$output_file"
else
    final_csv="$results_csv"
    cat "$final_csv"
fi

print_summary "$final_csv"
