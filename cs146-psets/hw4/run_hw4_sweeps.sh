#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/sweep_results}"
BASE_CONFIG="${CONFIG_BASE:-$ROOT_DIR/config-base}"
PIN_TOOL="${PIN_TOOL:-$ROOT_DIR/obj-intel64/hw4.so}"
PIN_BIN="${PIN_BIN:-}"
PIN_ROOT="${PIN_ROOT:-}"
MAX_INST="${MAX_INST:-1000000000}"
BENCH_DIR="${BENCH_DIR:-$ROOT_DIR/benchmarks}"
NATIVE_ASSOC="${NATIVE_ASSOC:-8}"
NATIVE_LIBQUANTUM="${NATIVE_LIBQUANTUM:-}"
NATIVE_HMMER="${NATIVE_HMMER:-}"
GENERATE_PLOTS="${GENERATE_PLOTS:-0}"
# Max parallel Pin invocations. Defaults to the host's logical CPU count.
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

LIBQUANTUM_CMD=( "$BENCH_DIR/libquantum_O3" 400 25 )
HMMER_CMD=( "$BENCH_DIR/hmmer_O3" "$BENCH_DIR/inputs/nph3.hmm" "$BENCH_DIR/inputs/swiss41" )

usage() {
  cat <<EOF
Usage: $(basename "$0") [assoc|stream|streams|2d|native|all]

Environment overrides:
  CONFIG_BASE   Path to the course config-base file
  PIN_ROOT      Pin installation root (uses \$PIN_ROOT/pin)
  PIN_BIN       Full path to the pin executable
  PIN_TOOL      Path to obj-intel64/hw4.so
  BENCH_DIR     Directory containing libquantum_O3 and hmmer_O3
  OUT_DIR       Output directory for CSVs, plots, and logs
  MAX_INST      Pin max_inst knob; set to 0 to omit it
  GENERATE_PLOTS Set to 1 to generate plots locally if Rscript is available
  NATIVE_ASSOC  X position for optional native miss markers on the assoc plot
  NATIVE_LIBQUANTUM  Optional native miss value to overlay on assoc plot
  NATIVE_HMMER       Optional native miss value to overlay on assoc plot
  JOBS          Max parallel Pin invocations (default: logical CPU count)
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

timestamp() {
  date +"%H:%M:%S"
}

log_info() {
  echo "[$(timestamp)] $*" >&2
}

log_section() {
  echo >&2
  echo "[$(timestamp)] === $* ===" >&2
}

log_step() {
  echo "[$(timestamp)] -> $*" >&2
}

resolve_pin_bin() {
  if [[ -n "$PIN_BIN" ]]; then
    :
  elif [[ -n "$PIN_ROOT" ]]; then
    PIN_BIN="$PIN_ROOT/pin"
  else
    PIN_BIN="pin"
  fi

  command -v "$PIN_BIN" >/dev/null 2>&1 || die "Pin binary not found: $PIN_BIN"
}

check_paths() {
  [[ -f "$BASE_CONFIG" ]] || die "Config file not found: $BASE_CONFIG"

  [[ -e "$PIN_TOOL" ]] || die "Pin tool not found: $PIN_TOOL"

  for bench in "${LIBQUANTUM_CMD[0]}" "${HMMER_CMD[0]}"; do
    [[ -f "$bench" ]] || die "Benchmark not found: $bench"
    if [[ ! -x "$bench" ]]; then
      log_info "Fixing benchmark permissions: chmod +x $bench"
      chmod +x "$bench" 2>/dev/null || die "Benchmark not executable: $bench (run chmod +x \"$bench\")"
    fi
    [[ -x "$bench" ]] || die "Benchmark not executable: $bench"
  done
}

make_config() {
  local assoc="$1"
  local stream_depth="${2:-}"    # optional 4th field on L1D line
  local stream_streams="${3:-}"  # optional 5th field on L1D line
  local dest="$4"

  awk -v assoc="$assoc" \
      -v stream_depth="$stream_depth" -v stream_streams="$stream_streams" '
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }

    BEGIN { seen = 0 }

    /^[[:space:]]*$/ { print; next }
    /^[[:space:]]*#/ { print; next }
    /^[[:space:]]*\/\// { print; next }

    {
      seen++
      if (seen == 3) {
        n = split($0, fields, ",")
        if (n < 3) {
          print
          next
        }

        line = trim(fields[1]) ", " trim(fields[2]) ", " assoc
        if (stream_depth != "") {
          line = line ", " stream_depth
          if (stream_streams != "") {
            line = line ", " stream_streams
          }
        }
        print line
      } else {
        print
      }
    }
  ' "$BASE_CONFIG" > "$dest"
}

run_pin() {
  local config="$1"
  local outfile="$2"
  shift 2

  local -a bench=( "$@" )
  local -a cmd=( "$PIN_BIN" -t "$PIN_TOOL" -config "$config" -outfile "$outfile" )

  if [[ "$MAX_INST" != "0" ]]; then
    cmd+=( -max_inst "$MAX_INST" )
  fi

  cmd+=( -- )
  cmd+=( "${bench[@]}" )
  "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Parallel job-pool helpers
# ---------------------------------------------------------------------------
# Global array that tracks PIDs of in-flight background jobs.
_pool_pids=()

# Launch run_case in the background.  Its stdout (the metrics CSV line) is
# redirected to result_file; log messages still appear on stderr as normal.
# Automatically drains the pool first when it is full.
pool_launch() {
  local result_file="$1"; shift
  # Drain before launching if the pool is already at capacity.
  if (( ${#_pool_pids[@]} >= JOBS )); then
    pool_drain
  fi
  run_case "$@" >"$result_file" &
  _pool_pids+=($!)
}

# Wait for every in-flight job and clear the pool.
pool_drain() {
  if (( ${#_pool_pids[@]} > 0 )); then
    wait "${_pool_pids[@]}"
    _pool_pids=()
  fi
}
# ---------------------------------------------------------------------------

extract_metric() {
  local file="$1"
  local label="$2"

  awk -v label="$label" '
    index($0, label) {
      sub(/^.*: /, "", $0)
      split($0, parts, /[[:space:]]+/)
      print parts[1]
      exit
    }
  ' "$file"
}

# Extract the number that follows "out of" on the matched label line.
# Used to get total L2 requests from "L2-Cache Miss: N out of M".
extract_out_of_metric() {
  local file="$1"
  local label="$2"

  awk -v label="$label" '
    index($0, label) {
      sub(/.*out of /, "", $0)
      split($0, parts, /[[:space:]]+/)
      print parts[1]
      exit
    }
  ' "$file"
}

run_case() {
  local assoc="$1"
  local stream_depth="$2"    # "" or integer; passed through to make_config
  local stream_streams="$3"  # "" or integer; passed through to make_config
  local label="$4"
  shift 4

  local -a bench=( "$@" )
  local cfg out dmiss sbhits l2req
  cfg="$(mktemp "${TMPDIR:-/tmp}/hw4_cfg.XXXXXX")"
  out="$(mktemp "${TMPDIR:-/tmp}/hw4_out.XXXXXX")"

  log_step "$label"
  make_config "$assoc" "$stream_depth" "$stream_streams" "$cfg"
  run_pin "$cfg" "$out" "${bench[@]}"

  dmiss="$(extract_metric        "$out" "D-Cache Miss:")"
  sbhits="$(extract_metric       "$out" "Stream-Buffer Hits:")"
  l2req="$(extract_out_of_metric "$out" "L2-Cache Miss:")"
  [[ -n "$dmiss"  ]] || dmiss=0
  [[ -n "$sbhits" ]] || sbhits=0
  [[ -n "$l2req"  ]] || l2req=0

  rm -f "$cfg" "$out"
  # Fields: L1D_misses, stream_buf_hits, L2_total_requests
  printf '%s,%s,%s\n' "$dmiss" "$sbhits" "$l2req"
}

run_native_capture() {
  local label="$1"
  shift

  local -a bench=( "$@" )
  local native_dir="$OUT_DIR/native"
  local log_file="$native_dir/${label}.log"

  mkdir -p "$native_dir"

  if ! command -v likwid-perfctr >/dev/null 2>&1; then
    echo "likwid-perfctr not found; skipping native capture for $label." >&2
    return 0
  fi

  log_step "native LIKWID capture for $label"
  likwid-perfctr -f -C 0 -g MEM_LOAD_RETIRED_L1_MISS:PMC0 -t 120ms -o "$log_file" -- "${bench[@]}" >/dev/null 2>&1 || true
  echo "Native LIKWID log written to $log_file" >&2
}

render_series_plot() {
  if [[ "$GENERATE_PLOTS" != "1" ]]; then
    return 0
  fi

  if ! command -v Rscript >/dev/null 2>&1; then
    log_info "Rscript not found; skipping plot generation."
    return 0
  fi

  local csv_file="$1"
  local png_file="$2"
  local xcol="$3"
  local y1col="$4"
  local y2col="$5"
  local title="$6"
  local xlabel="$7"
  local ylabel="$8"
  local legend1="$9"
  local legend2="${10}"
  local native_x="${11}"
  local native_y1="${12}"
  local native_y2="${13}"

  Rscript --vanilla - "$csv_file" "$png_file" "$xcol" "$y1col" "$y2col" "$title" "$xlabel" "$ylabel" "$legend1" "$legend2" "$native_x" "$native_y1" "$native_y2" <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
csv_file <- args[1]
png_file <- args[2]
xcol <- args[3]
y1col <- args[4]
y2col <- args[5]
title <- args[6]
xlabel <- args[7]
ylabel <- args[8]
legend1 <- args[9]
legend2 <- args[10]
native_x <- args[11]
native_y1 <- args[12]
native_y2 <- args[13]

df <- read.csv(csv_file, check.names = FALSE)
x <- as.numeric(df[[xcol]])
y1 <- as.numeric(df[[y1col]])
y2 <- if (nzchar(y2col)) as.numeric(df[[y2col]]) else NULL

all_y <- y1
if (!is.null(y2)) {
  all_y <- c(all_y, y2)
}
if (nzchar(native_y1)) {
  all_y <- c(all_y, as.numeric(native_y1))
}
if (nzchar(native_y2)) {
  all_y <- c(all_y, as.numeric(native_y2))
}
all_y <- all_y[is.finite(all_y)]
ylim <- c(0, max(all_y) * 1.15)

png(png_file, width = 900, height = 600, res = 144)
par(mar = c(5, 5, 4, 1))
plot(
  x, y1,
  type = "b",
  pch = 19,
  lwd = 2,
  col = "#1f77b4",
  ylim = ylim,
  xaxt = "n",
  xlab = xlabel,
  ylab = ylabel,
  main = title
)
if (!is.null(y2)) {
  lines(x, y2, type = "b", pch = 19, lwd = 2, col = "#d62728")
}
axis(1, at = x)
grid()

legend_labels <- c(legend1)
legend_cols <- c("#1f77b4")
legend_pchs <- c(19)
if (!is.null(y2)) {
  legend_labels <- c(legend_labels, legend2)
  legend_cols <- c(legend_cols, "#d62728")
  legend_pchs <- c(legend_pchs, 19)
}
legend("topleft", legend = legend_labels, col = legend_cols, pch = legend_pchs, lwd = 2, bty = "n")

if (nzchar(native_x) && nzchar(native_y1)) {
  points(as.numeric(native_x), as.numeric(native_y1), pch = 17, cex = 1.4, col = "#1f77b4")
}
if (nzchar(native_x) && nzchar(native_y2)) {
  points(as.numeric(native_x), as.numeric(native_y2), pch = 17, cex = 1.4, col = "#d62728")
}

dev.off()
RSCRIPT
}

run_assoc_sweep() {
  local out_dir="$OUT_DIR/assoc"
  mkdir -p "$out_dir"

  local csv_file="$out_dir/assoc_misses.csv"
  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hw4_assoc.XXXXXX")"

  log_section "Associativity Sweep (JOBS=$JOBS)"

  # ── Launch phase: 8 jobs, drained in batches of JOBS ─────────────────────
  _pool_pids=()
  for assoc in 1 2 4 8; do
    pool_launch "$tmp_dir/lq_${assoc}" "$assoc" "" "" "assoc=$assoc libquantum" "${LIBQUANTUM_CMD[@]}"
    pool_launch "$tmp_dir/hm_${assoc}" "$assoc" "" "" "assoc=$assoc hmmer"      "${HMMER_CMD[@]}"
  done
  pool_drain

  # ── Assemble phase ────────────────────────────────────────────────────────
  printf 'associativity,libquantum,hmmer\n' > "$csv_file"
  for assoc in 1 2 4 8; do
    local q h _r
    IFS=, read -r q _r < "$tmp_dir/lq_${assoc}"; q="${q:-0}"
    IFS=, read -r h _r < "$tmp_dir/hm_${assoc}"; h="${h:-0}"
    printf '%s,%s,%s\n' "$assoc" "$q" "$h" >> "$csv_file"
    log_info "Associativity $assoc complete: libquantum=$q, hmmer=$h"
  done
  rm -rf "$tmp_dir"

  render_series_plot \
    "$csv_file" \
    "$out_dir/assoc_misses.png" \
    "associativity" \
    "libquantum" \
    "hmmer" \
    "L1 D-Cache Misses vs Associativity" \
    "L1 D Cache Associativity" \
    "libquantum" \
    "hmmer" \
    "${NATIVE_ASSOC}" \
    "${NATIVE_LIBQUANTUM}" \
    "${NATIVE_HMMER}"

  echo "Associativity sweep CSV: $csv_file"
  if [[ "$GENERATE_PLOTS" == "1" ]]; then
    echo "Associativity sweep plot: $out_dir/assoc_misses.png"
  fi
}


run_stream_sweep() {
  local out_dir="$OUT_DIR/stream"
  mkdir -p "$out_dir"

  # Two CSVs — one per report figure.
  # Figure 2: effective L1D misses (demand misses not covered by the stream buffer).
  # Figure 3: total L2 requests (demand + prefetch traffic).
  local eff_csv="$out_dir/stream_eff_misses.csv"
  local l2_csv="$out_dir/stream_l2_requests.csv"
  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hw4_stream.XXXXXX")"

  log_section "Stream Buffer Sweep (direct-mapped L1D, 1 stream, JOBS=$JOBS)"
  printf 'depth,libquantum,hmmer\n' > "$eff_csv"
  printf 'depth,libquantum,hmmer\n' > "$l2_csv"

  # ── Launch phase: 10 jobs (2 per depth × 5 depths), drained at JOBS ──────
  _pool_pids=()
  for depth in 0 1 2 4 8; do
    pool_launch "$tmp_dir/lq_${depth}" 1 "$depth" "1" "stream depth=$depth libquantum" "${LIBQUANTUM_CMD[@]}"
    pool_launch "$tmp_dir/hm_${depth}" 1 "$depth" "1" "stream depth=$depth hmmer"      "${HMMER_CMD[@]}"
  done
  pool_drain

  # ── Assemble phase ────────────────────────────────────────────────────────
  # run_case outputs: L1D_misses, victim_hits, sb_hits, L2_total_requests
  for depth in 0 1 2 4 8; do
    local qdm _v qsb ql2 hdm hsb hl2 q_eff h_eff
    IFS=, read -r qdm qsb ql2 < "$tmp_dir/lq_${depth}"
    IFS=, read -r hdm hsb hl2 < "$tmp_dir/hm_${depth}"
    qdm="${qdm:-0}"; qsb="${qsb:-0}"; ql2="${ql2:-0}"
    hdm="${hdm:-0}"; hsb="${hsb:-0}"; hl2="${hl2:-0}"
    q_eff=$(( qdm - qsb ))
    h_eff=$(( hdm - hsb ))
    printf '%s,%s,%s\n' "$depth" "$q_eff" "$h_eff" >> "$eff_csv"
    printf '%s,%s,%s\n' "$depth" "$ql2"   "$hl2"   >> "$l2_csv"
    log_info "Stream depth $depth: libquantum eff=$q_eff L2req=$ql2 | hmmer eff=$h_eff L2req=$hl2"
  done
  rm -rf "$tmp_dir"

  render_series_plot \
    "$eff_csv" \
    "$out_dir/stream_eff_misses.png" \
    "depth" "libquantum" "hmmer" \
    "Effective L1D Misses vs Stream Buffer Depth" \
    "Stream Buffer Depth (lines prefetched)" \
    "Effective L1D Misses (L1D - SB hits)" \
    "libquantum" "hmmer" "" "" ""

  render_series_plot \
    "$l2_csv" \
    "$out_dir/stream_l2_requests.png" \
    "depth" "libquantum" "hmmer" \
    "Total L2 Requests vs Stream Buffer Depth" \
    "Stream Buffer Depth (lines prefetched)" \
    "Total L2 Requests (demand + prefetch)" \
    "libquantum" "hmmer" "" "" ""

  echo "Stream buffer CSVs: $eff_csv, $l2_csv"
  if [[ "$GENERATE_PLOTS" == "1" ]]; then
    echo "Stream buffer plots: $out_dir/stream_eff_misses.png, $out_dir/stream_l2_requests.png"
  fi
}

run_streams_sweep() {
  local out_dir="$OUT_DIR/streams"
  mkdir -p "$out_dir"

  local eff_csv="$out_dir/streams_eff_misses.csv"
  local l2_csv="$out_dir/streams_l2_requests.csv"
  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hw4_streams.XXXXXX")"

  log_section "Stream Count Sweep (depth=1, direct-mapped L1D, JOBS=$JOBS)"
  printf 'streams,libquantum,hmmer\n' > "$eff_csv"
  printf 'streams,libquantum,hmmer\n' > "$l2_csv"

  # 10 jobs: 5 stream counts × 2 benchmarks
  _pool_pids=()
  for s in 1 2 4 8 16; do
    pool_launch "$tmp_dir/lq_${s}" 1 1 "$s" "streams=$s libquantum" "${LIBQUANTUM_CMD[@]}"
    pool_launch "$tmp_dir/hm_${s}" 1 1 "$s" "streams=$s hmmer"      "${HMMER_CMD[@]}"
  done
  pool_drain

  for s in 1 2 4 8 16; do
    local qdm _v qsb ql2 hdm hsb hl2
    IFS=, read -r qdm qsb ql2 < "$tmp_dir/lq_${s}"
    IFS=, read -r hdm hsb hl2 < "$tmp_dir/hm_${s}"
    qdm="${qdm:-0}"; qsb="${qsb:-0}"; ql2="${ql2:-0}"
    hdm="${hdm:-0}"; hsb="${hsb:-0}"; hl2="${hl2:-0}"
    printf '%s,%s,%s\n' "$s" "$(( qdm - qsb ))" "$(( hdm - hsb ))" >> "$eff_csv"
    printf '%s,%s,%s\n' "$s" "$ql2"              "$hl2"              >> "$l2_csv"
    log_info "Streams $s: libquantum eff=$(( qdm - qsb )) L2req=$ql2 | hmmer eff=$(( hdm - hsb )) L2req=$hl2"
  done
  rm -rf "$tmp_dir"

  echo "Stream count CSVs: $eff_csv, $l2_csv"
}

run_2d_sweep() {
  local out_dir="$OUT_DIR/2d"
  mkdir -p "$out_dir"

  # One effective-miss CSV per benchmark; columns are stream counts.
  # Rows iterate over depth, so each cell is (depth, S) → eff misses.
  local lq_eff_csv="$out_dir/2d_libquantum_eff.csv"
  local hm_eff_csv="$out_dir/2d_hmmer_eff.csv"
  local lq_l2_csv="$out_dir/2d_libquantum_l2.csv"
  local hm_l2_csv="$out_dir/2d_hmmer_l2.csv"
  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hw4_2d.XXXXXX")"

  log_section "2D Depth x Streams Sweep (direct-mapped L1D, JOBS=$JOBS)"
  printf 'depth,s1,s2,s4,s8\n' > "$lq_eff_csv"
  printf 'depth,s1,s2,s4,s8\n' > "$hm_eff_csv"
  printf 'depth,s1,s2,s4,s8\n' > "$lq_l2_csv"
  printf 'depth,s1,s2,s4,s8\n' > "$hm_l2_csv"

  # 40 jobs: 5 depths × 4 stream counts × 2 benchmarks
  _pool_pids=()
  for depth in 0 1 2 4 8; do
    for s in 1 2 4 8; do
      pool_launch "$tmp_dir/lq_d${depth}_s${s}" 1 "$depth" "$s" \
        "2d depth=$depth s=$s libquantum" "${LIBQUANTUM_CMD[@]}"
      pool_launch "$tmp_dir/hm_d${depth}_s${s}" 1 "$depth" "$s" \
        "2d depth=$depth s=$s hmmer"      "${HMMER_CMD[@]}"
    done
  done
  pool_drain

  for depth in 0 1 2 4 8; do
    local lq_eff_row="$depth" hm_eff_row="$depth"
    local lq_l2_row="$depth"  hm_l2_row="$depth"
    for s in 1 2 4 8; do
      local qdm _v qsb ql2 hdm hsb hl2
      IFS=, read -r qdm qsb ql2 < "$tmp_dir/lq_d${depth}_s${s}"
      IFS=, read -r hdm hsb hl2 < "$tmp_dir/hm_d${depth}_s${s}"
      qdm="${qdm:-0}"; qsb="${qsb:-0}"; ql2="${ql2:-0}"
      hdm="${hdm:-0}"; hsb="${hsb:-0}"; hl2="${hl2:-0}"
      lq_eff_row="$lq_eff_row,$(( qdm - qsb ))"
      hm_eff_row="$hm_eff_row,$(( hdm - hsb ))"
      lq_l2_row="$lq_l2_row,$ql2"
      hm_l2_row="$hm_l2_row,$hl2"
      log_info "2D depth=$depth s=$s: lq_eff=$(( qdm - qsb )) lq_l2=$ql2 | hm_eff=$(( hdm - hsb )) hm_l2=$hl2"
    done
    printf '%s\n' "$lq_eff_row" >> "$lq_eff_csv"
    printf '%s\n' "$hm_eff_row" >> "$hm_eff_csv"
    printf '%s\n' "$lq_l2_row"  >> "$lq_l2_csv"
    printf '%s\n' "$hm_l2_row"  >> "$hm_l2_csv"
  done
  rm -rf "$tmp_dir"

  echo "2D sweep CSVs: $lq_eff_csv, $hm_eff_csv, $lq_l2_csv, $hm_l2_csv"
}

run_native_mode() {
  log_section "Native LIKWID Captures"
  run_native_capture "libquantum" "${LIBQUANTUM_CMD[@]}"
  run_native_capture "hmmer" "${HMMER_CMD[@]}"
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    assoc|stream|streams|2d|native|all)
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  mkdir -p "$OUT_DIR"
  resolve_pin_bin
  check_paths
  log_info "Output directory: $OUT_DIR"
  log_info "Pin tool: $PIN_TOOL"
  log_info "Config base: $BASE_CONFIG"
  log_info "Benchmarks: ${LIBQUANTUM_CMD[0]} and ${HMMER_CMD[0]}"

  case "$mode" in
    assoc)
      run_assoc_sweep
      ;;
    stream)
      run_stream_sweep
      ;;
    streams)
      run_streams_sweep
      ;;
    2d)
      run_2d_sweep
      ;;
    native)
      run_native_mode
      ;;
    all)
      run_assoc_sweep
      run_stream_sweep
      run_streams_sweep
      run_2d_sweep
      run_native_mode
      ;;
  esac
}

main "${1:-all}"
