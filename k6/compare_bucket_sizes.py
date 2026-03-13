#!/usr/bin/env python3
"""
compare_bucket_sizes.py

Compares latency headline figures when the same raw k6 data is bucketed at
different time-window widths (default: 10 s vs 15 s).

Usage
-----
  # All comparison pairs found under a grafana date directory:
  python3 k6/compare_bucket_sizes.py --grafana-date 2026-03-11

  # From a specific reset_then_test log file:
  python3 k6/compare_bucket_sizes.py --log logs/reset_then_test_20260311_000000.log

  # Custom bucket sizes:
  python3 k6/compare_bucket_sizes.py --grafana-date 2026-03-11 --buckets 5 10 15
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict

import numpy as np


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def load_raw_k6(path: str):
    """
    Read a raw k6 CSV export and return a list of (timestamp_s, duration_ms)
    for every http_req_duration row that has expected_response=true.
    """
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if r.get("metric_name") != "http_req_duration":
                continue
            if r.get("expected_response", "true").lower() != "true":
                continue
            try:
                ts = int(float(r["timestamp"]))
                dur = float(r["metric_value"])
                rows.append((ts, dur))
            except (ValueError, KeyError):
                continue
    return rows


def bucket_rows(rows, bucket_sec: int):
    """Group (ts, dur) pairs into time buckets of `bucket_sec` seconds."""
    buckets = defaultdict(list)
    for ts, dur in rows:
        b = ts - (ts % bucket_sec)
        buckets[b].append(dur)
    return buckets


def bucket_stats(buckets: dict):
    """
    For each bucket compute p50/p95/p99.
    Return dict of per-bucket percentiles and the mean of those across all buckets.
    """
    p50s, p95s, p99s = [], [], []
    for durs in buckets.values():
        a = np.array(durs)
        p50s.append(np.percentile(a, 50))
        p95s.append(np.percentile(a, 95))
        p99s.append(np.percentile(a, 99))
    return {
        "n_buckets": len(buckets),
        "mean_p50": float(np.mean(p50s)) if p50s else float("nan"),
        "mean_p95": float(np.mean(p95s)) if p95s else float("nan"),
        "mean_p99": float(np.mean(p99s)) if p99s else float("nan"),
        "median_p50": float(np.median(p50s)) if p50s else float("nan"),
        "median_p95": float(np.median(p95s)) if p95s else float("nan"),
        "median_p99": float(np.median(p99s)) if p99s else float("nan"),
    }


def overall_stats(rows):
    """Compute overall (raw, bucket-independent) percentiles."""
    if not rows:
        return {}
    durs = np.array([d for _, d in rows])
    return {
        "n_requests": len(durs),
        "p50": float(np.percentile(durs, 50)),
        "p95": float(np.percentile(durs, 95)),
        "p99": float(np.percentile(durs, 99)),
        "mean": float(np.mean(durs)),
    }


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def find_pairs_from_log(log_path: str, project_root: str):
    """
    Parse a reset_then_test log file.
    Returns list of (label_a, csv_a, label_b, csv_b) tuples.
    """
    pairs = []
    label_a = label_b = csv_a = csv_b = None

    with open(log_path) as f:
        for line in f:
            # Lines like:  [default_hpa] reports/dual_test_35_vus_hpa1_20260311_000553.csv
            m = re.match(r"\s*\[(.+?)\]\s+(reports/\S+\.csv)", line)
            if m:
                label, rel = m.group(1), m.group(2)
                full = os.path.join(project_root, "k6", rel)
                if csv_a is None:
                    label_a, csv_a = label, full
                elif csv_b is None:
                    label_b, csv_b = label, full
                    pairs.append((label_a, csv_a, label_b, csv_b))
                    label_a = label_b = csv_a = csv_b = None
    return pairs


def find_pairs_from_grafana_date(date_str: str, project_root: str):
    """
    Scan k6/grafana/<date>/*_comparison_*/comparison.log for CSV references.
    Returns list of (label_a, csv_a, label_b, csv_b).
    """
    base = os.path.join(project_root, "k6", "grafana", date_str)
    if not os.path.isdir(base):
        sys.exit(f"[ERROR] Directory not found: {base}")

    pairs = []
    seen = set()

    for name in sorted(os.listdir(base)):
        clog = os.path.join(base, name, "comparison.log")
        if not os.path.isfile(clog):
            continue
        sub = find_pairs_from_log(clog, project_root)
        for p in sub:
            key = (p[1], p[3])   # (csv_a, csv_b)
            if key not in seen:
                seen.add(key)
                pairs.append(p)

    return pairs


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

def fmt(v, decimals=1):
    return f"{v:>{8}.{decimals}f}" if not (isinstance(v, float) and np.isnan(v)) else f"{'N/A':>8}"


def print_pair(label_a, rows_a, label_b, rows_b, bucket_sizes):
    overall_a = overall_stats(rows_a)
    overall_b = overall_stats(rows_b)

    print()
    print("=" * 74)
    print(f"  {label_a}  vs  {label_b}")
    print(f"  Requests: {overall_a['n_requests']:,}  vs  {overall_b['n_requests']:,}")
    print("=" * 74)

    # ── Overall (bucket-independent) ────────────────────────────────────────
    print()
    print("  OVERALL (raw, bucket-size independent)")
    print(f"  {'Metric':<18} {'HPA-A':>10} {'HPA-B':>10} {'Diff':>10} {'% Diff':>10}")
    print("  " + "-" * 52)
    for label, ka, kb in [("Mean (ms)", "mean", "mean"),
                           ("P50 (ms)", "p50", "p50"),
                           ("P95 (ms)", "p95", "p95"),
                           ("P99 (ms)", "p99", "p99")]:
        va, vb = overall_a[ka], overall_b[kb]
        diff = vb - va
        pct = 100.0 * diff / va if va else float("nan")
        print(f"  {label:<18} {fmt(va)} {fmt(vb)} {fmt(diff)} {fmt(pct)}%")

    # ── Per bucket size ─────────────────────────────────────────────────────
    for bsec in bucket_sizes:
        bkt_a = bucket_stats(bucket_rows(rows_a, bsec))
        bkt_b = bucket_stats(bucket_rows(rows_b, bsec))

        print()
        print(f"  BUCKET SIZE = {bsec}s  "
              f"(buckets: {bkt_a['n_buckets']} vs {bkt_b['n_buckets']})")
        print(f"  Metric (mean of bucket pctile)  "
              f"{'HPA-A':>10} {'HPA-B':>10} {'Diff':>10} {'% Diff':>10}")
        print("  " + "-" * 60)
        for label, ka, kb in [
            ("Mean-of-P50 (ms)", "mean_p50", "mean_p50"),
            ("Mean-of-P95 (ms)", "mean_p95", "mean_p95"),
            ("Mean-of-P99 (ms)", "mean_p99", "mean_p99"),
            ("Median-of-P50 (ms)", "median_p50", "median_p50"),
            ("Median-of-P95 (ms)", "median_p95", "median_p95"),
            ("Median-of-P99 (ms)", "median_p99", "median_p99"),
        ]:
            va, vb = bkt_a[ka], bkt_b[kb]
            diff = vb - va
            pct = 100.0 * diff / va if va and not np.isnan(va) else float("nan")
            print(f"  {label:<32} {fmt(va)} {fmt(vb)} {fmt(diff)} {fmt(pct)}%")

    # ── Cross-bucket-size comparison for HPA-A ──────────────────────────────
    if len(bucket_sizes) >= 2:
        print()
        print(f"  BUCKET SIZE SENSITIVITY  (same run, different bucket width)")
        for which, rows, label in [("HPA-A", rows_a, label_a), ("HPA-B", rows_b, label_b)]:
            stats = {b: bucket_stats(bucket_rows(rows, b)) for b in bucket_sizes}
            bref = bucket_sizes[0]
            print(f"  {which} ({label})")
            print(f"  {'Metric':<20} " + "".join(f"  {b}s" .rjust(10) for b in bucket_sizes))
            print("  " + "-" * (22 + 12 * len(bucket_sizes)))
            for metric_label, key in [("Mean-of-P50", "mean_p50"),
                                       ("Mean-of-P95", "mean_p95"),
                                       ("Mean-of-P99", "mean_p99")]:
                vals = [stats[b][key] for b in bucket_sizes]
                row = f"  {metric_label:<20} " + "".join(fmt(v).rjust(10) for v in vals)
                # Also show % relative to first bucket size
                deltas = [100.0 * (v - vals[0]) / vals[0] if vals[0] else float("nan")
                          for v in vals]
                delta_str = "  Δ% vs {bref}s: ".format(bref=bref) + \
                            "  ".join(f"{d:+.1f}%" if not np.isnan(d) else "N/A"
                                      for d in deltas)
                print(row + "   |  " + delta_str)
            print()


def print_session_summary(all_results, bucket_sizes):
    """Aggregate across all pairs and print a session-level summary."""
    if not all_results:
        return

    print()
    print("=" * 74)
    print(f"  SESSION SUMMARY ({len(all_results)} comparison pair(s))")
    print("=" * 74)

    for bsec in bucket_sizes:
        gains_p50 = []  # HPA-B p50 - HPA-A p50 (negative = B is faster)
        gains_p95 = []
        gains_p99 = []
        for ra, rb in all_results:
            sa = bucket_stats(bucket_rows(ra, bsec))
            sb = bucket_stats(bucket_rows(rb, bsec))
            if not np.isnan(sa["mean_p50"]) and not np.isnan(sb["mean_p50"]):
                gains_p50.append(sb["mean_p50"] - sa["mean_p50"])
                gains_p95.append(sb["mean_p95"] - sa["mean_p95"])
                gains_p99.append(sb["mean_p99"] - sa["mean_p99"])

        if not gains_p50:
            continue

        print(f"\n  Bucket size = {bsec}s  ({len(gains_p50)} pairs)")
        print(f"  {'Metric':<22} {'Mean Δ(B-A)':>12} {'Median Δ':>12} {'StdDev':>10}")
        print("  " + "-" * 58)
        for label, vals in [("Mean-of-P50 diff", gains_p50),
                             ("Mean-of-P95 diff", gains_p95),
                             ("Mean-of-P99 diff", gains_p99)]:
            a = np.array(vals)
            print(f"  {label:<22} {np.mean(a):>11.1f}ms {np.median(a):>11.1f}ms "
                  f"{np.std(a):>9.1f}ms")

    # Raw overall
    raw_p50_gains, raw_p95_gains, raw_p99_gains = [], [], []
    for ra, rb in all_results:
        oa, ob = overall_stats(ra), overall_stats(rb)
        raw_p50_gains.append(ob["p50"] - oa["p50"])
        raw_p95_gains.append(ob["p95"] - oa["p95"])
        raw_p99_gains.append(ob["p99"] - oa["p99"])

    print(f"\n  Raw overall (bucket-independent, {len(raw_p50_gains)} pairs)")
    print(f"  {'Metric':<22} {'Mean Δ(B-A)':>12} {'Median Δ':>12} {'StdDev':>10}")
    print("  " + "-" * 58)
    for label, vals in [("P50 diff", raw_p50_gains),
                         ("P95 diff", raw_p95_gains),
                         ("P99 diff", raw_p99_gains)]:
        a = np.array(vals)
        print(f"  {label:<22} {np.mean(a):>11.1f}ms {np.median(a):>11.1f}ms "
              f"{np.std(a):>9.1f}ms")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="Compare latency at different bucket sizes")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--grafana-date", metavar="YYYY-MM-DD",
                     help="Process all comparison pairs under k6/grafana/<date>/")
    src.add_argument("--log", metavar="FILE",
                     help="Path to a reset_then_test log file")
    p.add_argument("--buckets", nargs="+", type=int, default=[10, 15],
                   help="Bucket widths in seconds to compare (default: 10 15)")
    p.add_argument("--project-root", default=None,
                   help="Project root directory (default: parent of this script's k6/ dir)")
    return p.parse_args()


def main():
    args = parse_args()

    if args.project_root:
        project_root = args.project_root
    else:
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    bucket_sizes = sorted(set(args.buckets))

    # Discover pairs
    if args.grafana_date:
        pairs = find_pairs_from_grafana_date(args.grafana_date, project_root)
        source_desc = f"grafana date {args.grafana_date}"
    else:
        pairs = find_pairs_from_log(args.log, project_root)
        source_desc = f"log {args.log}"

    if not pairs:
        sys.exit(f"[ERROR] No comparison pairs found in {source_desc}")

    print(f"\nFound {len(pairs)} comparison pair(s) from {source_desc}")
    print(f"Bucket sizes: {bucket_sizes}")

    all_rows = []   # list of (rows_a, rows_b) for session summary

    for i, (label_a, csv_a, label_b, csv_b) in enumerate(pairs, 1):
        print(f"\n[{i}/{len(pairs)}] Loading CSVs...")
        for path in (csv_a, csv_b):
            if not os.path.isfile(path):
                print(f"  [WARN] Missing: {path} — skipping pair")
                break
        else:
            rows_a = load_raw_k6(csv_a)
            rows_b = load_raw_k6(csv_b)
            print(f"  {label_a}: {len(rows_a):,} requests  ({os.path.basename(csv_a)})")
            print(f"  {label_b}: {len(rows_b):,} requests  ({os.path.basename(csv_b)})")
            if not rows_a or not rows_b:
                print(f"  [WARN] Skipping pair — one or both CSVs have 0 valid requests")
                continue
            print_pair(label_a, rows_a, label_b, rows_b, bucket_sizes)
            all_rows.append((rows_a, rows_b))

    if len(all_rows) > 1:
        print_session_summary(all_rows, bucket_sizes)


if __name__ == "__main__":
    main()
