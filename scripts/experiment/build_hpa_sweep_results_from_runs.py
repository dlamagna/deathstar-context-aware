#!/usr/bin/env python3
"""
Rebuild HPA sweep results CSV from existing Grafana run directories.

Use this if a long sweep was interrupted or run in multiple chunks.

It scans k6/grafana/<date>/ for run folders matching:
  <test_name_prefix>_vu{target}_cpu{cpu_mult}_hpa{1,2}_*

and for each (target, cpu_mult, HPA) extracts:
  - weighted_p95_ms        (request-weighted p95 latency)
  - weighted_fail_pct      (request-weighted failure rate %)
  - max_repl_compose
  - max_repl_text
  - max_repl_mention

Then it writes a CSV with one row per HPA per configuration.
"""

import argparse
import os
import re
from typing import Dict, List, Tuple

import pandas as pd


RUN_DIR_RE = re.compile(
    r"^(?P<prefix>.+)_vu(?P<target>\d+)_cpu(?P<cpu_mult>[0-9.]+)_hpa(?P<hpa>[12])_"
)


def extract_metrics(run_dir: str) -> Dict[str, float]:
    """
    Extract key metrics from unified_report.csv in the given grafana run directory.
    """
    csv_path = os.path.join(run_dir, "unified_report.csv")
    if not os.path.isfile(csv_path):
        raise FileNotFoundError(f"unified_report.csv not found in {run_dir}")

    df = pd.read_csv(csv_path)

    required_cols = [
        "k6_reqs",
        "k6_fail_pct",
        "k6_p95_ms",
        "Replicas_per_Service__compose-post",
        "Replicas_per_Service__text-service",
        "Replicas_per_Service__user-mention-service",
    ]
    missing = [c for c in required_cols if c not in df.columns]
    if missing:
        raise ValueError(f"Missing expected columns in {csv_path}: {missing}")

    total_reqs = df["k6_reqs"].sum()
    if total_reqs <= 0:
        raise ValueError(f"No requests in {csv_path}")

    weighted_p95_ms = float((df["k6_p95_ms"] * df["k6_reqs"]).sum() / total_reqs)
    weighted_fail_pct = float((df["k6_fail_pct"] * df["k6_reqs"]).sum() / total_reqs / 100.0) * 100.0

    max_repl_compose = float(df["Replicas_per_Service__compose-post"].max())
    max_repl_text = float(df["Replicas_per_Service__text-service"].max())
    max_repl_mention = float(df["Replicas_per_Service__user-mention-service"].max())

    return {
        "weighted_p95_ms": weighted_p95_ms,
        "weighted_fail_pct": weighted_fail_pct,
        "max_repl_compose": max_repl_compose,
        "max_repl_text": max_repl_text,
        "max_repl_mention": max_repl_mention,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Rebuild HPA sweep results from existing k6/grafana run directories."
    )
    parser.add_argument(
        "--date",
        required=True,
        help="Date folder under k6/grafana/, e.g. '2026-02-26'.",
    )
    parser.add_argument(
        "--test-name-prefix",
        default="grid_search",
        help="Prefix of test names, e.g. 'grid_search' (default: %(default)s).",
    )
    parser.add_argument(
        "--out-csv",
        default=None,
        help=(
            "Output CSV path (default: k6/hpa_sweep_results_from_runs.csv "
            "under the repo root)."
        ),
    )

    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    grafana_root = os.path.join(repo_root, "k6", "grafana", args.date)

    if not os.path.isdir(grafana_root):
        raise SystemExit(f"Grafana date directory not found: {grafana_root}")

    print(f"Scanning {grafana_root} for runs with prefix '{args.test_name_prefix}'...")

    # Map (target, cpu_mult, hpa_label) -> run_dir
    runs: Dict[Tuple[int, float, str], str] = {}

    for entry in os.listdir(grafana_root):
        m = RUN_DIR_RE.match(entry)
        if not m:
            continue
        prefix = m.group("prefix")
        if not prefix.startswith(args.test_name_prefix):
            continue

        target = int(m.group("target"))
        cpu_mult = float(m.group("cpu_mult"))
        hpa_num = m.group("hpa")
        hpa_label = "context-aware" if hpa_num == "1" else "default"

        key = (target, cpu_mult, hpa_label)
        full_dir = os.path.join(grafana_root, entry)
        runs[key] = full_dir

    if not runs:
        print("No matching run directories found.")
        return

    print(f"Found {len(runs)} HPA run directories.")

    results: List[Dict[str, object]] = []

    for (target, cpu_mult, hpa_label), run_dir in sorted(
        runs.items(), key=lambda x: (x[0][0], x[0][1], x[0][2])
    ):
        print(f"Processing target={target}, cpu_mult={cpu_mult}, hpa={hpa_label} -> {run_dir}")
        metrics = extract_metrics(run_dir)

        # Reconstruct base CPU mcore values if you used sweep_hpa_configs.py conventions
        base_compose_cpu_m = 60.0
        base_text_cpu_m = 60.0
        base_mention_cpu_m = 60.0
        base_nginx_cpu_m = 100.0

        results.append(
            {
                "target": target,
                "cpu_mult": cpu_mult,
                "compose_cpu_m": base_compose_cpu_m * cpu_mult,
                "text_cpu_m": base_text_cpu_m * cpu_mult,
                "mention_cpu_m": base_mention_cpu_m * cpu_mult,
                "nginx_cpu_m": base_nginx_cpu_m * cpu_mult,
                "hpa": hpa_label,
                "run_dir": run_dir,
                **metrics,
            }
        )

    out_csv = args.out_csv
    if out_csv is None:
        out_csv = os.path.join(repo_root, "k6", "hpa_sweep_results_from_runs.csv")

    os.makedirs(os.path.dirname(out_csv), exist_ok=True)
    pd.DataFrame(results).to_csv(out_csv, index=False)
    print(f"\n[INFO] Wrote {len(results)} rows to {out_csv}")


if __name__ == "__main__":
    main()

