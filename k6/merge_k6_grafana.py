#!/usr/bin/env python3
"""Merge a k6 raw CSV with a Grafana-scraped CSV into a single time-aligned report.

The k6 CSV (per-request rows) is bucketed into fixed intervals with aggregated
latency percentiles, throughput, and error rates.  The Grafana CSV (fixed-interval
infrastructure metrics) is joined on the nearest timestamp.

Output: a single unified CSV with both load-test and infra columns.
"""

import argparse
import csv
import math
import os
import sys
from collections import defaultdict
from datetime import datetime

import pandas as pd


def parse_args():
    p = argparse.ArgumentParser(description="Merge k6 CSV + Grafana CSV into a unified report")
    p.add_argument("--k6-csv", required=True, help="Path to raw k6 CSV export")
    p.add_argument("--grafana-csv", required=True, help="Path to grafana_master.csv")
    p.add_argument("--bucket-sec", type=int, default=10, help="Bucket size in seconds (default: 10, matching Grafana step)")
    p.add_argument("--out", default=None, help="Output CSV path (default: unified_report.csv next to grafana-csv)")
    return p.parse_args()


def bucket_k6_csv(path: str, bucket_sec: int) -> dict:
    """Read raw k6 CSV and aggregate into time buckets."""
    buckets = defaultdict(lambda: {"durations": [], "reqs": 0, "fails": 0})

    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            metric_name = row.get("metric_name", "")
            try:
                ts = int(float(row["timestamp"]))
            except (KeyError, ValueError):
                continue
            b = ts - (ts % bucket_sec)

            if metric_name == "http_reqs":
                buckets[b]["reqs"] += 1
                status = row.get("status", "")
                expected = row.get("expected_response", "true").lower()
                error = row.get("error", "")
                if (status and status != "200") or expected in ("false", "0") or error:
                    buckets[b]["fails"] += 1

            elif metric_name == "http_req_duration":
                try:
                    buckets[b]["durations"].append(float(row["metric_value"]))
                except (KeyError, ValueError):
                    pass

    return buckets


def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] * (c - k) + sorted_vals[c] * (k - f)


def buckets_to_dataframe(buckets: dict, bucket_sec: int) -> pd.DataFrame:
    rows = []
    for ts in sorted(buckets.keys()):
        d = buckets[ts]
        reqs = d["reqs"]
        durs = sorted(d["durations"]) if d["durations"] else []
        rows.append({
            "ts": ts,
            "k6_reqs": reqs,
            "k6_fail_pct": (d["fails"] / reqs * 100.0) if reqs else 0.0,
            "k6_p50_ms": percentile(durs, 0.5),
            "k6_p90_ms": percentile(durs, 0.9),
            "k6_p95_ms": percentile(durs, 0.95),
            "k6_p99_ms": percentile(durs, 0.99),
            "k6_max_ms": durs[-1] if durs else None,
            "k6_rps": reqs / bucket_sec if reqs else 0.0,
        })
    return pd.DataFrame(rows)


def main():
    args = parse_args()

    if not os.path.isfile(args.k6_csv):
        print(f"[ERROR] k6 CSV not found: {args.k6_csv}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(args.grafana_csv):
        print(f"[ERROR] Grafana CSV not found: {args.grafana_csv}", file=sys.stderr)
        sys.exit(1)

    print(f"[INFO] Bucketing k6 data ({args.bucket_sec}s intervals)...", flush=True)
    buckets = bucket_k6_csv(args.k6_csv, args.bucket_sec)
    k6_df = buckets_to_dataframe(buckets, args.bucket_sec)
    print(f"[INFO] k6: {len(k6_df)} buckets, {k6_df['k6_reqs'].sum():.0f} total requests", flush=True)

    print(f"[INFO] Loading Grafana CSV...", flush=True)
    grafana_df = pd.read_csv(args.grafana_csv)
    print(f"[INFO] Grafana: {len(grafana_df)} rows, {len(grafana_df.columns)} columns", flush=True)

    # merge_asof: for each k6 bucket, find the nearest Grafana row (within tolerance)
    k6_df.sort_values("ts", inplace=True)
    grafana_df.sort_values("ts", inplace=True)

    merged = pd.merge_asof(
        k6_df,
        grafana_df,
        on="ts",
        tolerance=args.bucket_sec,
        direction="nearest",
    )

    # Ensure time_iso is present and at the front
    if "time_iso" in merged.columns:
        merged["time_iso"] = merged["ts"].apply(
            lambda x: datetime.utcfromtimestamp(x).isoformat() + "Z"
        )
        cols = ["time_iso"] + [c for c in merged.columns if c != "time_iso"]
        merged = merged[cols]
    else:
        merged.insert(0, "time_iso", merged["ts"].apply(
            lambda x: datetime.utcfromtimestamp(x).isoformat() + "Z"
        ))

    out_path = args.out
    if not out_path:
        out_path = os.path.join(os.path.dirname(args.grafana_csv), "unified_report.csv")

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    merged.to_csv(out_path, index=False)

    k6_cols = [c for c in merged.columns if c.startswith("k6_")]
    infra_cols = [c for c in merged.columns if not c.startswith("k6_") and c not in ("ts", "time_iso")]

    print(f"\n[SUMMARY] Unified report: {len(merged)} rows", flush=True)
    print(f"[SUMMARY] k6 columns: {len(k6_cols)} ({', '.join(k6_cols)})", flush=True)
    print(f"[SUMMARY] Infra columns: {len(infra_cols)}", flush=True)
    print(f"[SUMMARY] Saved: {out_path}", flush=True)


if __name__ == "__main__":
    main()
