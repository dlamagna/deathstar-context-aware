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
import json
import os
import re
import sys
from datetime import datetime

import glob
import yaml

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# Default base directory for auto-discovery (searched recursively across all date subfolders).
# Override with --grafana-dir if you want to limit to a specific date.
GRAFANA_DIR = os.path.join(os.path.dirname(__file__), "grafana")


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


def load_unified_csvs(dirs, max_fail_pct=95.0):
    """Load unified_report.csv from each directory.

    Returns (frames, loaded_dirs) — both lists are parallel and only include
    runs that passed the health check (mean failure rate < max_fail_pct).
    Skips any run whose mean k6_fail_pct >= max_fail_pct (default 95%), which
    indicates the run was entirely failed / the testbed was not healthy.
    """
    frames = []
    loaded_dirs = []
    for d in dirs:
        csv_path = os.path.join(d, "unified_report.csv")
        if not os.path.isfile(csv_path):
            print(f"[WARN] Missing {csv_path}, skipping")
            continue
        df = pd.read_csv(csv_path)
        if "k6_fail_pct" in df.columns:
            mean_fail = pd.to_numeric(df["k6_fail_pct"], errors="coerce").mean()
            if mean_fail >= max_fail_pct:
                print(f"[SKIP] {csv_path}: mean failure rate {mean_fail:.1f}% >= {max_fail_pct}%, excluding from aggregation")
                continue
        frames.append(df)
        loaded_dirs.append(d)
        print(f"[INFO] Loaded {csv_path}: {len(df)} rows, {len(df.columns)} cols")
    return frames, loaded_dirs


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
        ax.set_xlabel("Bucket (10s intervals)")
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
        if col == "k6_fail_pct":
            max_fail = max(mean1[col].max(), mean2[col].max())
            ax.set_ylim(0, max_fail * 1.1 if max_fail > 0 else 1.0)

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


def find_k6_csv(run_dir):
    """Return the k6 raw CSV path stored in config/run_details.txt, or None."""
    details = os.path.join(run_dir, "config", "run_details.txt")
    if not os.path.isfile(details):
        return None
    with open(details) as f:
        for line in f:
            if line.startswith("K6 CSV Output:"):
                path = line.split(":", 1)[1].strip()
                # Path may be relative to the project root (one level up from k6/)
                if not os.path.isabs(path):
                    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    path = os.path.join(project_root, path)
                return path if os.path.isfile(path) else None
    return None


def load_raw_latencies(run_dirs):
    """Pool raw http_req_duration values from k6 CSVs across all run dirs."""
    all_latencies = []
    for d in run_dirs:
        csv_path = find_k6_csv(d)
        if csv_path is None:
            print(f"[WARN] No k6 CSV found for {d}, skipping for latency distribution")
            continue
        try:
            df = pd.read_csv(csv_path, low_memory=False)
            rows = df[df.iloc[:, 0] == "http_req_duration"]
            vals = pd.to_numeric(rows.iloc[:, 2], errors="coerce").dropna().tolist()
            all_latencies.extend(vals)
            print(f"[INFO] Loaded {len(vals):,} latency samples from {csv_path}")
        except Exception as e:
            print(f"[WARN] Failed to load latencies from {csv_path}: {e}")
    return all_latencies


def plot_latency_distribution(latencies_a, latencies_b, out_dir, label_a, label_b):
    """Normalised latency distribution histogram for two pooled sets of raw latencies."""
    if not latencies_a or not latencies_b:
        print("[WARN] Insufficient raw latency data for distribution plot, skipping")
        return

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.hist(latencies_a, bins=60, alpha=0.6, density=True,
            label=f"{label_a} (n={len(latencies_a):,})", color="#4F83CC", edgecolor="black", linewidth=0.3)
    ax.hist(latencies_b, bins=60, alpha=0.6, density=True,
            label=f"{label_b} (n={len(latencies_b):,})", color="#E57342", edgecolor="black", linewidth=0.3)
    ax.set_xlabel("Latency (ms)")
    ax.set_ylabel("Density (normalised)")
    ax.set_title(f"Aggregated Latency Distribution: {label_a} vs {label_b} (normalised, all iterations pooled)")
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    out_path = os.path.join(out_dir, "comparison_latency_distribution.png")
    plt.savefig(out_path, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"[INFO] Saved aggregated latency distribution to {out_path}")


def plot_per_run_p95(frames, mean_df, out_dir, label):
    """Line plot showing P95 latency per run over time, with mean overlaid.

    Each individual run is a faint line; the aggregated mean is a bold line.
    Saves per_run_p95.png to out_dir.
    """
    col = "k6_p95_ms"
    if not frames or col not in frames[0].columns:
        print(f"[WARN] {col} not found, skipping per-run P95 plot for {label}")
        return

    os.makedirs(out_dir, exist_ok=True)
    fig, ax = plt.subplots(figsize=(14, 5))

    min_rows = min(len(f) for f in frames)
    x = np.arange(min_rows)

    for i, df in enumerate(frames):
        vals = pd.to_numeric(df[col], errors="coerce").iloc[:min_rows].values
        ax.plot(x, vals, color="#4F83CC", alpha=0.25, linewidth=0.8,
                label="_nolegend_" if i > 0 else f"Individual runs (n={len(frames)})")

    if col in mean_df.columns:
        mean_vals = mean_df[col].values[:min_rows]
        ax.plot(x, mean_vals, color="#1A237E", linewidth=2.2, label="Mean across runs", zorder=5)

    ax.set_xlabel("Bucket (10s intervals)")
    ax.set_ylabel("P95 Latency (ms)")
    ax.set_title(f"{label} — P95 Latency per Run over Time")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    out_path = os.path.join(out_dir, "per_run_p95.png")
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"[INFO] Saved per-run P95 plot to {out_path}")


def plot_per_run_p95_comparison(hpa1_frames, hpa2_frames, mean1, mean2,
                                 out_dir, label_a, label_b):
    """Side-by-side per-run P95 comparison: both HPA groups in one figure."""
    col = "k6_p95_ms"
    if not hpa1_frames or not hpa2_frames:
        return
    if col not in hpa1_frames[0].columns or col not in hpa2_frames[0].columns:
        print(f"[WARN] {col} not found, skipping per-run P95 comparison plot")
        return

    os.makedirs(out_dir, exist_ok=True)
    fig, axes = plt.subplots(1, 2, figsize=(20, 6), sharey=True)

    for ax, frames, mean_df, label, run_color, mean_color in [
        (axes[0], hpa1_frames, mean1, label_a, "#4F83CC", "#1A237E"),
        (axes[1], hpa2_frames, mean2, label_b, "#E57342", "#7B1A00"),
    ]:
        min_rows = min(len(f) for f in frames)
        x = np.arange(min_rows)
        for i, df in enumerate(frames):
            vals = pd.to_numeric(df[col], errors="coerce").iloc[:min_rows].values
            ax.plot(x, vals, color=run_color, alpha=0.2, linewidth=0.8,
                    label="_nolegend_" if i > 0 else f"Individual runs (n={len(frames)})")
        if col in mean_df.columns:
            mean_vals = mean_df[col].values[:min_rows]
            ax.plot(x, mean_vals, color=mean_color, linewidth=2.2, label="Mean", zorder=5)
        ax.set_xlabel("Bucket (10s intervals)")
        ax.set_ylabel("P95 Latency (ms)")
        ax.set_title(f"{label} — P95 per Run")
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)

    plt.suptitle(f"Per-Run P95 Latency: {label_a} vs {label_b}", fontsize=13, fontweight="bold")
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    out_path = os.path.join(out_dir, "per_run_p95_comparison.png")
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"[INFO] Saved per-run P95 comparison plot to {out_path}")


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


def parse_run_config(run_dir):
    """Extract k6 params, HPA thresholds, and service CPU requests from a run directory.

    Reads config/run_details.txt (k6 params + inline HPA YAML) and
    config/service_values.yaml (CPU requests per Deployment).
    Returns a dict with keys: k6, hpa, services, and optional test_name/date/hpa_label.
    """
    config = {"run_dir": os.path.abspath(run_dir), "k6": {}, "hpa": {}, "services": {}}

    details_path = os.path.join(run_dir, "config", "run_details.txt")
    if os.path.isfile(details_path):
        with open(details_path) as f:
            content = f.read()

        for line in content.splitlines():
            if ":" not in line:
                continue
            key, _, val = line.strip().partition(":")
            key = key.strip()
            val = val.strip()
            if key == "K6_LOAD_MODE":
                config["k6"]["load_mode"] = val
            elif key.startswith("K6_RPS"):
                m = re.search(r"\d+", val)
                if m:
                    config["k6"]["rps"] = int(m.group())
            elif key == "EXPERIMENT_DURATION":
                config["k6"]["duration"] = val
            elif key.startswith("K6_TARGET"):
                m = re.search(r"\d+", val)
                if m:
                    config["k6"]["vus"] = int(m.group())
            elif key == "K6_TIMEOUT":
                config["k6"]["timeout"] = val
            elif key == "Test Name":
                config["test_name"] = val
            elif key == "Date":
                config["date"] = val
            elif key == "HPA Label":
                config["hpa_label"] = val
            elif key == "HPA File":
                config["hpa_file"] = val

        # Extract inline HPA YAML block (between "HPA YAML (inline):" and next "===")
        m = re.search(r"HPA YAML \(inline\):\n(.*?)(?=\n===|\Z)", content, re.DOTALL)
        if m:
            hpa_yaml_str = m.group(1).rstrip()
            try:
                for doc in yaml.safe_load_all(hpa_yaml_str):
                    if not doc or doc.get("kind") != "HorizontalPodAutoscaler":
                        continue
                    svc_name = doc["metadata"]["name"]
                    if svc_name.endswith("-hpa"):
                        svc_name = svc_name[:-4]
                    spec = doc.get("spec", {})
                    entry = {
                        "min_replicas": spec.get("minReplicas"),
                        "max_replicas": spec.get("maxReplicas"),
                    }
                    for metric in spec.get("metrics", []):
                        if metric["type"] == "Resource" and metric.get("resource", {}).get("name") == "cpu":
                            entry["cpu_threshold"] = metric["resource"]["target"].get("averageUtilization")
                        elif metric["type"] == "External":
                            ext = metric.get("external", {})
                            tgt = ext.get("target", {})
                            entry["parent_metric"] = ext.get("metric", {}).get("name")
                            entry["parent_target_type"] = tgt.get("type")
                            entry["parent_target_value"] = tgt.get("averageValue") or tgt.get("value")
                    config["hpa"][svc_name] = entry
            except Exception as e:
                config["hpa"]["_parse_error"] = str(e)

    svc_yaml_path = os.path.join(run_dir, "config", "service_values.yaml")
    if os.path.isfile(svc_yaml_path):
        try:
            with open(svc_yaml_path) as f:
                svc_content = f.read()
            for doc in yaml.safe_load_all(svc_content):
                if not doc or doc.get("kind") != "Deployment":
                    continue
                name = doc["metadata"]["name"]
                try:
                    containers = doc["spec"]["template"]["spec"]["containers"]
                    for c in containers:
                        if c.get("name") == name:
                            req = c.get("resources", {}).get("requests", {})
                            config["services"][name] = {
                                "cpu_request": req.get("cpu"),
                                "memory_request": req.get("memory"),
                            }
                except (KeyError, TypeError):
                    pass
        except Exception:
            pass

    return config


def compute_run_metrics(df):
    """Compute high-level summary metrics from a unified_report DataFrame."""
    col_map = {
        "p50_ms": "k6_p50_ms",
        "p90_ms": "k6_p90_ms",
        "p95_ms": "k6_p95_ms",
        "p99_ms": "k6_p99_ms",
        "fail_pct": "k6_fail_pct",
        "rps": "k6_rps",
    }
    return {
        key: round(float(pd.to_numeric(df[col], errors="coerce").dropna().mean()), 3)
        for key, col in col_map.items()
        if col in df.columns
    }


def build_comparison_json(hpa1_dirs, hpa2_dirs, hpa1_frames, hpa2_frames,
                          mean1, mean2, label_a, label_b, out_dir):
    """Write comparison/runs_summary.json with per-run configs and high-level metrics.

    Returns the summary dict (also useful for aggregate_across_runs.py).
    """
    agg_col_map = {
        "p50_ms": "k6_p50_ms",
        "p90_ms": "k6_p90_ms",
        "p95_ms": "k6_p95_ms",
        "p99_ms": "k6_p99_ms",
        "fail_pct": "k6_fail_pct",
        "rps": "k6_rps",
    }

    def _agg_metrics(mean_df):
        return {
            key: round(float(mean_df[col].mean()), 3)
            for key, col in agg_col_map.items()
            if col in mean_df.columns
        }

    def _build_group(dirs, frames, mean_df, label):
        runs = []
        for d, df in zip(dirs, frames):
            run = parse_run_config(d)
            run["metrics"] = compute_run_metrics(df)
            runs.append(run)
        return {
            "label": label,
            "n_runs": len(runs),
            "runs": runs,
            "aggregate": _agg_metrics(mean_df),
        }

    hpa1_data = _build_group(hpa1_dirs, hpa1_frames, mean1, label_a)
    hpa2_data = _build_group(hpa2_dirs, hpa2_frames, mean2, label_b)

    agg1, agg2 = hpa1_data["aggregate"], hpa2_data["aggregate"]
    comparison = {}
    for key in ["p50_ms", "p95_ms", "p99_ms", "fail_pct", "rps"]:
        if key in agg1 and key in agg2:
            diff = round(agg2[key] - agg1[key], 3)
            diff_pct = round(diff / agg1[key] * 100, 2) if agg1[key] != 0 else 0.0
            comparison[key] = {
                "hpa1": agg1[key], "hpa2": agg2[key],
                "diff": diff, "diff_pct": diff_pct,
            }

    summary = {
        "created_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "out_dir": os.path.abspath(out_dir),
        "labels": {"hpa1": label_a, "hpa2": label_b},
        "hpa1": hpa1_data,
        "hpa2": hpa2_data,
        "comparison": comparison,
    }

    out_path = os.path.join(out_dir, "comparison", "runs_summary.json")
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"[INFO] Saved runs summary JSON to {out_path}")
    return summary


def _discover_run_dirs(grafana_dir, last_n=None):
    """Auto-discover completed hpa1/hpa2 run dirs under grafana_dir.

    Searches both directly under grafana_dir and one level deeper (date subfolders),
    so it works whether you point it at a specific date (k6/grafana/2026-03-12) or
    the base directory (k6/grafana) covering all dates / overnight runs.

    A run dir is considered complete if it contains a unified_report.csv.
    Dirs are sorted chronologically by their embedded timestamp suffix (*_HHMMSSZ),
    with the date folder providing the primary sort key across overnight runs.
    last_n caps to the N most recent completed pairs.
    """
    def _find(pattern):
        return sorted(
            d for d in glob.glob(pattern, recursive=True)
            if os.path.isfile(os.path.join(d, "unified_report.csv"))
        )

    # Search both direct children and one level deeper (date subfolders)
    hpa1 = _find(os.path.join(grafana_dir, "*_hpa1_*")) + \
           _find(os.path.join(grafana_dir, "*", "*_hpa1_*"))
    hpa2 = _find(os.path.join(grafana_dir, "*_hpa2_*")) + \
           _find(os.path.join(grafana_dir, "*", "*_hpa2_*"))

    # Deduplicate and sort by full path (date folder + timestamp gives correct order)
    hpa1 = sorted(set(hpa1))
    hpa2 = sorted(set(hpa2))

    if last_n is not None:
        hpa1 = hpa1[-last_n:]
        hpa2 = hpa2[-last_n:]
    return hpa1, hpa2


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate multiple HPA test iterations into averaged results",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # Manual mode
    parser.add_argument("--hpa1-dirs", nargs="+", default=None,
                        help="Grafana run directories for HPA1 iterations")
    parser.add_argument("--hpa2-dirs", nargs="+", default=None,
                        help="Grafana run directories for HPA2 iterations")
    # Auto-discovery mode
    parser.add_argument("--grafana-dir", default=None,
                        help=f"Auto-discover completed hpa1/hpa2 run dirs under this directory. "
                             f"Searches across date subfolders, so you can point it at the base "
                             f"k6/grafana/ dir to cover overnight runs. "
                             f"Defaults to GRAFANA_DIR={GRAFANA_DIR}. "
                             f"Use --last-n to limit to a subset.")
    parser.add_argument("--last-n", type=int, default=None,
                        help="With --grafana-dir: only use the N most recent completed pairs")
    parser.add_argument("--out-dir", required=True,
                        help="Output directory for aggregated results")
    parser.add_argument("--label-a", default="HPA1", help="Label for HPA1")
    parser.add_argument("--label-b", default="HPA2", help="Label for HPA2")
    args = parser.parse_args()

    # Resolve dirs — manual takes priority, otherwise auto-discovery
    if args.hpa1_dirs and args.hpa2_dirs:
        hpa1_dirs = args.hpa1_dirs
        hpa2_dirs = args.hpa2_dirs
    else:
        search_dir = args.grafana_dir or GRAFANA_DIR
        hpa1_dirs, hpa2_dirs = _discover_run_dirs(search_dir, args.last_n)
        if not hpa1_dirs or not hpa2_dirs:
            print(f"[ERROR] No completed run dirs found under {search_dir}")
            sys.exit(1)
        print(f"[INFO] Auto-discovered {len(hpa1_dirs)} HPA1 and {len(hpa2_dirs)} HPA2 runs from {search_dir}")
        for d in hpa1_dirs: print(f"  HPA1: {d}")
        for d in hpa2_dirs: print(f"  HPA2: {d}")

    hpa1_dir = os.path.join(args.out_dir, "hpa1")
    hpa2_dir = os.path.join(args.out_dir, "hpa2")
    comp_dir = os.path.join(args.out_dir, "comparison")
    for d in (hpa1_dir, hpa2_dir, comp_dir):
        os.makedirs(d, exist_ok=True)

    _tee = _Tee(sys.stdout, os.path.join(comp_dir, "aggregation.log"))
    sys.stdout = _tee

    print(f"[INFO] Loading HPA1 runs ({len(hpa1_dirs)} iterations)...")
    hpa1_frames, hpa1_loaded = load_unified_csvs(hpa1_dirs)
    print(f"[INFO] Loading HPA2 runs ({len(hpa2_dirs)} iterations)...")
    hpa2_frames, hpa2_loaded = load_unified_csvs(hpa2_dirs)

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

    plot_per_run_p95(hpa1_frames, mean1, hpa1_dir, args.label_a)
    plot_per_run_p95(hpa2_frames, mean2, hpa2_dir, args.label_b)
    plot_per_run_p95_comparison(hpa1_frames, hpa2_frames, mean1, mean2,
                                comp_dir, args.label_a, args.label_b)

    # Overlay plots (with stddev bands from the aggregation)
    from overlay_plots import generate_overlays
    generate_overlays(mean1, mean2, comp_dir, args.label_a, args.label_b, std1, std2)

    # Latency distribution: pool raw per-request latencies across all iterations
    print(f"[INFO] Loading raw k6 latencies for distribution plot...")
    lat_a = load_raw_latencies(hpa1_dirs)
    lat_b = load_raw_latencies(hpa2_dirs)
    plot_latency_distribution(lat_a, lat_b, comp_dir, args.label_a, args.label_b)

    print_summary_table(mean1, mean2, args.label_a, args.label_b)

    build_comparison_json(hpa1_loaded, hpa2_loaded, hpa1_frames, hpa2_frames,
                          mean1, mean2, args.label_a, args.label_b, args.out_dir)

    print(f"[INFO] Aggregation complete. Results in {args.out_dir}/")
    print(f"  {hpa1_dir}/  - averaged CSV + plots for {args.label_a}")
    print(f"  {hpa2_dir}/  - averaged CSV + plots for {args.label_b}")
    print(f"  {comp_dir}/ - comparison + overlay plots")


if __name__ == "__main__":
    main()
