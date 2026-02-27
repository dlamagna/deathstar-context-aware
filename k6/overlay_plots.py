#!/usr/bin/env python3
"""Generate overlaid comparison plots from two unified_report.csv files.

Produces one PNG per metric group, with both HPA runs drawn on the same axes
so they can be visually compared side-by-side.

Usage:
  python3 overlay_plots.py \
    --csv-a run_hpa1/unified_report.csv \
    --csv-b run_hpa2/unified_report.csv \
    --out-dir comparison/ \
    --label-a "Context-Aware HPA" --label-b "Default HPA"

Also works with averaged CSVs from aggregate_runs.py (pass --stddev-a / --stddev-b
to add shaded stddev bands).
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


COLOR_A = "#4F83CC"
COLOR_B = "#E57342"
SERVICE_COLORS_A = ["#4F83CC", "#2196F3", "#1565C0", "#0D47A1"]
SERVICE_COLORS_B = ["#E57342", "#FF7043", "#D84315", "#BF360C"]


def friendly(col):
    parts = col.rsplit("__", 1)
    return parts[-1] if len(parts) > 1 else col


def load(path):
    df = pd.read_csv(path)
    if "bucket" not in df.columns:
        df.insert(0, "bucket", range(len(df)))
    return df


def load_optional(path):
    if path and os.path.isfile(path):
        return pd.read_csv(path)
    return None


def shade(ax, x, mean, std, color):
    if std is not None and mean.name in std.columns:
        lo = mean - std[mean.name]
        hi = mean + std[mean.name]
        ax.fill_between(x, lo, hi, alpha=0.18, color=color)


def find_cols(df, pattern, exclude=None):
    cols = [c for c in df.columns if pattern in c]
    if exclude:
        cols = [c for c in cols if exclude not in c.lower()]
    return cols


def plot_single_metric(ax, x, dfA, dfB, col, label_a, label_b, stdA, stdB):
    ax.plot(x, dfA[col], color=COLOR_A, linewidth=1.5, label=label_a)
    shade(ax, x, dfA[col], stdA, COLOR_A)
    ax.plot(x, dfB[col], color=COLOR_B, linewidth=1.5, label=label_b, linestyle="--")
    shade(ax, x, dfB[col], stdB, COLOR_B)


def save(fig, out_dir, name):
    path = os.path.join(out_dir, name)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path


def generate_overlays(dfA, dfB, out_dir, label_a, label_b, stdA=None, stdB=None):
    os.makedirs(out_dir, exist_ok=True)
    n = min(len(dfA), len(dfB))
    dfA = dfA.iloc[:n].reset_index(drop=True)
    dfB = dfB.iloc[:n].reset_index(drop=True)
    x = np.arange(n)
    saved = []

    # --- 1. Latency overlay (p50, p90, p95) ---
    lat_cols = [c for c in ("k6_p50_ms", "k6_p90_ms", "k6_p95_ms") if c in dfA.columns and c in dfB.columns]
    if lat_cols:
        fig, axes = plt.subplots(len(lat_cols), 1, figsize=(12, 4 * len(lat_cols)), sharex=True)
        if len(lat_cols) == 1:
            axes = [axes]
        for ax, col in zip(axes, lat_cols):
            plot_single_metric(ax, x, dfA, dfB, col, label_a, label_b, stdA, stdB)
            ax.set_ylabel(col.replace("k6_", "").replace("_", " "))
            ax.legend(fontsize=8)
            ax.grid(True, alpha=0.3)
        axes[-1].set_xlabel("Bucket (15s)")
        fig.suptitle(f"Latency Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        plt.tight_layout(rect=[0, 0, 1, 0.96])
        saved.append(save(fig, out_dir, "overlay_latency.png"))

    # --- 2. Throughput overlay (rps) ---
    if "k6_rps" in dfA.columns and "k6_rps" in dfB.columns:
        fig, ax = plt.subplots(figsize=(12, 4))
        plot_single_metric(ax, x, dfA, dfB, "k6_rps", label_a, label_b, stdA, stdB)
        ax.set_ylabel("Requests / sec")
        ax.set_xlabel("Bucket (15s)")
        ax.set_title(f"Throughput Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_throughput.png"))

    # --- 3. Failure rate overlay ---
    if "k6_fail_pct" in dfA.columns and "k6_fail_pct" in dfB.columns:
        fig, ax = plt.subplots(figsize=(12, 4))
        plot_single_metric(ax, x, dfA, dfB, "k6_fail_pct", label_a, label_b, stdA, stdB)
        ax.set_ylabel("Failure %")
        ax.set_xlabel("Bucket (15s)")
        ax.set_title(f"Failure Rate Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_failure_rate.png"))

    # --- 4. Replicas overlay (per service, both HPAs) ---
    rep_cols = find_cols(dfA, "Replicas_per_Service__")
    rep_cols = [c for c in rep_cols if c in dfB.columns]
    if rep_cols:
        fig, ax = plt.subplots(figsize=(12, 5))
        for i, col in enumerate(rep_cols):
            svc = friendly(col)
            ca = SERVICE_COLORS_A[i % len(SERVICE_COLORS_A)]
            cb = SERVICE_COLORS_B[i % len(SERVICE_COLORS_B)]
            ax.plot(x, dfA[col], color=ca, linewidth=1.4, label=f"{label_a} - {svc}")
            ax.plot(x, dfB[col], color=cb, linewidth=1.4, label=f"{label_b} - {svc}", linestyle="--")
        ax.set_ylabel("Replicas")
        ax.set_xlabel("Bucket (15s)")
        ax.yaxis.set_major_locator(plt.MaxNLocator(integer=True))
        ax.set_title(f"Replicas Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=7, loc="best", ncol=2)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_replicas.png"))

    # --- 5. CPU utilization overlay (per service, both HPAs) ---
    cpu_cols = find_cols(dfA, "CPU_Utilization_per_Service__", exclude="threshold")
    cpu_cols = [c for c in cpu_cols if c in dfB.columns]
    if cpu_cols:
        fig, ax = plt.subplots(figsize=(12, 5))
        for i, col in enumerate(cpu_cols):
            svc = friendly(col)
            ca = SERVICE_COLORS_A[i % len(SERVICE_COLORS_A)]
            cb = SERVICE_COLORS_B[i % len(SERVICE_COLORS_B)]
            ax.plot(x, dfA[col], color=ca, linewidth=1.4, label=f"{label_a} - {svc}")
            ax.plot(x, dfB[col], color=cb, linewidth=1.4, label=f"{label_b} - {svc}", linestyle="--")
        ax.set_ylabel("CPU Utilization %")
        ax.set_xlabel("Bucket (15s)")
        ax.set_title(f"CPU Utilization Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=7, loc="best", ncol=2)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_cpu_utilization.png"))

    # --- 6. CPU consumption (mcore) overlay ---
    mcore_cols = find_cols(dfA, "CPU_Consumption_by_Service_Total_mcore__")
    mcore_cols = [c for c in mcore_cols if c in dfB.columns]
    if mcore_cols:
        fig, ax = plt.subplots(figsize=(12, 5))
        for i, col in enumerate(mcore_cols):
            svc = friendly(col)
            ca = SERVICE_COLORS_A[i % len(SERVICE_COLORS_A)]
            cb = SERVICE_COLORS_B[i % len(SERVICE_COLORS_B)]
            ax.plot(x, dfA[col], color=ca, linewidth=1.4, label=f"{label_a} - {svc}")
            ax.plot(x, dfB[col], color=cb, linewidth=1.4, label=f"{label_b} - {svc}", linestyle="--")
        ax.set_ylabel("CPU (mcore)")
        ax.set_xlabel("Bucket (15s)")
        ax.set_title(f"CPU Consumption Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=7, loc="best", ncol=2)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_cpu_mcore.png"))

    # --- 7. Memory overlay ---
    mem_cols = find_cols(dfA, "Memory_Usage_per_Service_MB__")
    mem_cols = [c for c in mem_cols if c in dfB.columns]
    if mem_cols:
        fig, ax = plt.subplots(figsize=(12, 5))
        for i, col in enumerate(mem_cols):
            svc = friendly(col)
            ca = SERVICE_COLORS_A[i % len(SERVICE_COLORS_A)]
            cb = SERVICE_COLORS_B[i % len(SERVICE_COLORS_B)]
            ax.plot(x, dfA[col], color=ca, linewidth=1.4, label=f"{label_a} - {svc}")
            ax.plot(x, dfB[col], color=cb, linewidth=1.4, label=f"{label_b} - {svc}", linestyle="--")
        ax.set_ylabel("Memory (MB)")
        ax.set_xlabel("Bucket (15s)")
        ax.set_title(f"Memory Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=7, loc="best", ncol=2)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_memory.png"))

    # --- 8. Network I/O overlay ---
    net_cols = find_cols(dfA, "Network_IO_Rate_per_Service_KBs__")
    net_cols = [c for c in net_cols if c in dfB.columns]
    if net_cols:
        fig, ax = plt.subplots(figsize=(12, 5))
        for i, col in enumerate(net_cols):
            svc = friendly(col)
            ca = SERVICE_COLORS_A[i % len(SERVICE_COLORS_A)]
            cb = SERVICE_COLORS_B[i % len(SERVICE_COLORS_B)]
            ax.plot(x, dfA[col], color=ca, linewidth=1.4, label=f"{label_a} - {svc}")
            ax.plot(x, dfB[col], color=cb, linewidth=1.4, label=f"{label_b} - {svc}", linestyle="--")
        ax.set_ylabel("Network I/O (KB/s)")
        ax.set_xlabel("Bucket (15s)")
        ax.set_title(f"Network I/O Overlay: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
        ax.legend(fontsize=7, loc="best", ncol=2)
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        saved.append(save(fig, out_dir, "overlay_network_io.png"))

    print(f"[INFO] Generated {len(saved)} overlay plots in {out_dir}/")
    for p in saved:
        print(f"  {os.path.basename(p)}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate overlaid comparison plots from two unified_report.csv files",
        epilog="""Examples:
  %(prog)s --csv-a hpa1/unified_report.csv --csv-b hpa2/unified_report.csv --out-dir comparison/
  %(prog)s --csv-a hpa1/averaged.csv --csv-b hpa2/averaged.csv \\
           --stddev-a hpa1/stddev.csv --stddev-b hpa2/stddev.csv --out-dir comparison/
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--csv-a", required=True, help="Unified CSV for HPA A")
    parser.add_argument("--csv-b", required=True, help="Unified CSV for HPA B")
    parser.add_argument("--stddev-a", default=None, help="Optional stddev CSV for HPA A (adds shading)")
    parser.add_argument("--stddev-b", default=None, help="Optional stddev CSV for HPA B (adds shading)")
    parser.add_argument("--out-dir", required=True, help="Output directory for overlay plots")
    parser.add_argument("--label-a", default="HPA1", help="Label for CSV A")
    parser.add_argument("--label-b", default="HPA2", help="Label for CSV B")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    _tee = _Tee(sys.stdout, os.path.join(args.out_dir, "overlay.log"))
    sys.stdout = _tee

    for path in (args.csv_a, args.csv_b):
        if not os.path.isfile(path):
            print(f"[ERROR] File not found: {path}")
            sys.exit(1)

    dfA = load(args.csv_a)
    dfB = load(args.csv_b)
    stdA = load_optional(args.stddev_a)
    stdB = load_optional(args.stddev_b)

    generate_overlays(dfA, dfB, args.out_dir, args.label_a, args.label_b, stdA, stdB)


if __name__ == "__main__":
    main()
