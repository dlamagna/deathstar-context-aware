#!/usr/bin/env python3

import argparse
import csv
import datetime as dt
import json
import math
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Join k6 CSV with Prometheus CPU and replicas into an enhanced time series report")
    parser.add_argument("--k6-csv", required=True, help="Path to k6 CSV export (e.g., k6/reports/context_hpa_vu_50_10m.csv)")
    parser.add_argument("--prom", required=True, help="Prometheus base URL, e.g., http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
    parser.add_argument("--namespace", default="socialnetwork", help="Kubernetes namespace for targets")
    parser.add_argument("--services", nargs="+", default=["compose-post-service", "text-service", "user-mention-service"], help="Service/deployment names")
    parser.add_argument("--bucket-sec", type=int, default=10, help="Bucket size in seconds for aggregation")
    parser.add_argument("--out", required=True, help="Output CSV path (e.g., k6/reports/enhanced/enhanced.csv)")
    return parser.parse_args()


def read_k6_csv(path: str, bucket_sec: int):
    # Aggregate by bucket: count, failures, durations for percentiles
    per_bucket = defaultdict(lambda: {"durations": [], "reqs": 0, "fails": 0})

    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            metric_name = row.get("metric_name", "")
            # we consider only http_req_duration rows for latency; http_reqs for count
            try:
                ts = int(float(row["timestamp"]))
            except Exception:
                continue
            bucket = ts - (ts % bucket_sec)

            if metric_name == "http_reqs":
                per_bucket[bucket]["reqs"] += 1
                # failure can be inferred from status != 200 or expected_response == false or error present
                status = row.get("status", "")
                expected = row.get("expected_response", "true").lower()
                error = row.get("error", "")
                is_fail = False
                if status and status != "200":
                    is_fail = True
                elif expected in ("false", "0"): 
                    is_fail = True
                elif error:
                    is_fail = True
                if is_fail:
                    per_bucket[bucket]["fails"] += 1
            elif metric_name == "http_req_duration":
                try:
                    # k6 exports duration in ms by default
                    dur_ms = float(row["metric_value"])  # milliseconds
                    per_bucket[bucket]["durations"].append(dur_ms)
                except Exception:
                    pass

    if not per_bucket:
        raise SystemExit("No data parsed from k6 CSV; ensure the file is correct.")

    start = min(per_bucket.keys())
    end = max(per_bucket.keys())
    return per_bucket, start, end


def prom_query_range(prom_url: str, query: str, start: int, end: int, step: int = 10):
    params = {
        "query": query,
        "start": str(start),
        "end": str(end),
        "step": str(step),
    }
    url = f"{prom_url.rstrip('/')}/api/v1/query_range?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {payload}")
    return payload["data"]["result"]


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    k = (len(sorted_values) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_values[int(k)]
    d0 = sorted_values[f] * (c - k)
    d1 = sorted_values[c] * (k - f)
    return d0 + d1


def main():
    args = parse_args()

    per_bucket, start, end = read_k6_csv(args.k6_csv, args.bucket_sec)

    # Build PromQL for CPU (mcores) and replicas per service
    # CPU mcores: 1000 * sum(rate(container_cpu_usage_seconds_total{namespace="ns", pod=~"svc-.*"}[1m]))
    # Replicas: kube_deployment_status_replicas{namespace="ns", deployment="svc"}
    cpu_queries = {}
    replica_queries = {}
    for svc in args.services:
        pod_re = f"{svc}-.*"
        cpu_q = (
            "1000 * sum(rate(container_cpu_usage_seconds_total{"
            f"namespace=\"{args.namespace}\",pod=~\"{pod_re}\",container!\"\""  # exclude empty container name
            "}[1m]))"
        )
        rep_q = (
            f"kube_deployment_status_replicas{{namespace=\"{args.namespace}\",deployment=\"{svc}\"}}"
        )
        cpu_queries[svc] = cpu_q
        replica_queries[svc] = rep_q

    # Query Prometheus
    step = max(args.bucket_sec, 5)
    cpu_series = {}
    rep_series = {}
    for svc in args.services:
        try:
            cpu_res = prom_query_range(args.prom, cpu_queries[svc], start, end, step)
        except Exception as e:
            cpu_res = []
        try:
            rep_res = prom_query_range(args.prom, replica_queries[svc], start, end, step)
        except Exception as e:
            rep_res = []
        # Reduce to single time series by summing values at each ts if multiple vectors returned
        def reduce_series(results):
            agg = {}
            for r in results:
                for ts_str, val_str in r.get("values", []):
                    ts = int(float(ts_str))
                    try:
                        v = float(val_str)
                    except Exception:
                        continue
                    agg[ts] = agg.get(ts, 0.0) + v
            return agg
        cpu_series[svc] = reduce_series(cpu_res)
        rep_series[svc] = reduce_series(rep_res)

    # Prepare output
    fieldnames = [
        "time_iso",
        "time_unix",
        "bucket_sec",
        "reqs",
        "fail_pct",
        "p50_ms",
        "p90_ms",
        "p95_ms",
        "max_ms",
    ]
    for svc in args.services:
        fieldnames.append(f"{svc}_replicas")
        fieldnames.append(f"{svc}_cpu_mcores")

    # Ensure output directory exists
    out_dir = args.out.rsplit("/", 1)[0]
    if out_dir:
        import os
        os.makedirs(out_dir, exist_ok=True)

    with open(args.out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for bucket in sorted(per_bucket.keys()):
            data = per_bucket[bucket]
            reqs = data["reqs"]
            fails = data["fails"]
            durations = sorted(data["durations"]) if data["durations"] else []
            row = {
                "time_iso": dt.datetime.utcfromtimestamp(bucket).isoformat() + "Z",
                "time_unix": bucket,
                "bucket_sec": args.bucket_sec,
                "reqs": reqs,
                "fail_pct": (fails / reqs * 100.0) if reqs else 0.0,
                "p50_ms": percentile(durations, 0.5) if durations else None,
                "p90_ms": percentile(durations, 0.9) if durations else None,
                "p95_ms": percentile(durations, 0.95) if durations else None,
                "max_ms": durations[-1] if durations else None,
            }
            # attach infra metrics (nearest timestamp from prom step)
            for svc in args.services:
                # choose the closest timestamp <= bucket, else exact match
                # Prom series are at fixed step; we try exact match first
                rep = rep_series.get(svc, {})
                cpu = cpu_series.get(svc, {})
                rep_val = rep.get(bucket)
                cpu_val = cpu.get(bucket)
                if rep_val is None:
                    # try previous step alignment
                    rep_val = rep.get(bucket - (bucket % step))
                if cpu_val is None:
                    cpu_val = cpu.get(bucket - (bucket % step))
                row[f"{svc}_replicas"] = rep_val
                row[f"{svc}_cpu_mcores"] = cpu_val
            writer.writerow(row)

    print(f"Enhanced report written: {args.out}")


if __name__ == "__main__":
    main()


