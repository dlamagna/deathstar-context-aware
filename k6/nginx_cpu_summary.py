#!/usr/bin/env python3
"""
Summarize nginx-thrift CPU usage from a unified_report.csv to help detect bottlenecks.

It looks for either:
  - CPU_Utilization_per_Service__nginx-thrift (percentage)
  - CPU_Consumption_by_Service_Total_mcore__nginx-thrift (mcore)

and prints min/mean/p95/max over the load test window.
"""

import argparse
import sys
from typing import Optional

import numpy as np
import pandas as pd


def summarize(series: pd.Series, label: str, unit: str) -> None:
    if series.empty:
        print(f"[NGINX-CPU] {label}: no data")
        return
    vals = series.dropna().to_numpy()
    if vals.size == 0:
        print(f"[NGINX-CPU] {label}: all values NaN")
        return
    p95 = float(np.percentile(vals, 95))
    print(
        f"[NGINX-CPU] {label}: "
        f"min={vals.min():.2f}{unit}, "
        f"mean={vals.mean():.2f}{unit}, "
        f"p95={p95:.2f}{unit}, "
        f"max={vals.max():.2f}{unit}"
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--unified", required=True, help="Path to unified_report.csv")
    ap.add_argument(
        "--label",
        default="",
        help="Optional label for this run (e.g. test_name_hpa1) for context in logs.",
    )
    args = ap.parse_args()

    try:
        df = pd.read_csv(args.unified)
    except Exception as e:
        print(f"[NGINX-CPU] Failed to read unified report '{args.unified}': {e}", file=sys.stderr)
        sys.exit(1)

    prefix = f"{args.label}: " if args.label else ""

    util_col = "CPU_Utilization_per_Service__nginx-thrift"
    mcore_col = "CPU_Consumption_by_Service_Total_mcore__nginx-thrift"

    if util_col in df.columns:
        summarize(df[util_col], prefix + "nginx-thrift CPU util", "%")
    elif mcore_col in df.columns:
        summarize(df[mcore_col], prefix + "nginx-thrift CPU mcore", "m")
    else:
        print(
            f"[NGINX-CPU] {prefix}No nginx-thrift CPU columns found in unified report "
            f"(looked for '{util_col}' and '{mcore_col}').",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()

