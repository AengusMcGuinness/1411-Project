#!/usr/bin/env bash
set -euo pipefail

# Run from ali/ — Phase 2 (Paper-A adaptive stream buffer) end-to-end pipeline.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Repo root holds shared resources (benchmarks/, .venv/) used by both phases.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH_DIR="$REPO_ROOT/benchmarks"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"

CSV_OUT="results/stream_buffer_experiments.csv"

# ── 0. Minimal setup (no cleaning — we want to resume) ───────────
mkdir -p logs plots results

# ── 1. Check PIN_ROOT ─────────────────────────────────────────────
if [ -z "${PIN_ROOT:-}" ]; then
    echo "ERROR: PIN_ROOT is not set. Run: export PIN_ROOT=<pin install root>"
    exit 1
fi
echo "PIN_ROOT=$PIN_ROOT"
ls -la "$PIN_ROOT/pin" >/dev/null || { echo "ERROR: pin binary not found"; exit 1; }

# ── 2. Verify benchmarks at repo root ─────────────────────────────
if [ ! -d "$BENCH_DIR" ]; then
    echo "ERROR: $BENCH_DIR not found. Expected libquantum_O3, hmmer_O3, dealII_O3."
    exit 1
fi

# ── 3. Build pintool only if .so is missing ───────────────────────
PIN_TOOL="pintool/obj-intel64/adaptive_stream_buffer_pintool.so"
if [ ! -f "$PIN_TOOL" ]; then
    echo ">> Building pintool..."
    make pin-clean pin PIN_ROOT="$PIN_ROOT"
else
    echo ">> Pintool already built, skipping rebuild."
fi
ls -la "$PIN_TOOL"

# ── 4. Resume-aware full sweep ────────────────────────────────────
#
# Parameter space (72 configs):
#   3 benchmarks  : libquantum, hmmer, dealII
#   3 policies    : off, nextline, adaptive
#   2 stream_slots: 4, 8
#   2 max_depth   : 2, 8
#   2 max_length  : 8, 32
#
# off and nextline ignore stream params, but the redundant combos run fast
# under Pin and the resume logic still tracks them as distinct rows.
#
if [ -f "$CSV_OUT" ]; then
    done_count=$(tail -n +2 "$CSV_OUT" | grep -c ',ok,' || true)
    echo ">> Resuming sweep ($done_count configs already completed in $CSV_OUT)"
else
    echo ">> Starting fresh sweep"
fi

echo ">> Running full parameter sweep (stream buffer only, no victim cache)..."
echo ">> 72 configs — results stream to $CSV_OUT"
echo ">> Safe to kill and re-run to resume from where it left off."

PIN_ROOT="$PIN_ROOT" \
BENCHMARK_ROOT="$BENCH_DIR" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=5000000000 \
POLICY_VALUES="off nextline adaptive" \
STREAM_SLOTS_VALUES="4 8" \
MAX_PREFETCH_DEPTH_VALUES="2 8" \
MAX_STREAM_LENGTH_VALUES="8 32" \
./scripts/sweep_stream_buffer.sh -o "$CSV_OUT" 2>&1 | tee -a logs/full_sweep.log

echo ">> Sweep complete."

# ── 5. Generate plots ─────────────────────────────────────────────
if [ ! -x "$VENV_PYTHON" ]; then
    echo "WARN: $VENV_PYTHON not found — skipping plots."
    echo "      Set up the venv at the repo root: python3 -m venv .venv && .venv/bin/pip install matplotlib"
else
    echo ">> Generating plots..."
    "$VENV_PYTHON" scripts/plot_speedup.py            || echo "plot_speedup.py failed (non-fatal)"
    "$VENV_PYTHON" scripts/plot_hardware_cost.py      || echo "plot_hardware_cost.py failed (non-fatal)"
    "$VENV_PYTHON" scripts/plot_accuracy_coverage.py  || echo "plot_accuracy_coverage.py failed (non-fatal)"
fi

echo ""
echo "========================================="
echo "  DONE. Results:"
echo "    CSV:   $CSV_OUT"
echo "    Plots: plots/"
echo "    Logs:  logs/"
echo "========================================="
