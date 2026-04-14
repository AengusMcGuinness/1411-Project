#!/usr/bin/env python3
"""Plot speedup vs. stream buffer parameters for adaptive, nextline, and off policies."""

import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path

CSV_PATH = "stream_buffer_experiments.csv"
OUTDIR = Path("plots")


def plot_speedup_vs_param(df, param, xlabel, benchmarks, outdir):
    fig, axes = plt.subplots(len(benchmarks), 1, figsize=(8, 5 * len(benchmarks)))
    if len(benchmarks) == 1:
        axes = [axes]

    for ax, benchmark in zip(axes, benchmarks):
        bench_df = df[df["benchmark"] == benchmark]
        for policy, pdf in sorted(bench_df.groupby("policy")):
            grouped = pdf.groupby(param)["speedup"].mean().sort_index()
            ax.plot(grouped.index, grouped.values, marker="o", label=policy)

        ax.set_xlabel(xlabel)
        ax.set_ylabel("Speedup vs. Baseline")
        ax.set_title(f"{benchmark}: Speedup vs {xlabel}")
        ax.legend()
        ax.grid(True, linestyle="--", alpha=0.5)

    plt.tight_layout()
    fig.savefig(outdir / f"speedup_vs_{param}.png", dpi=200)
    plt.close(fig)


def main():
    OUTDIR.mkdir(exist_ok=True)
    df = pd.read_csv(CSV_PATH)
    df = df[df["status"] == "ok"]

    benchmarks = sorted(df["benchmark"].unique())

    plot_speedup_vs_param(df, "stream_slots", "Stream Slots", benchmarks, OUTDIR)
    plot_speedup_vs_param(df, "max_prefetch_depth", "Max Prefetch Depth", benchmarks, OUTDIR)
    plot_speedup_vs_param(df, "max_stream_length", "Max Stream Length", benchmarks, OUTDIR)


if __name__ == "__main__":
    main()
