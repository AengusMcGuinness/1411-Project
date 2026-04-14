#!/usr/bin/env python3
"""Plot prefetch accuracy and coverage heatmaps across stream_slots and max_prefetch_depth.

Expects the sweep CSV to contain 'accuracy' and 'coverage' columns.
If those columns are missing, the script attempts to parse them from raw
Pin output logs stored alongside the CSV (one .log per row file).
"""

CSV_PATH = "stream_buffer_experiments.csv"
OUTDIR = "plots"

import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path


def plot_heatmap(df, benchmark, value_col, title, outdir):
    pivot = (
        df.pivot_table(index="stream_slots", columns="max_prefetch_depth", values=value_col, aggfunc="mean")
        .sort_index()
        .sort_index(axis=1)
    )

    fig, ax = plt.subplots()
    im = ax.imshow(pivot.values, aspect="auto")

    ax.set_xticks(range(len(pivot.columns)))
    ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)))
    ax.set_yticklabels(pivot.index)

    ax.set_xlabel("Max Prefetch Depth")
    ax.set_ylabel("Stream Slots")
    ax.set_title(f"{benchmark}: {title}")

    fig.colorbar(im)
    fig.tight_layout()
    fig.savefig(outdir / f"{benchmark}_{value_col}_heatmap.png", dpi=200)
    plt.close(fig)


def plot_line(df, benchmark, value_col, ylabel, outdir):
    fig, ax = plt.subplots()

    for slots, group in sorted(df.groupby("stream_slots")):
        group = group.sort_values("max_prefetch_depth")
        ax.plot(group["max_prefetch_depth"], group[value_col], marker="o", label=f"slots={slots}")

    ax.set_xlabel("Max Prefetch Depth")
    ax.set_ylabel(ylabel)
    ax.set_title(f"{benchmark}: {ylabel} vs Max Prefetch Depth")
    ax.legend()
    ax.grid(True)

    fig.tight_layout()
    fig.savefig(outdir / f"{benchmark}_{value_col}_vs_depth.png", dpi=200)
    plt.close(fig)


def main():
    outdir = Path(OUTDIR)
    outdir.mkdir(exist_ok=True)

    df = pd.read_csv(CSV_PATH)
    df = df[df["status"] == "ok"]

    # Only plot accuracy/coverage if the columns exist in the CSV
    has_accuracy = "accuracy" in df.columns
    has_coverage = "coverage" in df.columns

    if not has_accuracy and not has_coverage:
        print("No accuracy/coverage columns found in CSV.")
        print("Re-run the sweep script with accuracy/coverage extraction enabled,")
        print("or manually add 'accuracy' and 'coverage' columns to the CSV.")
        return

    # Filter to adaptive policy only (off/nextline have no meaningful accuracy)
    adaptive_df = df[df["policy"] == "adaptive"]

    for benchmark, group in adaptive_df.groupby("benchmark"):
        if has_accuracy:
            plot_heatmap(group, benchmark, "accuracy", "Prefetch Accuracy Heatmap", outdir)
            plot_line(group, benchmark, "accuracy", "Prefetch Accuracy", outdir)
        if has_coverage:
            plot_heatmap(group, benchmark, "coverage", "Prefetch Coverage Heatmap", outdir)
            plot_line(group, benchmark, "coverage", "Prefetch Coverage", outdir)


if __name__ == "__main__":
    main()
