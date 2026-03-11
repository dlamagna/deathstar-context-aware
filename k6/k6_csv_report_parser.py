#!/usr/bin/env python3
"""Parse a single k6 raw CSV and generate per-run plots + printed metrics summary.

Plots saved:
  k6_avg_latency.png, k6_tail_latency.png, k6_throughput.png,
  k6_success_rate.png, k6_latency_distribution.png
"""

import argparse
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def parse_args():
    p = argparse.ArgumentParser(description="Parse a k6 CSV and generate per-run plots")
    p.add_argument("--k6-csv", required=True, help="Path to raw k6 CSV export")
    p.add_argument("--out-dir", required=True, help="Directory to save plots into")
    p.add_argument("--label", default="Test", help="Label used in plot titles and legends")
    p.add_argument("--bin-width", type=int, default=3, help="Bin width in seconds for time-series plots")
    return p.parse_args()


def extract_metric(data: pd.DataFrame, metric_name: str, sample_size: int = 10000):
    rows = data[data.iloc[:, 0] == metric_name]
    if rows.empty:
        return [], []
    if len(rows) > sample_size:
        step = len(rows) // sample_size
        rows = rows.iloc[::step].head(sample_size)
    timestamps = rows.iloc[:, 1].astype(float).tolist()
    values = rows.iloc[:, 2].astype(float).tolist()
    if not timestamps:
        return [], []
    t0 = timestamps[0]
    return [t - t0 for t in timestamps], values


def bucket(timestamps, values, bin_width):
    buckets = defaultdict(list)
    for ts, val in zip(timestamps, values):
        buckets[int(ts // bin_width)].append(val)
    time_bins = [b * bin_width for b in sorted(buckets.keys())]
    return buckets, time_bins


def print_metrics(timestamps, latencies, http_reqs, http_failed, label):
    if not latencies:
        return
    arr = np.array(latencies)
    print(f"\n=== {label} Performance Metrics ===")
    print(f"  Avg latency:  {np.mean(arr):.2f} ms")
    print(f"  P50:          {np.percentile(arr, 50):.2f} ms")
    print(f"  P95:          {np.percentile(arr, 95):.2f} ms")
    print(f"  P99:          {np.percentile(arr, 99):.2f} ms")
    print(f"  Min:          {np.min(arr):.2f} ms")
    print(f"  Max:          {np.max(arr):.2f} ms")
    if http_reqs:
        total = np.sum(http_reqs)
        failed = np.sum(http_failed) if http_failed else 0
        duration = max(timestamps) - min(timestamps) if timestamps else 0
        print(f"  Total reqs:   {total:.0f}")
        print(f"  Failed:       {failed:.0f} ({failed/total*100:.1f}%)" if total else "")
        print(f"  RPS:          {total/duration:.1f}" if duration > 0 else "")


def main():
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    bw = args.bin_width

    data = pd.read_csv(args.k6_csv, low_memory=False)

    ts_lat, latencies = extract_metric(data, "http_req_duration")
    ts_reqs, http_reqs = extract_metric(data, "http_reqs")
    _, http_failed = extract_metric(data, "http_req_failed")

    print_metrics(ts_lat, latencies, http_reqs, http_failed, args.label)

    if not latencies:
        print("[WARN] No latency data found, skipping plots")
        return

    # Avg latency over time
    b_lat, bins_lat = bucket(ts_lat, latencies, bw)
    avgs = [np.mean(b_lat[k]) for k in sorted(b_lat.keys())]
    plt.figure(figsize=(12, 5))
    plt.plot(bins_lat, avgs, linewidth=2, label=args.label)
    plt.xlabel("Time (s)"); plt.ylabel("Avg Latency (ms)")
    plt.title(f"Average Latency Over Time ({args.label})")
    plt.legend(); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "k6_avg_latency.png"), dpi=200)
    plt.close()

    # P95 tail latency over time
    p95s = [np.percentile(b_lat[k], 95) for k in sorted(b_lat.keys()) if b_lat[k]]
    plt.figure(figsize=(12, 5))
    plt.plot(bins_lat[:len(p95s)], p95s, linewidth=2, linestyle="--", label=f"{args.label} P95")
    plt.xlabel("Time (s)"); plt.ylabel("P95 Latency (ms)")
    plt.title(f"Tail Latency (P95) Over Time ({args.label})")
    plt.legend(); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "k6_tail_latency.png"), dpi=200)
    plt.close()

    # Throughput over time
    if http_reqs:
        b_rps, bins_rps = bucket(ts_reqs, http_reqs, bw)
        rps = [sum(b_rps[k]) / bw for k in sorted(b_rps.keys())]
        plt.figure(figsize=(12, 5))
        plt.plot(bins_rps, rps, linewidth=2, color="green", label=args.label)
        plt.xlabel("Time (s)"); plt.ylabel("Requests/s")
        plt.title(f"Throughput Over Time ({args.label})")
        plt.legend(); plt.grid(True, alpha=0.3); plt.tight_layout()
        plt.savefig(os.path.join(args.out_dir, "k6_throughput.png"), dpi=200)
        plt.close()

    # Success rate over time
    if http_reqs and http_failed:
        sr_buckets = defaultdict(lambda: {"total": 0, "failed": 0})
        for t, r, f in zip(ts_reqs, http_reqs, http_failed):
            idx = int(t // bw)
            sr_buckets[idx]["total"] += r
            sr_buckets[idx]["failed"] += f
        sr_bins = [b * bw for b in sorted(sr_buckets.keys())]
        sr_vals = [
            ((sr_buckets[k]["total"] - sr_buckets[k]["failed"]) / sr_buckets[k]["total"] * 100)
            if sr_buckets[k]["total"] > 0 else 0
            for k in sorted(sr_buckets.keys())
        ]
        plt.figure(figsize=(12, 5))
        plt.plot(sr_bins, sr_vals, linewidth=2, color="blue", label=args.label)
        plt.xlabel("Time (s)"); plt.ylabel("Success Rate (%)")
        plt.title(f"Success Rate Over Time ({args.label})")
        plt.ylim(0, 100); plt.legend(); plt.grid(True, alpha=0.3); plt.tight_layout()
        plt.savefig(os.path.join(args.out_dir, "k6_success_rate.png"), dpi=200)
        plt.close()

    # Latency distribution histogram (density so per-run plots are comparable)
    plt.figure(figsize=(12, 5))
    plt.hist(latencies, bins=50, alpha=0.7, edgecolor="black", density=True)
    plt.xlabel("Latency (ms)"); plt.ylabel("Density (normalised)")
    plt.title(f"Latency Distribution ({args.label}, n={len(latencies):,})")
    plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "k6_latency_distribution.png"), dpi=200)
    plt.close()

    print(f"\n[SUMMARY] k6 plots saved to: {args.out_dir}")


if __name__ == "__main__":
    main()
