#!/usr/bin/env python3
"""Aggregate multiple HPA test iterations into averaged CSVs, plots, and a comparison.

Usage:
  python3 aggregate_runs.py \
    --hpa1-dirs dir1 dir2 dir3 \
    --hpa2-dirs dir4 dir5 dir6 \
    --out-dir k6/grafana/2026-02-18/aggregated \
    --label-a "Context-Aware HPA" --label-b "Default HPA"

Each dir is expected to contain a unified_report.csv. The script:
  1. Reads all unified_report.csv files for each HPA group
  2. Aligns them by bucket index (row number, not wall-clock time)
  3. Computes per-column mean and std across iterations
  4. Saves averaged CSVs and generates plots with stddev bands
  5. Runs a comparison between the two averaged datasets
"""

import argparse
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


class _Tee:
    """Duplicate writes to both the original stream and a file."""
    def __init__(self, stream, filepath):
        self._stream = stream
        self._file = open(filepath, "w")
    def write(self, data):
        self._stream.write(data)
        self._file.write(data)
    def flush(self):
        self._stream.flush()
        self._file.flush()
    def close(self):
        self._file.close()


def load_unified_csvs(dirs):
    """Load unified_report.csv from each directory, return list of DataFrames."""
    frames = []
    for d in dirs:
        csv_path = os.path.join(d, "unified_report.csv")
        if not os.path.isfile(csv_path):
            print(f"[WARN] Missing {csv_path}, skipping")
            continue
        df = pd.read_csv(csv_path)
        frames.append(df)
        print(f"[INFO] Loaded {csv_path}: {len(df)} rows, {len(df.columns)} cols")
    return frames


def numeric_columns(df):
    return [c for c in df.columns if c not in ("time_iso", "ts") and pd.api.types.is_numeric_dtype(df[c])]


def aggregate(frames):
    """Compute per-bucket mean and std across iterations.

    Aligns by row index (bucket number) since wall-clock times differ between runs.
    Returns (mean_df, std_df) with a synthetic 'bucket' index column.
    """
    if not frames:
        return None, None

    num_cols = numeric_columns(frames[0])
    min_rows = min(len(f) for f in frames)
    print(f"[INFO] Aggregating {len(frames)} runs, {min_rows} buckets each (trimmed to shortest)")

    trimmed = [f[num_cols].iloc[:min_rows].reset_index(drop=True) for f in frames]
    stacked = pd.concat(trimmed, keys=range(len(trimmed)))

    mean_df = stacked.groupby(level=1).mean()
    std_df = stacked.groupby(level=1).std(ddof=1).fillna(0)

    mean_df.insert(0, "bucket", range(len(mean_df)))
    std_df.insert(0, "bucket", range(len(std_df)))

    return mean_df, std_df


def plot_averaged(mean_df, std_df, out_dir, label, color_idx=0):
    """Generate per-metric plots with mean line and stddev shading."""
    os.makedirs(out_dir, exist_ok=True)
    cols = [c for c in mean_df.columns if c != "bucket"]
    x = mean_df["bucket"]

    k6_cols = [c for c in cols if c.startswith("k6_")]
    replica_cols = [c for c in cols if "Replicas" in c]
    cpu_util_cols = [c for c in cols if "CPU_Utilization_per_Service" in c and "threshold" not in c.lower()]
    cpu_mcore_cols = [c for c in cols if "CPU_Consumption" in c]

    groups = {
        "k6_latency": ([c for c in k6_cols if "ms" in c and "max" not in c], "Latency (ms)"),
        "k6_throughput": ([c for c in k6_cols if c in ("k6_rps", "k6_reqs")], "Requests"),
        "k6_errors": ([c for c in k6_cols if "fail" in c], "Failure %"),
        "replicas": (replica_cols, "Replicas"),
        "cpu_utilization": (cpu_util_cols, "CPU Utilization %"),
        "cpu_mcore": (cpu_mcore_cols, "CPU (mcore)"),
    }

    palette = ["#4F83CC", "#E57342", "#FFB300", "#7CB342", "#8E24AA", "#00ACC1"]

    for name, (metric_cols, ylabel) in groups.items():
        if not metric_cols:
            continue
        fig, ax = plt.subplots(figsize=(12, 5))
        for i, col in enumerate(metric_cols):
            c = palette[i % len(palette)]
            short = col.split("__")[-1] if "__" in col else col
            ax.plot(x, mean_df[col], label=short, color=c, linewidth=1.5)
            ax.fill_between(x, mean_df[col] - std_df[col], mean_df[col] + std_df[col],
                            alpha=0.2, color=c)
        ax.set_xlabel("Bucket (15s intervals)")
        ax.set_ylabel(ylabel)
        ax.set_title(f"{label} - {name} (mean +/- stddev, n={len(std_df)})")
        ax.legend(fontsize=8, loc="best")
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, f"avg_{name}.png"), dpi=150)
        plt.close()

    print(f"[INFO] Saved {len([g for g in groups.values() if g[0]])} averaged plots to {out_dir}/")


def plot_comparison(mean1, std1, mean2, std2, out_dir, label_a, label_b):
    """Side-by-side comparison plots for key metrics."""
    os.makedirs(out_dir, exist_ok=True)
    x = mean1["bucket"]

    key_metrics = [
        ("k6_p50_ms", "P50 Latency (ms)"),
        ("k6_p95_ms", "P95 Latency (ms)"),
        ("k6_rps", "Throughput (rps)"),
        ("k6_fail_pct", "Failure Rate (%)"),
    ]

    replica_cols = [c for c in mean1.columns if "Replicas" in c]

    fig, axes = plt.subplots(2, 3, figsize=(20, 10))
    axes = axes.flatten()

    for idx, (col, title) in enumerate(key_metrics):
        if col not in mean1.columns or col not in mean2.columns:
            continue
        ax = axes[idx]
        ax.plot(x, mean1[col], label=label_a, color="#4F83CC", linewidth=1.5)
        ax.fill_between(x, mean1[col] - std1[col], mean1[col] + std1[col], alpha=0.2, color="#4F83CC")
        ax.plot(x, mean2[col], label=label_b, color="#E57342", linewidth=1.5)
        ax.fill_between(x, mean2[col] - std2[col], mean2[col] + std2[col], alpha=0.2, color="#E57342")
        ax.set_title(title)
        ax.set_xlabel("Bucket")
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)

    if replica_cols:
        ax = axes[4]
        for i, col in enumerate(replica_cols):
            short = col.split("__")[-1] if "__" in col else col
            c_a = ["#4F83CC", "#2196F3", "#1565C0", "#0D47A1"][i % 4]
            c_b = ["#E57342", "#FF7043", "#D84315", "#BF360C"][i % 4]
            if col in mean1.columns:
                ax.plot(x, mean1[col], label=f"{label_a} {short}", color=c_a, linewidth=1, linestyle="-")
            if col in mean2.columns:
                ax.plot(x, mean2[col], label=f"{label_b} {short}", color=c_b, linewidth=1, linestyle="--")
        ax.set_title("Replicas per Service")
        ax.set_xlabel("Bucket")
        ax.legend(fontsize=6, loc="best", ncol=2)
        ax.grid(True, alpha=0.3)

    # Summary bar chart
    ax = axes[5]
    summary_metrics = ["k6_p50_ms", "k6_p95_ms", "k6_rps"]
    labels = ["P50 (ms)", "P95 (ms)", "RPS"]
    vals_a = [mean1[m].mean() for m in summary_metrics if m in mean1.columns]
    vals_b = [mean2[m].mean() for m in summary_metrics if m in mean2.columns]
    bar_x = np.arange(len(labels))
    ax.bar(bar_x - 0.18, vals_a, 0.35, label=label_a, color="#4F83CC", alpha=0.8)
    ax.bar(bar_x + 0.18, vals_b, 0.35, label=label_b, color="#E57342", alpha=0.8)
    ax.set_xticks(bar_x)
    ax.set_xticklabels(labels)
    ax.set_title("Overall Averages")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3, axis="y")

    plt.suptitle(f"Aggregated Comparison: {label_a} vs {label_b}", fontsize=14, fontweight="bold")
    plt.tight_layout(rect=[0, 0, 1, 0.96])
    plt.savefig(os.path.join(out_dir, "aggregated_comparison.png"), dpi=150, bbox_inches="tight")
    plt.close()

    print(f"[INFO] Saved aggregated comparison plot to {out_dir}/aggregated_comparison.png")


def print_summary_table(mean1, mean2, label_a, label_b):
    """Print a text summary table of key aggregated metrics."""
    metrics = [
        ("k6_p50_ms", "P50 Latency (ms)"),
        ("k6_p90_ms", "P90 Latency (ms)"),
        ("k6_p95_ms", "P95 Latency (ms)"),
        ("k6_p99_ms", "P99 Latency (ms)"),
        ("k6_rps", "Throughput (rps)"),
        ("k6_fail_pct", "Failure Rate (%)"),
        ("k6_reqs", "Requests / bucket"),
    ]
    print(f"\n{'='*80}")
    print(f"AGGREGATED COMPARISON: {label_a} vs {label_b}")
    print(f"{'='*80}")
    print(f"{'Metric':<25} {label_a:<15} {label_b:<15} {'Diff':<12} {'% Change':<10}")
    print("-" * 80)
    for col, name in metrics:
        if col in mean1.columns and col in mean2.columns:
            a = mean1[col].mean()
            b = mean2[col].mean()
            diff = b - a
            pct = (diff / a * 100) if a != 0 else 0
            print(f"{name:<25} {a:<15.2f} {b:<15.2f} {diff:<12.2f} {pct:<10.2f}%")
    print(f"{'='*80}\n")


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate multiple HPA test iterations into averaged results",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--hpa1-dirs", nargs="+", required=True,
                        help="Grafana run directories for HPA1 iterations")
    parser.add_argument("--hpa2-dirs", nargs="+", required=True,
                        help="Grafana run directories for HPA2 iterations")
    parser.add_argument("--out-dir", required=True,
                        help="Output directory for aggregated results")
    parser.add_argument("--label-a", default="HPA1", help="Label for HPA1")
    parser.add_argument("--label-b", default="HPA2", help="Label for HPA2")
    args = parser.parse_args()

    hpa1_dir = os.path.join(args.out_dir, "hpa1")
    hpa2_dir = os.path.join(args.out_dir, "hpa2")
    comp_dir = os.path.join(args.out_dir, "comparison")
    for d in (hpa1_dir, hpa2_dir, comp_dir):
        os.makedirs(d, exist_ok=True)

    _tee = _Tee(sys.stdout, os.path.join(comp_dir, "aggregation.log"))
    sys.stdout = _tee

    print(f"[INFO] Loading HPA1 runs ({len(args.hpa1_dirs)} iterations)...")
    hpa1_frames = load_unified_csvs(args.hpa1_dirs)
    print(f"[INFO] Loading HPA2 runs ({len(args.hpa2_dirs)} iterations)...")
    hpa2_frames = load_unified_csvs(args.hpa2_dirs)

    if len(hpa1_frames) < 1 or len(hpa2_frames) < 1:
        print("[ERROR] Need at least 1 valid run for each HPA group")
        sys.exit(1)

    mean1, std1 = aggregate(hpa1_frames)
    mean2, std2 = aggregate(hpa2_frames)

    mean1.to_csv(os.path.join(hpa1_dir, "averaged_unified_report.csv"), index=False)
    std1.to_csv(os.path.join(hpa1_dir, "stddev_unified_report.csv"), index=False)
    mean2.to_csv(os.path.join(hpa2_dir, "averaged_unified_report.csv"), index=False)
    std2.to_csv(os.path.join(hpa2_dir, "stddev_unified_report.csv"), index=False)
    print(f"[INFO] Saved averaged CSVs")

    plot_averaged(mean1, std1, hpa1_dir, args.label_a)
    plot_averaged(mean2, std2, hpa2_dir, args.label_b)

    plot_comparison(mean1, std1, mean2, std2, comp_dir, args.label_a, args.label_b)

    # Overlay plots (with stddev bands from the aggregation)
    from overlay_plots import generate_overlays
    generate_overlays(mean1, mean2, comp_dir, args.label_a, args.label_b, std1, std2)

    print_summary_table(mean1, mean2, args.label_a, args.label_b)

    print(f"[INFO] Aggregation complete. Results in {args.out_dir}/")
    print(f"  {hpa1_dir}/  - averaged CSV + plots for {args.label_a}")
    print(f"  {hpa2_dir}/  - averaged CSV + plots for {args.label_b}")
    print(f"  {comp_dir}/ - comparison + overlay plots")


if __name__ == "__main__":
    main()
