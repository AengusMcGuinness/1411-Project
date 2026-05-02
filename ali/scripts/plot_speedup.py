#!/usr/bin/env python3
"""Plot speedup vs. stream buffer parameters for adaptive, nextline, and off policies."""

import csv
import matplotlib.pyplot as plt
from collections import defaultdict
from pathlib import Path

CSV_PATH = "results/stream_buffer_experiments.csv"
OUTDIR = Path("plots")


def read_csv(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if row["status"] != "ok":
                continue
            row["speedup"] = float(row["speedup"])
            row["stream_slots"] = int(row["stream_slots"])
            row["max_prefetch_depth"] = int(row["max_prefetch_depth"])
            row["max_stream_length"] = int(row["max_stream_length"])
            rows.append(row)
    return rows


def groupby_mean(rows, group_key, value_key):
    buckets = defaultdict(list)
    for row in rows:
        buckets[row[group_key]].append(row[value_key])
    return sorted((k, sum(v) / len(v)) for k, v in buckets.items())


def plot_speedup_vs_param(rows, param, xlabel, benchmarks, outdir):
    fig, axes = plt.subplots(len(benchmarks), 1, figsize=(8, 5 * len(benchmarks)))
    if len(benchmarks) == 1:
        axes = [axes]

    for ax, benchmark in zip(axes, benchmarks):
        bench_rows = [r for r in rows if r["benchmark"] == benchmark]
        for policy in sorted(set(r["policy"] for r in bench_rows)):
            policy_rows = [r for r in bench_rows if r["policy"] == policy]
            grouped = groupby_mean(policy_rows, param, "speedup")
            if grouped:
                xs, ys = zip(*grouped)
                ax.plot(xs, ys, marker="o", label=policy)

        ax.set_xlabel(xlabel)
        ax.set_ylabel("Speedup vs. Baseline")
        ax.set_title(f"{benchmark}: Speedup vs {xlabel}")
        ax.legend()
        ax.grid(True, linestyle="--", alpha=0.5)

    plt.tight_layout()
    fig.savefig(outdir / f"speedup_vs_{param}.png", dpi=200)
    plt.close(fig)
    print(f"  wrote speedup_vs_{param}.png")


def main():
    OUTDIR.mkdir(exist_ok=True)
    rows = read_csv(CSV_PATH)
    benchmarks = sorted(set(r["benchmark"] for r in rows))
    print(f"Loaded {len(rows)} ok rows, benchmarks: {benchmarks}")

    plot_speedup_vs_param(rows, "stream_slots", "Stream Slots", benchmarks, OUTDIR)
    plot_speedup_vs_param(rows, "max_prefetch_depth", "Max Prefetch Depth", benchmarks, OUTDIR)
    plot_speedup_vs_param(rows, "max_stream_length", "Max Stream Length", benchmarks, OUTDIR)


if __name__ == "__main__":
    main()
