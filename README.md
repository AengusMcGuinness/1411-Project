# Stream-Buffer Prefetching: Two Phases

This repository implements and evaluates two stream-buffer prefetcher designs
on the same Pin-based simulator, against three SPEC CPU2006 workloads
(`libquantum`, `hmmer`, `dealII`):

| Phase | Directory   | Design                                               | Reference |
|-------|-------------|------------------------------------------------------|-----------|
| 1     | `aengus/`   | Fixed-depth FIFO stream buffer                       | Jouppi 1990 |
| 2     | `ali/`      | Adaptive stream buffer with learned histogram + L1/L2 hierarchy | `Advanced-Paper.pdf` (Palacharla & Kessler) |

Phase 1 establishes the workload sensitivity: prefetching is hugely
beneficial for streaming code (`libquantum`) and either irrelevant or
bandwidth-wasteful for irregular workloads (`hmmer`, `dealII`). Phase 2
addresses the bandwidth-waste problem by *learning* how aggressive to be.

The two phases share the `benchmarks/` directory and a Python venv at
`.venv/`. Each phase has its own README and run script.

---

## Phase 1 — Fixed-depth stream buffer (`aengus/`)

**Implementation.** `aengus/stream.cpp` is a single-translation-unit Pintool
that models L1D ↦ stream buffer ↦ L2 ↦ memory. Each of `S` parallel streams
holds up to `D` prefetched lines in a FIFO. On an L1D miss the simulator
probes the head of every active stream; a head match pops the line and
issues a fresh prefetch one block past the new tail (keeping the FIFO full).
A head miss allocates a new sequential stream starting at `(missed_line + 1)`.

**Sweep.** `aengus/sweep.sh` sweeps depth `D ∈ {0, 1, 2, 4, 8}` and stream
count `S ∈ {1, 2, 4, 8}`, plus an associativity sweep at `S = 4, D = 4`.
Results land in `aengus/sweep_results/`. The full report is
`aengus/report.pdf`.

**Headline result — effective L1D misses with `S = 4`:**

| depth | libquantum    | hmmer         | dealII       |
|------:|--------------:|--------------:|-------------:|
|   0   | 121,200,271   | 1,089,349,815 | 488,587,529  |
|   1   |   2,813,918   | 1,061,848,629 | 476,963,724  |
|   2   |   2,781,862   | 1,061,093,631 | 481,485,540  |
|   8   |   2,813,636   | 1,062,569,741 | 484,302,817  |

**Bandwidth cost — total L2 requests (demand + prefetch):**

| depth | libquantum    | hmmer         | dealII       |
|------:|--------------:|--------------:|-------------:|
|   0   | 121,204,522   | 1,091,088,059 |   525,692,727 |
|   1   | 124,038,602   | 2,130,266,731 |   999,832,393 |
|   8   | 143,733,460   | 9,570,217,539 | 4,404,294,345 |

**Takeaway.** `libquantum` collapses by ~43× at any depth ≥ 1 — its access
pattern is essentially infinite sequential streams. `hmmer` and `dealII`
barely shrink (~2 %) but their L2 traffic *balloons* roughly with depth
(`hmmer` at depth = 8 issues 9× the L2 traffic of the no-prefetch baseline
for almost no payoff). A static prefetcher cannot tell these workloads
apart.

---

## Phase 2 — Adaptive stream buffer (`ali/`)

**Implementation.** `ali/src/stream_buffer.{cpp,hpp}` adds three things on
top of the Phase 1 design:

1. **A two-level cache hierarchy** (`SetAssocCache` × 2: 4 KB L1D, 1 MB L2,
   both 1-way LRU by default). The stream buffer observes L2 misses, which
   matches the paper's intent.
2. **A learned-histogram depth policy.** Each completed stream's length
   contributes to a cumulative histogram of "streams that reached length
   ≥ k." On each access we walk the histogram from the current stream
   length and prefetch `depth` lines while `lht[k] < 2·lht[k+1]` (i.e.,
   "the next bucket is heavy enough to bet on continuation"). Histograms
   roll over every `epoch_reads` L2 misses.
3. **A configurable Pin harness.** `ali/scripts/sweep_stream_buffer.sh`
   runs Pin invocations 4-wide in parallel, emits per-config rows
   incrementally so kills don't lose work, and skips configs already in
   the output CSV on resume. The CSV captures cycles, accuracy, and
   coverage.

**Sweep.** 72 configs from `ali/run.sh`: 3 benchmarks × 3 policies (`off`,
`nextline`, `adaptive`) × 2 stream_slots (4, 8) × 2 max_prefetch_depth
(2, 8) × 2 max_stream_length (8, 32), capped at 5 B instructions per
thread. Results: `ali/results/stream_buffer_experiments.csv`. Plots:
`ali/plots/`.

**Headline result — best speedup vs. baseline (cycle model):**

| Benchmark   | off | nextline | adaptive (best) |
|-------------|-----|----------|-----------------|
| libquantum  | 1.000 | 5.832 | **5.024** |
| hmmer       | 1.000 | 1.009 | 1.001 |
| dealII      | 1.000 | 1.018 | 1.011 |

**Headline result — prefetch accuracy (useful / issued):**

| Benchmark   | nextline | adaptive (depth = 2) |
|-------------|----------|----------------------|
| libquantum  | 99.4 % | 99.4 % |
| hmmer       | 93.4 % | 93.2 % |
| dealII      | 78.4 % | **83.3 %** |

**Takeaway.** The adaptive policy approaches `nextline`'s speedup on
`libquantum` (5.0× vs 5.8×) without giving up the option to throttle.
At `max_prefetch_depth = 2` it matches or beats `nextline`'s accuracy on
`hmmer` and `dealII` (83 % vs 78 % on `dealII`), turning the wasted-
bandwidth failure mode that Phase 1 exposed into a tunable knob. This is
the central claim of the Palacharla & Kessler paper — Phase 2 reproduces
it.

---

## Comparing the two phases

The two phases agree on the *shape* of the result and reinforce each
other:

- **`libquantum`:** Phase 1 shows a 43× reduction in effective demand
  misses; Phase 2 turns that into a ~5× speedup once latency is modeled.
  Both phases say "prefetching wins big here."
- **`hmmer` / `dealII`:** Phase 1 shows the wasted-bandwidth failure mode
  (~10× L2 traffic at depth = 8 for `hmmer` with no payoff). Phase 2's
  adaptive policy at depth = 2 matches `nextline`'s tiny speedup while
  improving accuracy — the same insight, expressed differently.

Phase 1 is the cleaner picture of *workload sensitivity*; Phase 2 is the
cleaner picture of *what an adaptive policy buys you*. Together they
cover the full story.

---

## Repository layout

```
.
├── README.md                ← this file (unified writeup)
├── Advanced-Paper.pdf       ← Palacharla & Kessler (Phase 2 reference)
├── Makefile                 ← delegates `make pin` to ali/
├── benchmarks/              ← libquantum_O3, hmmer_O3, dealII_O3, inputs/
├── aengus/                  ← Phase 1
│   ├── report.pdf, report.tex
│   ├── stream.cpp, sweep.sh, plot_results.py
│   └── sweep_results/{stream,2d,assoc,plots,native}/
├── ali/                     ← Phase 2 (see ali/README.md for details)
│   ├── README.md
│   ├── Makefile, run.sh
│   ├── src/, pintool/, scripts/
│   ├── results/stream_buffer_experiments.csv
│   ├── plots/  (17 figures)
│   └── notes/  (development scratch)
├── cs146-psets/             ← course homework (homework 3 / 4)
└── disregard/               ← deprecated paths (kept for history)
```

## Building and running

Set `PIN_ROOT` to your Intel Pin install:

```bash
export PIN_ROOT=/path/to/intel-pin

# Phase 2 (full pipeline):
cd ali && bash run.sh

# Phase 1:
cd aengus && bash sweep.sh
```

The Phase 2 sweep is resumable — kill it any time and re-run; it picks up
from the partial CSV.

## Authors

Aengus McGuinness, Ali Saffrini, Madison Gates, Jacob Tom (CS 1411 Final
Project, Spring 2026).
