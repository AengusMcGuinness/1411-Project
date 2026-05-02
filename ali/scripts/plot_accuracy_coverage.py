#!/usr/bin/env python3
"""Plot prefetch accuracy and coverage heatmaps across stream_slots and max_prefetch_depth."""

import csv
import matplotlib.pyplot as plt
from collections import defaultdict
from pathlib import Path

CSV_PATH = "results/stream_buffer_experiments.csv"
OUTDIR = Path("plots")


def read_csv(path):
    rows = []
    has_accuracy = has_coverage = False
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames or []
        has_accuracy = "accuracy" in fieldnames
        has_coverage = "coverage" in fieldnames
        for row in reader:
            if row["status"] != "ok":
                continue
            row["stream_slots"] = int(row["stream_slots"])
            row["max_prefetch_depth"] = int(row["max_prefetch_depth"])
            if has_accuracy:
                row["accuracy"] = float(row["accuracy"])
            if has_coverage:
                row["coverage"] = float(row["coverage"])
            rows.append(row)
    return rows, has_accuracy, has_coverage


def pivot_mean(rows, row_key, col_key, value_key):
    buckets = defaultdict(list)
    for row in rows:
        buckets[(row[row_key], row[col_key])].append(row[value_key])
    row_vals = sorted(set(r[row_key] for r in rows))
    col_vals = sorted(set(r[col_key] for r in rows))
    grid = [
        [sum(buckets.get((rv, cv), [0.0])) / max(len(buckets.get((rv, cv), [0.0])), 1)
         for cv in col_vals]
        for rv in row_vals
    ]
    return row_vals, col_vals, grid


def plot_heatmap(rows, benchmark, value_col, title, outdir):
    row_vals, col_vals, grid = pivot_mean(rows, "stream_slots", "max_prefetch_depth", value_col)
    fig, ax = plt.subplots()
    im = ax.imshow(grid, aspect="auto")
    ax.set_xticks(range(len(col_vals)))
    ax.set_xticklabels(col_vals)
    ax.set_yticks(range(len(row_vals)))
    ax.set_yticklabels(row_vals)
    ax.set_xlabel("Max Prefetch Depth")
    ax.set_ylabel("Stream Slots")
    ax.set_title(f"{benchmark}: {title}")
    fig.colorbar(im)
    fig.tight_layout()
    fig.savefig(outdir / f"{benchmark}_{value_col}_heatmap.png", dpi=200)
    plt.close(fig)
    print(f"  wrote {benchmark}_{value_col}_heatmap.png")


def plot_line(rows, benchmark, value_col, ylabel, outdir):
    fig, ax = plt.subplots()
    slots_groups = defaultdict(list)
    for row in rows:
        slots_groups[row["stream_slots"]].append(row)
    for slots in sorted(slots_groups.keys()):
        group = sorted(slots_groups[slots], key=lambda r: r["max_prefetch_depth"])
        ax.plot([r["max_prefetch_depth"] for r in group],
                [r[value_col] for r in group],
                marker="o", label=f"slots={slots}")
    ax.set_xlabel("Max Prefetch Depth")
    ax.set_ylabel(ylabel)
    ax.set_title(f"{benchmark}: {ylabel} vs Max Prefetch Depth")
    ax.legend()
    ax.grid(True)
    fig.tight_layout()
    fig.savefig(outdir / f"{benchmark}_{value_col}_vs_depth.png", dpi=200)
    plt.close(fig)
    print(f"  wrote {benchmark}_{value_col}_vs_depth.png")


def main():
    OUTDIR.mkdir(exist_ok=True)
    rows, has_accuracy, has_coverage = read_csv(CSV_PATH)

    if not has_accuracy and not has_coverage:
        print("No accuracy/coverage columns in CSV — skipping accuracy/coverage plots.")
        return

    adaptive_rows = [r for r in rows if r["policy"] == "adaptive"]
    for benchmark in sorted(set(r["benchmark"] for r in adaptive_rows)):
        bench_rows = [r for r in adaptive_rows if r["benchmark"] == benchmark]
        if has_accuracy:
            plot_heatmap(bench_rows, benchmark, "accuracy", "Prefetch Accuracy Heatmap", OUTDIR)
            plot_line(bench_rows, benchmark, "accuracy", "Prefetch Accuracy", OUTDIR)
        if has_coverage:
            plot_heatmap(bench_rows, benchmark, "coverage", "Prefetch Coverage Heatmap", OUTDIR)
            plot_line(bench_rows, benchmark, "coverage", "Prefetch Coverage", OUTDIR)


if __name__ == "__main__":
    main()
