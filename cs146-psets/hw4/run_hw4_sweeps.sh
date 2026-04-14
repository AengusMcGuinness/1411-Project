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

LIBQUANTUM_CMD=( "$BENCH_DIR/libquantum_O3" 400 25 )
HMMER_CMD=( "$BENCH_DIR/hmmer_O3" "$BENCH_DIR/inputs/nph3.hmm" "$BENCH_DIR/inputs/swiss41" )

usage() {
  cat <<EOF
Usage: $(basename "$0") [assoc|victim|compare|native|all]

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
  local victim="$2"
  local dest="$3"

  awk -v assoc="$assoc" -v victim="$victim" '
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
        if (victim != "") {
          line = line ", " victim
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

run_case() {
  local assoc="$1"
  local victim="$2"
  local label="$3"
  shift 3

  local -a bench=( "$@" )
  local cfg out dmiss vhits
  cfg="$(mktemp "${TMPDIR:-/tmp}/hw4_cfg.XXXXXX")"
  out="$(mktemp "${TMPDIR:-/tmp}/hw4_out.XXXXXX")"

  log_step "$label"
  make_config "$assoc" "$victim" "$cfg"
  run_pin "$cfg" "$out" "${bench[@]}"

  dmiss="$(extract_metric "$out" "D-Cache Miss:")"
  vhits="$(extract_metric "$out" "Victim-Cache Hits:")"
  [[ -n "$dmiss" ]] || dmiss=0
  [[ -n "$vhits" ]] || vhits=0

  rm -f "$cfg" "$out"
  printf '%s,%s\n' "$dmiss" "$vhits"
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

  log_section "Associativity Sweep"
  printf 'associativity,libquantum,hmmer\n' > "$csv_file"
  for assoc in 1 2 4 8; do
    local q h
    IFS=, read -r q _ <<EOF
$(run_case "$assoc" "" "assoc=$assoc libquantum" "${LIBQUANTUM_CMD[@]}")
EOF
    IFS=, read -r h _ <<EOF
$(run_case "$assoc" "" "assoc=$assoc hmmer" "${HMMER_CMD[@]}")
EOF
    printf '%s,%s,%s\n' "$assoc" "$q" "$h" >> "$csv_file"
    log_info "Associativity $assoc complete: libquantum=$q, hmmer=$h"
  done

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

run_victim_sweep_dm() {
  local out_dir="$OUT_DIR/victim_dm"
  mkdir -p "$out_dir"

  local csv_file="$out_dir/victim_dm_misses.csv"
  log_section "Victim Sweep: Direct-Mapped L1D"
  printf 'entries,libquantum,hmmer\n' > "$csv_file"

  for entries in 1 2 3 4 5 6 7 8; do
    local q h qd qv hd hv
    IFS=, read -r qd qv <<EOF
$(run_case 1 "$entries" "victim=$entries libquantum" "${LIBQUANTUM_CMD[@]}")
EOF
    IFS=, read -r hd hv <<EOF
$(run_case 1 "$entries" "victim=$entries hmmer" "${HMMER_CMD[@]}")
EOF
    q=$(( qd - qv ))
    h=$(( hd - hv ))
    printf '%s,%s,%s\n' "$entries" "$q" "$h" >> "$csv_file"
    log_info "Victim entries $entries complete: libquantum=$q (L1D=$qd, VC hits=$qv), hmmer=$h (L1D=$hd, VC hits=$hv)"
  done

  render_series_plot \
    "$csv_file" \
    "$out_dir/victim_dm_misses.png" \
    "entries" \
    "libquantum" \
    "hmmer" \
    "Victim Cache Sweep with Direct-Mapped L1D" \
    "Victim Cache Entries" \
    "L1D misses - VC hits" \
    "libquantum" \
    "hmmer" \
    "" \
    "" \
    ""

  echo "Direct-mapped victim sweep CSV: $csv_file"
  if [[ "$GENERATE_PLOTS" == "1" ]]; then
    echo "Direct-mapped victim sweep plot: $out_dir/victim_dm_misses.png"
  fi
}

run_compare_sweep() {
  local out_dir="$OUT_DIR/victim_compare"
  mkdir -p "$out_dir"

  local lib_csv="$out_dir/libquantum_dm_vs_8way.csv"
  local hmmer_csv="$out_dir/hmmer_dm_vs_8way.csv"

  log_section "Victim Sweep: Direct-Mapped vs 8-Way"
  printf 'entries,direct_mapped,assoc8\n' > "$lib_csv"
  printf 'entries,direct_mapped,assoc8\n' > "$hmmer_csv"

  for entries in 1 2 3 4 5 6 7 8; do
    local qdm qd_hits q8 q8_hits hdm hd_hits h8 h8_hits
    IFS=, read -r qdm qd_hits <<EOF
$(run_case 1 "$entries" "compare dm victim=$entries libquantum" "${LIBQUANTUM_CMD[@]}")
EOF
    IFS=, read -r q8 q8_hits <<EOF
$(run_case 8 "$entries" "compare 8way victim=$entries libquantum" "${LIBQUANTUM_CMD[@]}")
EOF
    IFS=, read -r hdm hd_hits <<EOF
$(run_case 1 "$entries" "compare dm victim=$entries hmmer" "${HMMER_CMD[@]}")
EOF
    IFS=, read -r h8 h8_hits <<EOF
$(run_case 8 "$entries" "compare 8way victim=$entries hmmer" "${HMMER_CMD[@]}")
EOF

    printf '%s,%s,%s\n' "$entries" $(( qdm - qd_hits )) $(( q8 - q8_hits )) >> "$lib_csv"
    printf '%s,%s,%s\n' "$entries" $(( hdm - hd_hits )) $(( h8 - h8_hits )) >> "$hmmer_csv"
    log_info "Compare entries $entries complete: libquantum(dm=$(( qdm - qd_hits )), 8way=$(( q8 - q8_hits ))), hmmer(dm=$(( hdm - hd_hits )), 8way=$(( h8 - h8_hits )))"
  done

  render_series_plot \
    "$lib_csv" \
    "$out_dir/libquantum_dm_vs_8way.png" \
    "entries" \
    "direct_mapped" \
    "assoc8" \
    "Victim Cache Benefits: libquantum" \
    "Victim Cache Entries" \
    "direct-mapped L1D" \
    "8-way L1D" \
    "" \
    "" \
    ""

  render_series_plot \
    "$hmmer_csv" \
    "$out_dir/hmmer_dm_vs_8way.png" \
    "entries" \
    "direct_mapped" \
    "assoc8" \
    "Victim Cache Benefits: hmmer" \
    "Victim Cache Entries" \
    "direct-mapped L1D" \
    "8-way L1D" \
    "" \
    "" \
    ""

  echo "Comparison CSVs: $lib_csv, $hmmer_csv"
  if [[ "$GENERATE_PLOTS" == "1" ]]; then
    echo "Comparison plots: $out_dir/libquantum_dm_vs_8way.png, $out_dir/hmmer_dm_vs_8way.png"
  fi
}

run_native_mode() {
  log_section "Native LIKWID Captures"
  run_native_capture "libquantum" "${LIBQUANTUM_CMD[@]}"
  run_native_capture "hmmer" "${HMMER_CMD[@]}"
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    assoc|victim|compare|native|all)
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
    victim)
      run_victim_sweep_dm
      ;;
    compare)
      run_compare_sweep
      ;;
    native)
      run_native_mode
      ;;
    all)
      run_assoc_sweep
      run_victim_sweep_dm
      run_compare_sweep
      run_native_mode
      ;;
  esac
}

main "${1:-all}"
