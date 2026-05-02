# Phase 2 — Adaptive Stream Buffer (Paper A)

This directory contains the full Phase 2 implementation: an adaptive stream
buffer prefetcher modeled on Palacharla & Kessler's paper *"Evaluating Stream
Buffers as a Secondary Cache Replacement"* (the project's `Advanced-Paper.pdf`).

The Phase 1 prefetcher in `../aengus/` is a fixed-depth FIFO stream buffer.
Phase 2 builds on that foundation with three additions:

1. **A two-level cache hierarchy** (L1D → L2 → memory) with set-associative
   LRU at each level, ported from the homework 4 cache model. The stream
   buffer observes L2 misses, not L1 misses, matching the paper.
2. **An adaptive prefetch-depth policy** driven by a learned histogram of
   stream lengths. Rather than always prefetching one line ahead (next-line)
   or always *N* lines ahead (fixed-depth), the policy infers from past
   stream behavior how many lines to fetch.
3. **A configurable Pintool harness** with a parameter sweeper that runs
   Pin invocations in parallel, supports resume across kills, and emits
   per-config accuracy/coverage to a CSV.

## Directory layout

```
ali/
├── README.md                ← this file
├── Makefile                 ← top-level (delegates to pintool/)
├── run.sh                   ← one-command end-to-end pipeline
├── src/
│   ├── stream_buffer.hpp    ← simulator API and config struct
│   └── stream_buffer.cpp    ← simulator core: caches, stream tracker,
│                              histogram, prefetch buffer, latency model
├── pintool/
│   ├── adaptive_stream_buffer_pintool.cpp
│   ├── Makefile
│   └── makefile.rules
├── scripts/
│   ├── sweep_stream_buffer.sh          ← parallel Cartesian sweep
│   ├── plot_speedup.py                 ← speedup vs each parameter
│   ├── plot_hardware_cost.py           ← hardware-bits vs speedup
│   └── plot_accuracy_coverage.py       ← heatmaps + line plots
├── results/
│   └── stream_buffer_experiments.csv   ← 72 ok rows from the final sweep
├── plots/
│   └── *.png, hardware_cost_summary.csv  ← 17 deliverables
└── notes/                              ← development scratch (NOTES.md, etc.)
```

## Build

The Pintool requires Intel Pin. Set `PIN_ROOT` to your Pin install root,
then from the repo root or this directory:

```bash
make pin                        # delegates to pintool/
```

`make pin-clean` wipes Pin's intermediate objects.

## Run

The full sweep is one command:

```bash
cd ali
PIN_ROOT=$PIN_ROOT bash run.sh
```

`run.sh` does the following:

1. Verifies `PIN_ROOT` and that the benchmarks live at `../benchmarks/`
   (shared with Phase 1).
2. Builds the Pintool if `pintool/obj-intel64/*.so` is missing.
3. Sweeps **72 configs**: 3 benchmarks × 3 policies × 2 stream_slots ×
   2 max_prefetch_depth × 2 max_stream_length, capped at 5 B instructions
   per benchmark thread.
4. **Resumable**: results stream to `results/stream_buffer_experiments.csv`
   as each config finishes, and configs already in the CSV are skipped on
   restart.
5. Generates plots from the CSV using the venv at `../.venv/`.

Defaults in `run.sh` can be overridden by setting environment variables
(`POLICY_VALUES`, `STREAM_SLOTS_VALUES`, etc.) — see
`scripts/sweep_stream_buffer.sh -h` for the full list.

## Implementation notes

### Cache hierarchy
`SetAssocCache` (in `src/stream_buffer.cpp`) implements set-associative LRU
sized by `(size_bytes, line_size_bytes, associativity)`. The defaults are
4 KB / 1-way for L1D and 1 MB / 1-way for L2 (matching the homework 4
config-base). A read access first probes L1D, then L2 on miss. An L2 miss is
where the prefetcher kicks in; the prefetched line is installed into both
levels on the way back.

### Adaptive depth selection
The stream tracker maintains up to `stream_slots` active streams. Each slot
records the most recently observed line, the inferred direction (+1, −1, or
unknown), and the running stream length. On every read miss we extend the
matching slot or allocate a fresh one.

The depth policy is driven by a cumulative histogram `lht_curr_[k]` of
stream lengths. After each epoch (every `epoch_reads` L2 misses) the next
epoch's histogram replaces the current one. To choose how many lines to
prefetch on a given access, we walk the histogram starting at the slot's
current length and increment depth as long as
`lht_curr_[probe] < 2 · lht_curr_[probe + 1]` — i.e., as long as the
likelihood that the stream continues to the next bucket dominates.

### Bug fixes that closed the gap with next-line
The naive form of the histogram-driven policy under-prefetches in two
places. Both are fixed here:

1. **Cliff at the histogram cap.** When a stream's length reaches
   `max_stream_length`, the original code returned depth = 0 because there
   was "no more histogram to consult." But that's exactly when we have the
   *strongest* evidence the stream is long-lived. Fix: return
   `max_prefetch_depth` once a stream is past the histogram cap.
2. **Broken bootstrap.** Before the first epoch rollover the policy used a
   tiny seed histogram (`lht[1]=1, lht[2]=1`). For any stream of length ≥ 2
   the depth-walking loop hit a zero in the next bucket and returned 0,
   so warmup was almost completely silent. Fix: keep `history_ready_` false
   until a real epoch has rolled, and let the bootstrap path return
   `depth = 1` for *any* length (i.e., behave like next-line during warmup).
3. **Singleton-stream histogram poisoning.** When all stream slots are full,
   the tracker used to record the orphan miss as a length-1 stream, biasing
   the histogram toward "throttle." Removed — untracked misses now record
   nothing.

These changes are what carry adaptive from ~1× speedup to within striking
distance of next-line on `libquantum` (5.0× best, 5.8× for next-line),
while keeping its bandwidth advantage on irregular workloads.

## Headline result

| Benchmark   | off | nextline | adaptive (best) | adaptive @ depth = 2 |
|-------------|-----|----------|-----------------|----------------------|
| libquantum  | 1.000 | 5.832 | **5.024** | 1.013 |
| hmmer       | 1.000 | 1.009 | 1.001 | 1.001 |
| dealII      | 1.000 | 1.018 | 1.011 | 1.011 |

| Benchmark   | nextline accuracy | adaptive (depth=2) accuracy |
|-------------|-------------------|------------------------------|
| libquantum  | 99.4 % | 99.4 % |
| hmmer       | 93.4 % | 93.2 % |
| dealII      | 78.4 % | **83.3 %** |

The adaptive policy lets the user trade speedup for bandwidth: at
`max_prefetch_depth = 8` it gets close to next-line on `libquantum` (5.0×)
while at `max_prefetch_depth = 2` it gets higher accuracy than next-line on
`dealII` (83 % vs 78 %). Phase 1 measured the same workload sensitivity as
"effective miss reduction"; Phase 2 puts that in cycle terms via a modeled
L1D / L2 / memory hit cost.
