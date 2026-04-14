#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 0. Check PIN_ROOT ──────────────────────────────────────────────
if [ -z "${PIN_ROOT:-}" ]; then
    echo "ERROR: PIN_ROOT is not set. Run: export PIN_ROOT=\$PIN_ROOT"
    exit 1
fi

# ── 1. Copy benchmarks if missing ──────────────────────────────────
if [ ! -d benchmarks ]; then
    echo ">> Copying benchmarks from ASSIGNMENT3..."
    if [ -d "$HOME/workspace/ASSIGNMENT3/benchmarks" ]; then
        cp -r "$HOME/workspace/ASSIGNMENT3/benchmarks" benchmarks
    else
        echo "ERROR: benchmarks/ not found and ~/workspace/ASSIGNMENT3/benchmarks doesn't exist."
        echo "Copy them manually: cp -r /path/to/benchmarks ./benchmarks"
        exit 1
    fi
fi

# ── 2. Build the pintool ───────────────────────────────────────────
echo ">> Building pintool..."
make pin PIN_ROOT="$PIN_ROOT"

# ── 3. Quick smoke test ────────────────────────────────────────────
echo ">> Running smoke test (2 configs, 1M instructions)..."
PIN_ROOT="$PIN_ROOT" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=1000000 \
POLICY_VALUES="adaptive" \
STREAM_SLOTS_VALUES="4 8" \
./scripts/sweep_stream_buffer.sh -o smoke_test.csv

echo ">> Smoke test passed. Results:"
cat smoke_test.csv
echo ""

# ── 4. Full sweep ──────────────────────────────────────────────────
echo ">> Running full parameter sweep..."
PIN_ROOT="$PIN_ROOT" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=1000000 \
POLICY_VALUES="off nextline adaptive" \
STREAM_SLOTS_VALUES="4 8 16" \
MAX_PREFETCH_DEPTH_VALUES="1 2 4 8" \
MAX_STREAM_LENGTH_VALUES="8 16 32" \
./scripts/sweep_stream_buffer.sh -o stream_buffer_experiments.csv

echo ">> Sweep complete."

# ── 5. Generate plots ─────────────────────────────────────────────
echo ">> Generating plots..."
python3 scripts/plot_speedup.py
python3 scripts/plot_hardware_cost.py
python3 scripts/plot_accuracy_coverage.py

echo ""
echo "========================================="
echo "  DONE. Results:"
echo "    CSV:   stream_buffer_experiments.csv"
echo "    Plots: plots/"
echo "========================================="
