#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CSV_OUT="stream_buffer_experiments.csv"

# ── 0. Minimal setup (no cleaning — we want to resume) ───────────
mkdir -p logs plots

# ── 1. Check PIN_ROOT ─────────────────────────────────────────────
if [ -z "${PIN_ROOT:-}" ]; then
    echo "ERROR: PIN_ROOT is not set. Run: export PIN_ROOT=\$PIN_ROOT"
    exit 1
fi
echo "PIN_ROOT=$PIN_ROOT"
ls -la "$PIN_ROOT/pin" || { echo "ERROR: pin binary not found"; exit 1; }

# ── 2. Copy benchmarks if missing ─────────────────────────────────
if [ ! -d benchmarks ]; then
    echo ">> Copying benchmarks from ASSIGNMENT3..."
    if [ -d "$HOME/workspace/ASSIGNMENT3/benchmarks" ]; then
        cp -r "$HOME/workspace/ASSIGNMENT3/benchmarks" benchmarks
    else
        echo "ERROR: benchmarks/ not found and ~/workspace/ASSIGNMENT3/benchmarks doesn't exist."
        exit 1
    fi
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
# Parameter space (72 total configs):
#   3 benchmarks  : libquantum, hmmer, dealII
#   3 policies    : off, nextline, adaptive
#   2 stream_slots: 4, 8
#   2 max_depth   : 2, 8
#   2 max_length  : 8, 32
#
# (off and nextline ignore stream params, but the redundant combos
#  are fast — same result, Pin still runs quickly.)
#
if [ -f "$CSV_OUT" ]; then
    done_count=$(tail -n +2 "$CSV_OUT" | grep -c ',ok,' || true)
    echo ">> Resuming sweep ($done_count configs already completed in $CSV_OUT)"
else
    echo ">> Starting fresh sweep"
fi

echo ">> Running full parameter sweep (stream buffer only, no victim cache)..."
echo ">> 72 configs × 3 benchmarks — results stream to $CSV_OUT"
echo ">> Safe to kill and re-run to resume from where it left off."

PIN_ROOT="$PIN_ROOT" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=5000000000 \
POLICY_VALUES="off nextline adaptive" \
STREAM_SLOTS_VALUES="4 8" \
MAX_PREFETCH_DEPTH_VALUES="2 8" \
MAX_STREAM_LENGTH_VALUES="8 32" \
./scripts/sweep_stream_buffer.sh -o "$CSV_OUT" 2>&1 | tee -a logs/full_sweep.log

echo ">> Sweep complete."

# ── 5. Generate plots ─────────────────────────────────────────────
echo ">> Generating plots..."
.venv/bin/python3 scripts/plot_speedup.py || echo "plot_speedup.py failed (non-fatal)"
.venv/bin/python3 scripts/plot_hardware_cost.py || echo "plot_hardware_cost.py failed (non-fatal)"
.venv/bin/python3 scripts/plot_accuracy_coverage.py || echo "plot_accuracy_coverage.py failed (non-fatal)"

echo ""
echo "========================================="
echo "  DONE. Results:"
echo "    CSV:   $CSV_OUT"
echo "    Plots: plots/"
echo "    Logs:  logs/"
echo "========================================="
