#!/usr/bin/env python3
"""Plot hardware cost (bits) vs. performance tradeoff.

Hardware cost is estimated from configuration parameters:
  Stream table  = stream_slots * (1 valid + 1 direction + 46 addr + 16 length + 16 lifetime + 16 touch)
  Prefetch buf  = prefetch_buffer_lines * (46 addr + 32 ready_time + 1 used + 1 claimed)
  Histogram     = 2 * (max_stream_length + 2) * 16  [current + next epoch]
"""

import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path

CSV_PATH = "stream_buffer_experiments.csv"
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


def main():
    OUTDIR.mkdir(exist_ok=True)
    df = pd.read_csv(CSV_PATH)
    df = df[df["status"] == "ok"]

    df["hardware_bits"] = df.apply(compute_hardware_bits, axis=1)

    benchmarks = sorted(df["benchmark"].unique())

    fig, axes = plt.subplots(len(benchmarks), 1, figsize=(8, 5 * len(benchmarks)))
    if len(benchmarks) == 1:
        axes = [axes]

    for ax, benchmark in zip(axes, benchmarks):
        bench_df = df[df["benchmark"] == benchmark]
        for policy, pdf in sorted(bench_df.groupby("policy")):
            ax.scatter(pdf["hardware_bits"], pdf["speedup"], label=policy, alpha=0.7, s=40)

        ax.set_xlabel("Hardware Cost (bits)")
        ax.set_ylabel("Speedup vs. Baseline")
        ax.set_title(f"{benchmark}: Hardware Cost vs. Performance")
        ax.legend()
        ax.grid(True, linestyle="--", alpha=0.5)

    plt.tight_layout()
    fig.savefig(OUTDIR / "hardware_cost_vs_speedup.png", dpi=200)
    plt.close(fig)

    # Also save a summary table
    summary = (
        df.groupby(["benchmark", "policy", "hardware_bits"])["speedup"]
        .mean()
        .reset_index()
        .sort_values(["benchmark", "hardware_bits"])
    )
    summary.to_csv(OUTDIR / "hardware_cost_summary.csv", index=False)


if __name__ == "__main__":
    main()
