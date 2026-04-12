# Adaptive Stream Buffer

This repository now includes a C++ implementation of an adaptive stream buffer
prefetcher inspired by the paper in `Paper-A.pdf`.

What is implemented:

- A reusable C++ simulator for adaptive and next-line stream prefetching.
- A standalone trace-driven CLI so the model can be benchmarked locally.
- An Intel Pin Pintool front-end that reuses the same simulator core.

## Build

Build the standalone simulator:

```bash
make
```

Build the Pintool once `PIN_ROOT` points at an Intel Pin installation:

```bash
make -C pintool PIN_ROOT=/path/to/pin
```

## Trace Format

The standalone simulator reads a simple text trace:

- `R 0x1000` for a read
- `W 0x1000` for a write

You can pass the trace file as the last argument or pipe it through stdin.

## Run The Simulator

```bash
./build/stream_buffer_sim --policy adaptive trace.txt
./build/stream_buffer_sim --policy nextline trace.txt
./build/stream_buffer_sim --policy off trace.txt
```

Useful knobs:

- `--line-size`
- `--demand-cache-lines`
- `--prefetch-buffer-lines`
- `--stream-slots`
- `--max-stream-length`
- `--epoch-reads`
- `--stream-lifetime`
- `--prefetch-latency`
- `--miss-latency`
- `--hit-latency`
- `--write-latency`
- `--base-cost`
- `--max-prefetch-depth`

## Run The Pintool

After building the Pintool, run it through Pin:

```bash
pin -t pintool/obj-intel64/adaptive_stream_buffer_pintool.so \
    -policy adaptive \
    -- ./your_program
```

The Pintool prints a selected-policy summary and a no-prefetch baseline so you
can estimate the speedup from a single run.

## Notes

- The implementation models sequential streams with a small stream table and a
  finite prefetch buffer, which matches the design in the paper closely enough
  for benchmarking.
- The simulator is trace-driven and uses logical reference steps for latency.
  It is useful for comparing policies, but it is not a cycle-accurate CPU
  simulator.

