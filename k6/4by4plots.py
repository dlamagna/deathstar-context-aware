#!/usr/bin/env python3
"""Generate a 4-panel overview plot from a unified_report.csv (k6 + Grafana merged).

Panels:
  1. HTTP Success Rate (%)
  2. HTTP Error Rate (%)
  3. Replicas per Service
  4. CPU Consumption per Service (mcore)

Saved as: overview_4panel.png
"""

import argparse
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


COLORS = ["#4F83CC", "#E57342", "#FFB300", "#7CB342", "#8E24AA"]


def parse_args():
    p = argparse.ArgumentParser(description="Generate 4-panel overview from unified report")
    p.add_argument("--unified-csv", required=True, help="Path to unified_report.csv")
    p.add_argument("--out-dir", required=True, help="Directory to save the plot")
    p.add_argument("--label", default="", help="Optional title suffix")
    return p.parse_args()


def friendly_name(col: str) -> str:
    """Extract a short service name from a Grafana column name."""
    parts = col.rsplit("__", 1)
    return parts[-1] if len(parts) > 1 else col


def main():
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    df = pd.read_csv(args.unified_csv)

    # Build relative time axis (seconds from start)
    if "ts" in df.columns:
        t0 = df["ts"].min()
        df["t"] = df["ts"] - t0
    else:
        df["t"] = range(len(df))

    # Identify columns by pattern
    replica_cols = [c for c in df.columns if "Replicas_per_Service__" in c]
    cpu_cols = [c for c in df.columns if "CPU_Consumption_by_Service_Total_mcore__" in c]

    # Compute success/error from k6 columns
    has_k6 = "k6_fail_pct" in df.columns
    if has_k6:
        df["success_pct"] = 100.0 - df["k6_fail_pct"].fillna(0.0)
    else:
        df["success_pct"] = 100.0
        df["k6_fail_pct"] = 0.0

    plt.rcParams["font.size"] = 11

    fig, axs = plt.subplots(4, 1, figsize=(7, 10))
    title_suffix = f" ({args.label})" if args.label else ""

    # Panel 1: HTTP Success Rate
    axs[0].plot(df["t"], df["success_pct"], color=COLORS[0], linewidth=1.6)
    axs[0].set_ylabel("HTTP Success (%)")
    axs[0].set_ylim(max(0, df["success_pct"].min() - 5), 105)
    axs[0].grid(True, linestyle="--", linewidth=0.5, color="gray")
    axs[0].spines["top"].set_visible(False)
    axs[0].spines["right"].set_visible(False)

    # Panel 2: HTTP Error Rate
    axs[1].plot(df["t"], df["k6_fail_pct"], color="#E57342", linewidth=1.6)
    axs[1].set_ylabel("HTTP Error (%)")
    axs[1].grid(True, linestyle="--", linewidth=0.5, color="gray")
    axs[1].spines["top"].set_visible(False)
    axs[1].spines["right"].set_visible(False)

    # Panel 3: Replicas per Service
    for i, col in enumerate(replica_cols):
        axs[2].plot(df["t"], df[col], label=friendly_name(col), color=COLORS[i % len(COLORS)], linewidth=1.6)
    axs[2].set_ylabel("Replicas")
    axs[2].yaxis.set_major_locator(plt.MaxNLocator(integer=True))
    axs[2].grid(True, linestyle="--", linewidth=0.5, color="gray")
    axs[2].spines["top"].set_visible(False)
    axs[2].spines["right"].set_visible(False)

    # Panel 4: CPU Consumption (mcore)
    for i, col in enumerate(cpu_cols):
        axs[3].plot(df["t"], df[col], label=friendly_name(col), color=COLORS[i % len(COLORS)], linewidth=1.6)
    axs[3].set_ylabel("CPU (mcore)")
    axs[3].set_xlabel("Time (s)")
    axs[3].grid(True, linestyle="--", linewidth=0.5, color="gray")
    axs[3].spines["top"].set_visible(False)
    axs[3].spines["right"].set_visible(False)

    # Shared legend from the replicas/CPU panels
    handles, labels = [], []
    for ax in (axs[2], axs[3]):
        h, l = ax.get_legend_handles_labels()
        for hi, li in zip(h, l):
            if li not in labels:
                handles.append(hi)
                labels.append(li)
    if handles:
        fig.legend(handles, labels, loc="upper center", ncol=min(4, len(labels)),
                   fontsize=9, frameon=True, edgecolor="gray")

    fig.suptitle(f"Run Overview{title_suffix}", fontsize=12, y=0.99)
    plt.subplots_adjust(top=0.93, hspace=0.35)
    fig.patch.set_facecolor("white")

    out_path = os.path.join(args.out_dir, "overview_4panel.png")
    plt.savefig(out_path, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"[SUMMARY] 4-panel overview saved: {out_path}")


if __name__ == "__main__":
    main()
