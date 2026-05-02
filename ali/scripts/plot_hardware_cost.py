#!/usr/bin/env python3
"""Plot hardware cost breakdown for the four distinct configurations swept.

Hardware cost is estimated from configuration parameters:
  Stream table  = stream_slots * (1 valid + 1 direction + 46 addr + 16 length + 16 lifetime + 16 touch)
  Prefetch buf  = prefetch_buffer_lines * (46 addr + 32 ready_time + 1 used + 1 claimed)
  Histogram     = 2 * (max_stream_length + 2) * 16  [current + next epoch]

Cost depends only on (stream_slots, max_stream_length) — not on policy or depth.
"""

import matplotlib.pyplot as plt
from pathlib import Path

OUTDIR = Path("plots")

ADDR_BITS = 46
LENGTH_BITS = 16
LIFETIME_BITS = 16
TOUCH_BITS = 16
READY_TIME_BITS = 32
COUNTER_BITS = 16
PREFETCH_BUFFER_LINES = 16


def compute_components(slots, max_len):
    stream_table = slots * (1 + 1 + ADDR_BITS + LENGTH_BITS + LIFETIME_BITS + TOUCH_BITS)
    prefetch_buf = PREFETCH_BUFFER_LINES * (ADDR_BITS + READY_TIME_BITS + 1 + 1)
    histogram = 2 * (max_len + 2) * COUNTER_BITS
    return stream_table, prefetch_buf, histogram


def main():
    OUTDIR.mkdir(exist_ok=True)

    configs = [
        (4, 8),
        (4, 32),
        (8, 8),
        (8, 32),
    ]
    labels = [f"slots={s}\nmax_len={m}" for s, m in configs]

    stream_costs, prefetch_costs, hist_costs = [], [], []
    for slots, max_len in configs:
        s, p, h = compute_components(slots, max_len)
        stream_costs.append(s)
        prefetch_costs.append(p)
        hist_costs.append(h)

    x = range(len(configs))
    fig, ax = plt.subplots(figsize=(7, 4))

    bars_s = ax.bar(x, stream_costs, label="Stream table", color="steelblue")
    bars_p = ax.bar(x, prefetch_costs, bottom=stream_costs, label="Prefetch buffer", color="tomato")
    bars_h = ax.bar(x, hist_costs,
                    bottom=[s + p for s, p in zip(stream_costs, prefetch_costs)],
                    label="Histogram (2 epochs)", color="mediumseagreen")

    # Annotate total on top of each bar
    for i, (s, p, h) in enumerate(zip(stream_costs, prefetch_costs, hist_costs)):
        total = s + p + h
        ax.text(i, total + 20, f"{total} b", ha="center", va="bottom", fontsize=9)

    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylabel("Storage (bits)")
    ax.set_title("Hardware Cost Breakdown by Configuration")
    ax.legend(loc="upper left")
    ax.set_ylim(0, max(s + p + h for s, p, h in zip(stream_costs, prefetch_costs, hist_costs)) * 1.15)
    ax.grid(axis="y", linestyle="--", alpha=0.5)

    plt.tight_layout()
    fig.savefig(OUTDIR / "hardware_cost_vs_speedup.png", dpi=200)
    plt.close(fig)
    print("  wrote hardware_cost_vs_speedup.png")


if __name__ == "__main__":
    main()
