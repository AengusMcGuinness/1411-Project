#!/usr/bin/env python3

# Hardcoded paths
CSV_PATH = "hrt_pt_experiments.csv"
OUTDIR = "plots"

import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path


def plot_accuracy_vs_pt(df, benchmark, outdir):
    fig, ax = plt.subplots()

    for hrt, group in sorted(df.groupby("hrt")):
        group = group.sort_values("pt")
        ax.plot(group["pt"], group["accuracy"], marker="o", label=f"HRT={hrt}")

    ax.set_xscale("log", base=2)
    ax.set_xlabel("PT entries")
    ax.set_ylabel("Accuracy")
    ax.set_title(f"{benchmark}: Accuracy vs PT")
    ax.legend()
    ax.grid(True)

    fig.tight_layout()
    fig.savefig(outdir / f"{benchmark}_accuracy_vs_pt.png", dpi=200)
    plt.close(fig)


def plot_mispred_vs_pt(df, benchmark, outdir):
    fig, ax = plt.subplots()

    for hrt, group in sorted(df.groupby("hrt")):
        group = group.sort_values("pt")
        ax.plot(group["pt"], group["misprediction_rate"], marker="o", label=f"HRT={hrt}")

    ax.set_xscale("log", base=2)
    ax.set_xlabel("PT entries")
    ax.set_ylabel("Misprediction rate")
    ax.set_title(f"{benchmark}: Misprediction Rate vs PT")
    ax.legend()
    ax.grid(True)

    fig.tight_layout()
    fig.savefig(outdir / f"{benchmark}_misprediction_vs_pt.png", dpi=200)
    plt.close(fig)


def plot_heatmap(df, benchmark, column, title, outdir):
    pivot = df.pivot(index="hrt", columns="pt", values=column).sort_index().sort_index(axis=1)

    fig, ax = plt.subplots()
    im = ax.imshow(pivot.values, aspect="auto")

    ax.set_xticks(range(len(pivot.columns)))
    ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)))
    ax.set_yticklabels(pivot.index)

    ax.set_xlabel("PT entries")
    ax.set_ylabel("HRT entries")
    ax.set_title(f"{benchmark}: {title}")

    fig.colorbar(im)
    fig.tight_layout()

    fig.savefig(outdir / f"{benchmark}_{column}_heatmap.png", dpi=200)
    plt.close(fig)


def main():
    csv_path = Path(CSV_PATH)
    outdir = Path(OUTDIR)
    outdir.mkdir(exist_ok=True)

    df = pd.read_csv(csv_path)

    for benchmark, group in df.groupby("benchmark"):
        plot_accuracy_vs_pt(group, benchmark, outdir)
        plot_mispred_vs_pt(group, benchmark, outdir)
        plot_heatmap(group, benchmark, "accuracy", "Accuracy Heatmap", outdir)
        plot_heatmap(group, benchmark, "misprediction_rate", "Misprediction Rate Heatmap", outdir)


if __name__ == "__main__":
    main()
