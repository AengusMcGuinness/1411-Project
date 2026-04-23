# Paper-A: Adaptive Stream Buffer Prefetcher

## Overview

This project implements and evaluates the adaptive stream buffer prefetcher
described in `Paper-A.pdf`. The core idea is to detect sequential memory access
streams at runtime, maintain a stream table with direction and length metadata,
and use a learned likelihood histogram to choose how aggressively to prefetch
ahead of the demand access pattern.

## Implementation

- **Core simulator**: `src/stream_buffer.cpp` / `src/stream_buffer.hpp`
  - LRU demand cache model
  - FIFO prefetch buffer with ready-time tracking
  - Stream table with configurable slot count and lifetime
  - Epoch-based histogram learning for adaptive prefetch depth
- **Pin tool**: `pintool/adaptive_stream_buffer_pintool.cpp`
  - Instruments memory reads and writes on real binaries
  - Runs selected policy side-by-side with a no-prefetch baseline
  - Reports accuracy, coverage, modeled cycles, and speedup
- **Policies**: off (baseline), nextline (always prefetch N+1), adaptive (histogram-guided depth)

## Experiments

### Parameter Sweep Configuration
- **Benchmarks**: libquantum, hmmer
- **Policies**: off, nextline, adaptive
- **Stream slots**: 4, 8, 16
- **Max prefetch depth**: 1, 2, 4, 8
- **Max stream length**: 8, 16, 32
- **MAX_INSTRUCTIONS**: 1000000 (for tractable run times under Pin)

### Running the Sweep
```bash
make pin PIN_ROOT="$PIN_ROOT"

PIN_ROOT="$PIN_ROOT" \
MAX_JOBS=4 \
MAX_INSTRUCTIONS=1000000 \
POLICY_VALUES="off nextline adaptive" \
STREAM_SLOTS_VALUES="4 8 16" \
MAX_PREFETCH_DEPTH_VALUES="1 2 4 8" \
MAX_STREAM_LENGTH_VALUES="8 16 32" \
./scripts/sweep_stream_buffer.sh -o stream_buffer_experiments.csv
```

### Generating Plots
```bash
python3 scripts/plot_speedup.py
python3 scripts/plot_hardware_cost.py
python3 scripts/plot_accuracy_coverage.py
```

### Results

[TODO: Reference the CSV and plots after running experiments on the cluster]

## Analysis

### Speedup
[TODO: Compare adaptive vs nextline vs off for each benchmark.
Explain why adaptive outperforms nextline on streaming workloads (libquantum)
and how the epoch-based learning adapts to different access patterns.]

### Hardware Cost Tradeoff
[TODO: Calculate bits per configuration using `scripts/plot_hardware_cost.py`.
Show diminishing returns as stream table and prefetch buffer grow.
Discuss the Pareto frontier of cost vs. speedup.]

Hardware cost formula:
- Stream table = `stream_slots * (1 valid + 1 direction + 46 addr + 16 length + 16 lifetime + 16 touch)` bits per slot
- Prefetch buffer = `prefetch_buffer_lines * (46 addr + 32 ready_time + 1 used + 1 claimed)` bits per entry
- Histogram = `2 * (max_stream_length + 2) * 16` bits (current + next epoch counters)

### Prefetch Accuracy and Coverage
[TODO: Discuss the accuracy-coverage tradeoff.
Explain how epoch length and max prefetch depth affect learning stability.
Reference heatmap plots from `scripts/plot_accuracy_coverage.py`.]

## Machine Details
```
[TODO: Paste lscpu output from the cluster here]
```
