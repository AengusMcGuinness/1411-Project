#!/usr/bin/env python3
"""Plot hardware cost (bits) vs. performance tradeoff.

Hardware cost is estimated from configuration parameters:
  Stream table  = stream_slots * (1 valid + 1 direction + 46 addr + 16 length + 16 lifetime + 16 touch)
  Prefetch buf  = prefetch_buffer_lines * (46 addr + 32 ready_time + 1 used + 1 claimed)
  Histogram     = 2 * (max_stream_length + 2) * 16  [current + next epoch]
"""

import csv
import matplotlib.pyplot as plt
from collections import defaultdict
from pathlib import Path

CSV_PATH = "results/stream_buffer_experiments.csv"
OUTDIR = Path("plots")

ADDR_BITS = 46
LENGTH_BITS = 16
LIFETIME_BITS = 16
TOUCH_BITS = 16
READY_TIME_BITS = 32
COUNTER_BITS = 16


def compute_hardware_bits(row):
    stream_table = int(row["stream_slots"]) * (1 + 1 + ADDR_BITS + LENGTH_BITS + LIFETIME_BITS + TOUCH_BITS)
    prefetch_buf = int(row["prefetch_buffer_lines"]) * (ADDR_BITS + READY_TIME_BITS + 1 + 1)
    histogram = 2 * (int(row["max_stream_length"]) + 2) * COUNTER_BITS
    return stream_table + prefetch_buf + histogram


def read_csv(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if row["status"] != "ok":
                continue
            row["speedup"] = float(row["speedup"])
            row["hardware_bits"] = compute_hardware_bits(row)
            rows.append(row)
    return rows


def main():
    OUTDIR.mkdir(exist_ok=True)
    rows = read_csv(CSV_PATH)
    benchmarks = sorted(set(r["benchmark"] for r in rows))
    print(f"Loaded {len(rows)} ok rows, benchmarks: {benchmarks}")

    fig, axes = plt.subplots(len(benchmarks), 1, figsize=(8, 5 * len(benchmarks)))
    if len(benchmarks) == 1:
        axes = [axes]

    for ax, benchmark in zip(axes, benchmarks):
        bench_rows = [r for r in rows if r["benchmark"] == benchmark]
        for policy in sorted(set(r["policy"] for r in bench_rows)):
            policy_rows = [r for r in bench_rows if r["policy"] == policy]
            xs = [r["hardware_bits"] for r in policy_rows]
            ys = [r["speedup"] for r in policy_rows]
            ax.scatter(xs, ys, label=policy, alpha=0.7, s=40)

        ax.set_xlabel("Hardware Cost (bits)")
        ax.set_ylabel("Speedup vs. Baseline")
        ax.set_title(f"{benchmark}: Hardware Cost vs. Performance")
        ax.legend()
        ax.grid(True, linestyle="--", alpha=0.5)

    plt.tight_layout()
    fig.savefig(OUTDIR / "hardware_cost_vs_speedup.png", dpi=200)
    plt.close(fig)
    print("  wrote hardware_cost_vs_speedup.png")

    # Summary CSV grouped by (benchmark, policy, hardware_bits)
    buckets = defaultdict(list)
    for row in rows:
        buckets[(row["benchmark"], row["policy"], row["hardware_bits"])].append(row["speedup"])

    with open(OUTDIR / "hardware_cost_summary.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["benchmark", "policy", "hardware_bits", "speedup"])
        for (bench, policy, hw), speeds in sorted(buckets.items()):
            writer.writerow([bench, policy, hw, sum(speeds) / len(speeds)])
    print("  wrote hardware_cost_summary.csv")


if __name__ == "__main__":
    main()
