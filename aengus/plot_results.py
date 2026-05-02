#!/usr/bin/env python3
"""Generate plots for all sweep_results CSVs."""

import csv
import os
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sweep_results")
PLOTS_DIR   = os.path.join(RESULTS_DIR, "plots")
os.makedirs(PLOTS_DIR, exist_ok=True)

BENCHMARKS = ["libquantum", "hmmer", "dealII"]
COLORS     = {"libquantum": "#1f77b4", "hmmer": "#d62728", "dealII": "#2ca02c"}
MARKERS    = {"libquantum": "o", "hmmer": "s", "dealII": "^"}


def read_csv(path):
    """Return (header_list, list_of_row_dicts)."""
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    return reader.fieldnames, rows


def save(fig, name):
    path = os.path.join(PLOTS_DIR, name)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved {path}")


def millions(x, _):
    return f"{x/1e6:.0f}M"


# ── 1. Associativity sweep ────────────────────────────────────────────────────
def plot_assoc():
    path = os.path.join(RESULTS_DIR, "assoc", "assoc_misses.csv")
    if not os.path.exists(path):
        print("skip assoc (file not found)"); return
    _, rows = read_csv(path)

    x  = [int(r["associativity"]) for r in rows]
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for bench in BENCHMARKS:
        y = [int(r[bench]) for r in rows]
        ax.plot(x, y, marker=MARKERS[bench], color=COLORS[bench],
                linewidth=2, markersize=6, label=bench)

    ax.set_xlabel("L1D Associativity")
    ax.set_ylabel("L1D Misses")
    ax.set_title("L1D Misses vs Associativity")
    ax.set_xticks(x)
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(millions))
    ax.legend(); ax.grid(True, alpha=0.3)
    save(fig, "assoc_misses.png")


# ── 2 & 3. Stream buffer depth sweep ─────────────────────────────────────────
def plot_stream():
    for fname, ylabel, title, outname in [
        ("stream_eff_misses.csv",
         "Effective L1D Misses (L1D − SB hits)",
         "Effective L1D Misses vs Stream Buffer Depth",
         "stream_eff_misses.png"),
        ("stream_l2_requests.csv",
         "Total L2 Requests (demand + prefetch)",
         "Total L2 Requests vs Stream Buffer Depth",
         "stream_l2_requests.png"),
    ]:
        path = os.path.join(RESULTS_DIR, "stream", fname)
        if not os.path.exists(path):
            print(f"skip {fname}"); continue
        _, rows = read_csv(path)

        x = [int(r["depth"]) for r in rows]
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for bench in BENCHMARKS:
            y = [int(r[bench]) for r in rows]
            ax.plot(x, y, marker=MARKERS[bench], color=COLORS[bench],
                    linewidth=2, markersize=6, label=bench)

        ax.set_xlabel("Stream Buffer Depth (lines prefetched)")
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.set_xticks(x)
        ax.yaxis.set_major_formatter(ticker.FuncFormatter(millions))
        ax.legend(); ax.grid(True, alpha=0.3)
        save(fig, outname)


# ── 4 & 5. Stream count sweep ─────────────────────────────────────────────────
def plot_streams():
    for fname, ylabel, title, outname in [
        ("streams_eff_misses.csv",
         "Effective L1D Misses (L1D − SB hits)",
         "Effective L1D Misses vs Number of Streams (depth=1)",
         "streams_eff_misses.png"),
        ("streams_l2_requests.csv",
         "Total L2 Requests (demand + prefetch)",
         "Total L2 Requests vs Number of Streams (depth=1)",
         "streams_l2_requests.png"),
    ]:
        path = os.path.join(RESULTS_DIR, "streams", fname)
        if not os.path.exists(path):
            print(f"skip {fname}"); continue
        _, rows = read_csv(path)

        x = [int(r["streams"]) for r in rows]
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for bench in BENCHMARKS:
            y = [int(r[bench]) for r in rows]
            ax.plot(x, y, marker=MARKERS[bench], color=COLORS[bench],
                    linewidth=2, markersize=6, label=bench)

        ax.set_xlabel("Number of Concurrent Streams")
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.set_xticks(x)
        ax.yaxis.set_major_formatter(ticker.FuncFormatter(millions))
        ax.legend(); ax.grid(True, alpha=0.3)
        save(fig, outname)


# ── 6. 2D heatmaps (depth × streams) ────────────────────────────────────────
def plot_2d():
    depths       = [0, 1, 2, 4, 8]
    stream_counts = [1, 2, 4, 8]

    for bench in BENCHMARKS:
        for suffix, metric_label, outname in [
            ("eff", "Effective L1D Misses (millions)", f"2d_{bench}_eff.png"),
            ("l2",  "Total L2 Requests (millions)",    f"2d_{bench}_l2.png"),
        ]:
            path = os.path.join(RESULTS_DIR, "2d", f"2d_{bench}_{suffix}.csv")
            if not os.path.exists(path):
                print(f"skip {path}"); continue
            _, rows = read_csv(path)

            # Build matrix: rows=depth, cols=stream count
            matrix = np.array([
                [int(r[f"s{s}"]) / 1e6 for s in stream_counts]
                for r in rows
            ])

            fig, ax = plt.subplots(figsize=(6, 4.5))
            im = ax.imshow(matrix, aspect="auto", cmap="YlOrRd_r",
                           origin="upper")
            cbar = fig.colorbar(im, ax=ax)
            cbar.set_label(metric_label)

            ax.set_xticks(range(len(stream_counts)))
            ax.set_xticklabels([str(s) for s in stream_counts])
            ax.set_yticks(range(len(depths)))
            ax.set_yticklabels([str(d) for d in depths])
            ax.set_xlabel("Number of Streams")
            ax.set_ylabel("Stream Buffer Depth")
            ax.set_title(f"{bench} — {metric_label}")

            # Annotate each cell with its value
            for i in range(len(depths)):
                for j in range(len(stream_counts)):
                    ax.text(j, i, f"{matrix[i, j]:.0f}M",
                            ha="center", va="center", fontsize=7,
                            color="black")

            save(fig, outname)


if __name__ == "__main__":
    print(f"Writing plots to {PLOTS_DIR}/")
    plot_assoc()
    plot_stream()
    plot_streams()
    plot_2d()
    print("Done.")
