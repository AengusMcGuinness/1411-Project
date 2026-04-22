#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path
from typing import Iterable, Optional

repo_dir = Path(__file__).resolve().parent
mpl_dir = repo_dir / ".mplconfig"
mpl_dir.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("MPLCONFIGDIR", str(mpl_dir))
cache_dir = repo_dir / ".cache"
cache_dir.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("XDG_CACHE_HOME", str(cache_dir))

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.style.use("seaborn-v0_8-whitegrid")


NATIVE_ASSOC_POINTS = {
    "libquantum": {"x": 8.0, "y": 4278884.0, "label": "Native libquantum"},
    "hmmer": {"x": 8.0, "y": 414607.0, "label": "Native hmmer"},
}

DEFAULT_INPUTS = [
    "assoc_misses.csv",
    "victim_dm_misses.csv",
    "libquantum_dm_vs_8way.csv",
    "hmmer_dm_vs_8way.csv",
    "stream_eff_misses.csv",
    "stream_l2_requests.csv",
]


def read_csv(path: Path) -> tuple[list[str], list[list[str]]]:
    with path.open(newline="") as f:
        rows = list(csv.reader(f))
    if not rows:
        raise ValueError(f"{path} is empty")
    return [cell.strip() for cell in rows[0]], rows[1:]


def parse_number(value: str) -> Optional[float]:
    value = value.strip()
    if not value or value.upper() == "NA":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def save_figure(fig: plt.Figure, out_base: Path) -> None:
    fig.tight_layout()
    fig.savefig(out_base.with_suffix(".png"))
    fig.savefig(out_base.with_suffix(".pdf"))
    plt.close(fig)


def pretty_series_label(raw: str) -> str:
    mapping = {
        "direct_mapped": "Direct-mapped L1D",
        "assoc8": "8-way L1D",
    }
    return mapping.get(raw, raw)


def plot_multi_series(
    csv_path: Path,
    out_dir: Path,
    title: str,
    xlabel: str,
    ylabel: str,
    native_markers: Optional[Iterable[dict[str, object]]] = None,
) -> None:
    header, rows = read_csv(csv_path)
    if len(header) < 3:
        raise ValueError(f"{csv_path} needs at least 3 columns for this plot")

    x_vals: list[float] = []
    series: dict[str, list[Optional[float]]] = {name: [] for name in header[1:]}

    for row in rows:
        if len(row) < len(header):
            row = row + [""] * (len(header) - len(row))
        x = parse_number(row[0])
        if x is None:
            continue
        x_vals.append(x)
        for idx, name in enumerate(header[1:], start=1):
            series[name].append(parse_number(row[idx]))

    if not x_vals:
        raise ValueError(f"{csv_path} does not contain any plottable numeric data")

    fig, ax = plt.subplots(figsize=(9, 6), dpi=160)
    palette = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e", "#17becf"]

    for idx, name in enumerate(header[1:]):
        points = [(x, y) for x, y in zip(x_vals, series[name]) if y is not None]
        if not points:
            continue
        px, py = zip(*points)
        ax.plot(
            px,
            py,
            marker="o",
            linewidth=2.2,
            color=palette[idx % len(palette)],
            label=pretty_series_label(name),
        )

    if native_markers:
        for marker in native_markers:
            native_x = float(marker["x"])
            native_y = float(marker["y"])
            label = str(marker["label"])
            ax.scatter(
                [native_x],
                [native_y],
                marker="^",
                s=90,
                color="#8c564b",
                zorder=5,
                label=label,
            )
            ax.annotate(
                label,
                (native_x, native_y),
                textcoords="offset points",
                xytext=(8, 8),
                ha="left",
                fontsize=9,
                color="#8c564b",
            )

    ax.set_title(title)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_xticks(sorted(set(x_vals)))
    ax.legend(frameon=False, loc="best")
    out_dir.mkdir(parents=True, exist_ok=True)
    save_figure(fig, out_dir / csv_path.stem)


def plot_single_series(
    csv_path: Path,
    out_dir: Path,
    title: str,
    xlabel: str,
    ylabel: str,
) -> None:
    header, rows = read_csv(csv_path)
    if len(header) != 2:
        raise ValueError(f"{csv_path} needs exactly 2 columns for this plot")

    x_vals: list[float] = []
    y_vals: list[float] = []
    for row in rows:
        if len(row) < 2:
            continue
        x = parse_number(row[0])
        y = parse_number(row[1])
        if x is None or y is None:
            continue
        x_vals.append(x)
        y_vals.append(y)

    if not x_vals:
        raise ValueError(f"{csv_path} does not contain any plottable numeric data")

    fig, ax = plt.subplots(figsize=(9, 6), dpi=160)
    ax.plot(x_vals, y_vals, marker="o", linewidth=2.2, color="#1f77b4")
    ax.set_title(title)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_xticks(sorted(set(x_vals)))
    ax.legend([pretty_series_label(header[1])], frameon=False, loc="best")
    out_dir.mkdir(parents=True, exist_ok=True)
    save_figure(fig, out_dir / csv_path.stem)


def plot_assoc_sweep(csv_path: Path, out_dir: Path) -> None:
    plot_multi_series(
        csv_path,
        out_dir,
        title="L1 D-Cache Misses vs Associativity",
        xlabel="L1 D Cache Associativity",
        ylabel="L1 D-Cache Misses",
        native_markers=NATIVE_ASSOC_POINTS.values(),
    )


def plot_victim_sweep(csv_path: Path, out_dir: Path) -> None:
    plot_multi_series(
        csv_path,
        out_dir,
        title="Victim Cache Sweep with Direct-Mapped L1D",
        xlabel="Victim Cache Entries",
        ylabel="Number of Misses = L1D Misses - VC Hits",
    )


def plot_compare_sweep(csv_path: Path, out_dir: Path, benchmark_name: str) -> None:
    plot_multi_series(
        csv_path,
        out_dir,
        title=f"Victim Cache Benefits: {benchmark_name}",
        xlabel="Victim Cache Entries",
        ylabel="Number of Misses = L1D Misses - VC Hits",
    )


def plot_stream_eff_misses(csv_path: Path, out_dir: Path) -> None:
    """Figure 2: effective L1D misses (L1D misses − stream-buffer hits) vs depth."""
    plot_multi_series(
        csv_path,
        out_dir,
        title="Stream Buffer: Effective L1D Misses vs Prefetch Depth",
        xlabel="Stream Buffer Depth (lines prefetched)",
        ylabel="Effective L1D Misses  (L1D misses − SB hits)",
    )


def plot_stream_l2_requests(csv_path: Path, out_dir: Path) -> None:
    """Figure 3: total L2 requests (demand + prefetch traffic) vs depth."""
    plot_multi_series(
        csv_path,
        out_dir,
        title="Stream Buffer: Total L2 Requests vs Prefetch Depth",
        xlabel="Stream Buffer Depth (lines prefetched)",
        ylabel="Total L2 Requests  (demand + prefetch)",
    )


def plot_cacti_access_time(csv_path: Path, out_dir: Path) -> None:
    plot_single_series(
        csv_path,
        out_dir,
        title="CACTI Access Time vs Associativity",
        xlabel="Associativity",
        ylabel="Access Time (ns)",
    )


def discover_inputs(args: list[str]) -> list[Path]:
    if args:
        return [Path(arg) for arg in args]
    discovered: list[Path] = []
    for name in DEFAULT_INPUTS:
        path = Path(name)
        if path.exists():
            discovered.append(path)
    return discovered


def plot_file(csv_path: Path, out_dir: Path) -> bool:
    stem = csv_path.stem

    if stem == "assoc_misses":
        plot_assoc_sweep(csv_path, out_dir)
        return True
    if stem == "victim_dm_misses":
        plot_victim_sweep(csv_path, out_dir)
        return True
    if stem == "libquantum_dm_vs_8way":
        plot_compare_sweep(csv_path, out_dir, "libquantum")
        return True
    if stem == "hmmer_dm_vs_8way":
        plot_compare_sweep(csv_path, out_dir, "hmmer")
        return True
    if stem == "access_time_vs_assoc":
        plot_cacti_access_time(csv_path, out_dir)
        return True
    if stem == "stream_eff_misses":
        plot_stream_eff_misses(csv_path, out_dir)
        return True
    if stem == "stream_l2_requests":
        plot_stream_l2_requests(csv_path, out_dir)
        return True

    header, _ = read_csv(csv_path)
    if len(header) == 2:
        plot_single_series(csv_path, out_dir, title=stem, xlabel=header[0], ylabel=header[1])
        return True
    if len(header) >= 3:
        plot_multi_series(csv_path, out_dir, title=stem, xlabel=header[0], ylabel="Value")
        return True

    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate submission-ready plots for the hw4 CSV outputs."
    )
    parser.add_argument(
        "csv_files",
        nargs="*",
        help="CSV files to plot. If omitted, known hw4 CSVs in the current directory are used.",
    )
    parser.add_argument(
        "--output-dir",
        default="plots",
        help="Directory where PNG and PDF plots are written.",
    )
    args = parser.parse_args()

    csv_files = discover_inputs(args.csv_files)
    if not csv_files:
        raise SystemExit("No CSV files found.")

    out_dir = Path(args.output_dir)
    for csv_path in csv_files:
        if not csv_path.exists():
            print(f"Skipping missing file: {csv_path}")
            continue
        try:
            if plot_file(csv_path, out_dir):
                print(f"Wrote {out_dir / (csv_path.stem + '.png')}")
                print(f"Wrote {out_dir / (csv_path.stem + '.pdf')}")
        except Exception as exc:
            print(f"Skipping {csv_path}: {exc}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
