#!/usr/bin/env python3
"""Pool run directories from multiple runs_summary.json files and re-aggregate.

Each runs_summary.json is produced by aggregate_runs.py in its comparison/
directory. This script reads the run_dirs listed inside, pools them across
all input JSONs, and runs a full re-aggregation — producing the same output
structure as aggregate_runs.py (averaged CSVs, plots, overlay plots, latency
distribution, and a new runs_summary.json).

Usage:
  python3 k6/aggregate_across_runs.py \\
    --jsons k6/grafana/2026-03-14/aggregated_compose_post_40/comparison/runs_summary.json \\
            k6/grafana/2026-03-16/aggregated_094450Z/comparison/runs_summary.json \\
    --out-dir k6/grafana/combined_YYYYMMDD_XYZ

Flags:
  --label-a / --label-b   Override the HPA labels (default: taken from the first JSON).
  --skip-latency-dist     Skip pooling raw k6 CSVs (faster when raw files are unavailable).
"""

import argparse
import json
import os
import sys

# Import shared functions from aggregate_runs (same directory)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aggregate_runs as agg


def load_summary(path):
    if not os.path.isfile(path):
        print(f"[ERROR] JSON not found: {path}")
        sys.exit(1)
    with open(path) as f:
        return json.load(f)


def validate_k6_configs(all_runs, label):
    """Warn if k6 settings differ across pooled runs — same workload is required."""
    configs = [r.get("k6", {}) for r in all_runs]
    for key in ("rps", "duration", "timeout", "load_mode"):
        vals = {c.get(key) for c in configs if c.get(key) is not None}
        if len(vals) > 1:
            print(f"[WARN] {label}: k6.{key} differs across pooled runs: {vals}")


def main():
    parser = argparse.ArgumentParser(
        description="Combine run pools from multiple aggregate_runs.py JSON summaries",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--jsons", nargs="+", required=True,
        help="Paths to runs_summary.json files produced by aggregate_runs.py",
    )
    parser.add_argument(
        "--out-dir", required=True,
        help="Output directory for the combined aggregation",
    )
    parser.add_argument("--label-a", default=None, help="Override label for HPA1")
    parser.add_argument("--label-b", default=None, help="Override label for HPA2")
    parser.add_argument(
        "--skip-latency-dist", action="store_true",
        help="Skip pooling raw k6 CSVs for the latency distribution plot",
    )
    args = parser.parse_args()

    summaries = []
    for p in args.jsons:
        s = load_summary(p)
        n1 = s["hpa1"]["n_runs"]
        n2 = s["hpa2"]["n_runs"]
        print(f"[INFO] Loaded {p}  ({n1} HPA1 runs, {n2} HPA2 runs)")
        summaries.append(s)

    # Pool run dirs from all JSONs
    hpa1_dirs = [r["run_dir"] for s in summaries for r in s["hpa1"]["runs"]]
    hpa2_dirs = [r["run_dir"] for s in summaries for r in s["hpa2"]["runs"]]

    # Validate that all pooled runs used the same k6 workload
    all_hpa1_runs = [r for s in summaries for r in s["hpa1"]["runs"]]
    all_hpa2_runs = [r for s in summaries for r in s["hpa2"]["runs"]]
    validate_k6_configs(all_hpa1_runs, "HPA1")
    validate_k6_configs(all_hpa2_runs, "HPA2")

    print(f"[INFO] Pooled {len(hpa1_dirs)} HPA1 dirs, {len(hpa2_dirs)} HPA2 dirs")

    # Labels: CLI overrides first JSON
    label_a = args.label_a or summaries[0]["labels"]["hpa1"]
    label_b = args.label_b or summaries[0]["labels"]["hpa2"]

    # Set up output directories
    hpa1_out = os.path.join(args.out_dir, "hpa1")
    hpa2_out = os.path.join(args.out_dir, "hpa2")
    comp_out = os.path.join(args.out_dir, "comparison")
    for d in (hpa1_out, hpa2_out, comp_out):
        os.makedirs(d, exist_ok=True)

    tee = agg._Tee(sys.stdout, os.path.join(comp_out, "aggregation.log"))
    sys.stdout = tee

    print(f"[INFO] Loading HPA1 runs ({len(hpa1_dirs)} dirs)...")
    hpa1_frames, hpa1_loaded = agg.load_unified_csvs(hpa1_dirs)
    print(f"[INFO] Loading HPA2 runs ({len(hpa2_dirs)} dirs)...")
    hpa2_frames, hpa2_loaded = agg.load_unified_csvs(hpa2_dirs)

    if not hpa1_frames or not hpa2_frames:
        print("[ERROR] Need at least 1 valid run per group")
        sys.exit(1)

    mean1, std1 = agg.aggregate(hpa1_frames)
    mean2, std2 = agg.aggregate(hpa2_frames)

    mean1.to_csv(os.path.join(hpa1_out, "averaged_unified_report.csv"), index=False)
    std1.to_csv(os.path.join(hpa1_out, "stddev_unified_report.csv"), index=False)
    mean2.to_csv(os.path.join(hpa2_out, "averaged_unified_report.csv"), index=False)
    std2.to_csv(os.path.join(hpa2_out, "stddev_unified_report.csv"), index=False)
    print("[INFO] Saved averaged CSVs")

    agg.plot_averaged(mean1, std1, hpa1_out, label_a)
    agg.plot_averaged(mean2, std2, hpa2_out, label_b)
    agg.plot_comparison(mean1, std1, mean2, std2, comp_out, label_a, label_b)

    agg.plot_per_run_p95(hpa1_frames, mean1, hpa1_out, label_a)
    agg.plot_per_run_p95(hpa2_frames, mean2, hpa2_out, label_b)
    agg.plot_per_run_p95_comparison(hpa1_frames, hpa2_frames, mean1, mean2,
                                    comp_out, label_a, label_b)

    from overlay_plots import generate_overlays
    generate_overlays(mean1, mean2, comp_out, label_a, label_b, std1, std2)

    if not args.skip_latency_dist:
        print("[INFO] Loading raw k6 latencies for distribution plot...")
        lat_a = agg.load_raw_latencies(hpa1_loaded)
        lat_b = agg.load_raw_latencies(hpa2_loaded)
        agg.plot_latency_distribution(lat_a, lat_b, comp_out, label_a, label_b)
    else:
        print("[INFO] Skipping latency distribution plot (--skip-latency-dist)")

    agg.print_summary_table(mean1, mean2, label_a, label_b)

    agg.build_comparison_json(
        hpa1_loaded, hpa2_loaded, hpa1_frames, hpa2_frames,
        mean1, mean2, label_a, label_b, args.out_dir,
    )

    print(f"[INFO] Combined aggregation complete. Results in {args.out_dir}/")


if __name__ == "__main__":
    main()
