# Adaptive Stream Buffer

This repository now includes a C++ implementation of an adaptive stream buffer
prefetcher inspired by the paper in `Paper-A.pdf`.

What is implemented:

- A reusable C++ simulator for adaptive and next-line stream prefetching.
<!-- - A standalone trace-driven CLI so the model can be benchmarked locally. -->
- An Intel Pin Pintool front-end that reuses the same simulator core.
- A bash sweep helper that runs the Pintool across `libquantum` and `hmmer`
  with configurable parameter grids and up to 4 concurrent jobs.

## Build

<!-- Build the standalone simulator: -->

<!-- ```bash -->
<!-- make -->
<!-- ``` -->

Build the Pintool once `PIN_ROOT` points at an Intel Pin installation:

```bash
make pin PIN_ROOT=/path/to/pin
```

On the cluster it should be `PIN_ROOT=$PIN_ROOT`
<!-- ## Trace Format -->

<!-- The standalone simulator reads a simple text trace: -->

<!-- - `R 0x1000` for a read -->
<!-- - `W 0x1000` for a write -->

<!-- You can pass the trace file as the last argument or pipe it through stdin. -->

<!-- ## Run The Simulator -->

<!-- ```bash -->
<!-- ./build/stream_buffer_sim --policy adaptive trace.txt -->
<!-- ./build/stream_buffer_sim --policy nextline trace.txt -->
<!-- ./build/stream_buffer_sim --policy off trace.txt -->
<!-- ``` -->

<!-- Useful knobs: -->

<!-- - `--line-size` -->
<!-- - `--demand-cache-lines` -->
<!-- - `--prefetch-buffer-lines` -->
<!-- - `--stream-slots` -->
<!-- - `--max-stream-length` -->
<!-- - `--epoch-reads` -->
<!-- - `--stream-lifetime` -->
<!-- - `--prefetch-latency` -->
<!-- - `--miss-latency` -->
<!-- - `--hit-latency` -->
<!-- - `--write-latency` -->
<!-- - `--base-cost` -->
<!-- - `--max-prefetch-depth` -->

## Run The Pintool

After building the Pintool, run it through Pin:

```bash
$PIN_ROOT/pin \
  -t pintool/obj-intel64/adaptive_stream_buffer_pintool.so \
  -policy adaptive \
  -stream_slots 8 \
  -max_stream_length 16 \
  -max_prefetch_depth 4 \
  -bootstrap_next_line 1 \
  -- benchmarks/libquantum_O3 400 25
```

The Pintool prints a selected-policy summary and a no-prefetch baseline so you
can estimate the speedup from a single run.

## Sweep The Benchmarks

The sweep helper runs the Pintool directly on the benchmark executables and
writes a CSV table of the modeled selected/baseline cycles and speedup.

```bash
PIN_ROOT=/path/to/pin \
MAX_JOBS=4 \
POLICY_VALUES="off nextline adaptive" \
STREAM_SLOTS_VALUES="4 8 16" \
MAX_PREFETCH_DEPTH_VALUES="1 2 4" \
./scripts/sweep_stream_buffer.sh -o results.csv
```

By default the script looks for:

- `benchmarks/libquantum_O3`
- `benchmarks/hmmer_O3`

If your benchmark binaries live elsewhere, override them with:

- `BENCHMARK_ROOT=/path/to/benchmarks`
- `LIBQUANTUM_BIN=/path/to/libquantum_O3`
- `HMMER_BIN=/path/to/hmmer_O3`

The sweep script accepts any combination of the parameter lists documented in
its `--help` output. Set a list to a single value to keep that knob fixed.

## Notes

- The implementation models sequential streams with a small stream table and a
  finite prefetch buffer, which matches the design in the paper closely enough
  for benchmarking.
- The simulator is trace-driven and uses logical reference steps for latency.
  It is useful for comparing policies, but it is not a cycle-accurate CPU
  simulator.
