#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p logs

# ── 0. Check PIN_ROOT ──────────────────────────────────────────────
if [ -z "${PIN_ROOT:-}" ]; then
    echo "ERROR: PIN_ROOT is not set. Run: export PIN_ROOT=\$PIN_ROOT"
    exit 1
fi
echo "PIN_ROOT=$PIN_ROOT"
echo "PIN_BIN=$PIN_ROOT/pin"
ls -la "$PIN_ROOT/pin" || { echo "ERROR: pin binary not found"; exit 1; }

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
echo ">> Benchmarks:"
ls -la benchmarks/
ls -la benchmarks/inputs/

# ── 2. Build the pintool ───────────────────────────────────────────
echo ">> Building pintool..."
make pin PIN_ROOT="$PIN_ROOT"

PIN_TOOL="pintool/obj-intel64/adaptive_stream_buffer_pintool.so"
echo ">> Checking pintool .so exists:"
ls -la "$PIN_TOOL" || { echo "ERROR: pintool .so not found"; exit 1; }

# ── 3. DEBUG: Run ONE Pin invocation directly to see raw output ────
echo ""
echo "========================================"
echo "  DEBUG: Running single Pin invocation"
echo "========================================"
echo "Command:"
echo "  $PIN_ROOT/pin -t $PIN_TOOL -policy adaptive -stream_slots 8 -max_instructions 1000000 -- benchmarks/libquantum_O3 400 25"
echo ""

DEBUG_LOG="logs/debug_single_run.log"
set +e
"$PIN_ROOT/pin" \
    -t "$PIN_TOOL" \
    -policy adaptive \
    -stream_slots 8 \
    -max_instructions 1000000 \
    -- benchmarks/libquantum_O3 400 25 \
    > "$DEBUG_LOG" 2>&1
DEBUG_EXIT=$?
set -e

echo ">> Exit code: $DEBUG_EXIT"
echo ">> Raw output ($DEBUG_LOG):"
echo "--- START ---"
cat "$DEBUG_LOG"
echo "--- END ---"
echo ""

# Check if we got the expected output format
if grep -q "^selected" "$DEBUG_LOG"; then
    echo ">> GOOD: Found 'selected' block in output"
else
    echo ">> PROBLEM: No 'selected' block found in output"
    echo ">> The pintool is not producing expected output."
    echo ">> Check the log above for errors."
fi

if grep -q "^baseline" "$DEBUG_LOG"; then
    echo ">> GOOD: Found 'baseline' block in output"
else
    echo ">> PROBLEM: No 'baseline' block found in output"
fi

if grep -q "modeled cycles:" "$DEBUG_LOG"; then
    echo ">> GOOD: Found 'modeled cycles' in output"
else
    echo ">> PROBLEM: No 'modeled cycles' found in output"
fi

echo ""
echo "========================================"
echo "  DEBUG complete. Review output above."
echo "  If it looks correct, the sweep should work."
echo "========================================"
echo ""

# ── 4. Quick smoke test ────────────────────────────────────────────
echo ">> Running smoke test (2 configs, 1M instructions)..."
PIN_ROOT="$PIN_ROOT" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=1000000 \
POLICY_VALUES="adaptive" \
STREAM_SLOTS_VALUES="4 8" \
./scripts/sweep_stream_buffer.sh -o smoke_test.csv 2>&1 | tee logs/smoke_test.log

echo ">> Smoke test results:"
cat smoke_test.csv
echo ""

# ── 5. Full sweep ──────────────────────────────────────────────────
echo ">> Running full parameter sweep..."
PIN_ROOT="$PIN_ROOT" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=1000000 \
POLICY_VALUES="off nextline adaptive" \
STREAM_SLOTS_VALUES="4 8 16" \
MAX_PREFETCH_DEPTH_VALUES="1 2 4 8" \
MAX_STREAM_LENGTH_VALUES="8 16 32" \
./scripts/sweep_stream_buffer.sh -o stream_buffer_experiments.csv 2>&1 | tee logs/full_sweep.log

echo ">> Sweep complete."

# ── 6. Generate plots ─────────────────────────────────────────────
echo ">> Generating plots..."
python3 scripts/plot_speedup.py
python3 scripts/plot_hardware_cost.py
python3 scripts/plot_accuracy_coverage.py

echo ""
echo "========================================="
echo "  DONE. Results:"
echo "    CSV:   stream_buffer_experiments.csv"
echo "    Plots: plots/"
echo "    Logs:  logs/"
echo "========================================="
