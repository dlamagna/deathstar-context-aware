#!/usr/bin/env python3
"""
Sweep k6/HPA configurations and print key metrics for both HPAs.

This script:
  - Varies k6 load parameters (VUs, duration).
  - Optionally varies CPU sizes for the main service chain
    (compose-post-service, text-service, user-mention-service, nginx-thrift)
    via scalar multipliers applied to deathstar-bench/hpa/service_values.yaml.
  - For each configuration, runs hpa_comparison_test.sh for:
      * context-aware HPA (HPA1)
      * default HPA (HPA2)
  - Reads the resulting unified_report.csv for each HPA run and:
      * prints a summary table
      * writes a CSV with all configurations and metrics:
          - weighted p95 latency (ms)
          - weighted failure rate (%)
          - max replicas per service (compose-post, text-service, user-mention-service)
          - k6 + CPU configuration metadata
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import pandas as pd


RE_HPA_DIR_HPA1 = re.compile(r"^HPA_RUN_DIR_HPA1=(.+)$")
RE_HPA_DIR_HPA2 = re.compile(r"^HPA_RUN_DIR_HPA2=(.+)$")
RE_HPA_LOG_FILE = re.compile(r"^Log file:\s+(.+)$")


def run_hpa_comparison(
    hpa1: str,
    hpa2: str,
    test_name: str,
    k6_target: int,
    k6_duration: str,
    k6_timeout: str,
    cpu_mult: float,
    hard_reset: bool = False,
    sweep_log_path: Optional[str] = None,
) -> Tuple[str, str]:
    """
    Run ./hpa_comparison_test.sh with the given k6 settings and return
    the grafana run directories for HPA1 and HPA2 as printed by the script.
    """
    env = os.environ.copy()
    env["K6_TARGET"] = str(k6_target)
    env["K6_DURATION"] = k6_duration
    env["K6_TIMEOUT"] = k6_timeout
    # Drive CPU scaling through the SERVICE_CPU_MULT env used by hpa_comparison_test.sh
    env["SERVICE_CPU_MULT"] = str(cpu_mult)

    cmd: List[str] = ["./hpa_comparison_test.sh"]
    if hard_reset:
        cmd.append("--hard-reset-testbed")
    cmd.extend([hpa1, hpa2, test_name])

    print(f"\n=== Running config: target={k6_target}, duration={k6_duration}, timeout={k6_timeout} ===")
    print("Command:", " ".join(cmd))

    # Repo root (same as cwd for the subprocess)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    # Append a short entry to the sweep-level log, if configured.
    if sweep_log_path is not None:
        try:
            with open(sweep_log_path, "a", encoding="utf-8") as f:
                f.write(
                    f"\n=== Sweep config: test_name={test_name}, "
                    f"target={k6_target}, duration={k6_duration}, timeout={k6_timeout} ===\n"
                )
                f.write("Command: " + " ".join(cmd) + "\n")
        except OSError as e:
            print(f"[WARN] Failed to append to sweep log {sweep_log_path}: {e}", file=sys.stderr)

    proc = subprocess.run(
        cmd,
        env=env,
        cwd=repo_root,  # repo root
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )

    output = proc.stdout
    sys.stdout.write(output)

    if proc.returncode != 0:
        raise RuntimeError(f"hpa_comparison_test.sh failed with exit code {proc.returncode}")

    hpa1_dir = ""
    hpa2_dir = ""
    hpa_log_file = ""
    for line in output.splitlines():
        stripped = line.strip()

        m1 = RE_HPA_DIR_HPA1.match(stripped)
        if m1:
            hpa1_dir = m1.group(1)

        m2 = RE_HPA_DIR_HPA2.match(stripped)
        if m2:
            hpa2_dir = m2.group(1)

        m_log = RE_HPA_LOG_FILE.match(stripped)
        if m_log:
            hpa_log_file = m_log.group(1)

    if not hpa1_dir or not hpa2_dir:
        raise RuntimeError("Failed to parse HPA run directories from hpa_comparison_test.sh output")

    # Record where the detailed HPA comparison log lives, both to stdout and (optionally) the sweep log.
    if hpa_log_file:
        msg = f"[INFO] HPA comparison log for test '{test_name}': {hpa_log_file}"
    else:
        msg = f"[WARN] Could not determine HPA comparison log file for test '{test_name}' from script output"
    print(msg)

    if sweep_log_path is not None:
        try:
            with open(sweep_log_path, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        except OSError as e:
            print(f"[WARN] Failed to append HPA log path to sweep log {sweep_log_path}: {e}", file=sys.stderr)

    return hpa1_dir, hpa2_dir


def extract_metrics(run_dir: str) -> Dict[str, float]:
    """
    Extract key metrics from unified_report.csv in the given grafana run directory.

    Metrics:
      - weighted_p95_ms: request-weighted average of k6_p95_ms across buckets
      - weighted_fail_pct: request-weighted average of k6_fail_pct
      - max_replicas_compose
      - max_replicas_text
      - max_replicas_mention
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
    parser = argparse.ArgumentParser(description="Sweep k6/HPA configs and print key metrics.")
    parser.add_argument(
        "--hpa1",
        default="deathstar-bench/hpa/context_aware_hpa_dual_metric.yaml",
        help="Path to HPA1 (context-aware) YAML (default: %(default)s)",
    )
    parser.add_argument(
        "--hpa2",
        default="deathstar-bench/hpa/default_hpa.yaml",
        help="Path to HPA2 (default) YAML (default: %(default)s)",
    )
    parser.add_argument(
        "--test-name-prefix",
        default="grid_search",
        help="Prefix for TEST_NAME passed to hpa_comparison_test.sh (default: %(default)s)",
    )
    parser.add_argument(
        "--targets",
        default="40,50,60,80,100",
        help="Comma-separated list of K6_TARGET (VUs) values to test (default: %(default)s)",
    )
    parser.add_argument(
        "--duration",
        default="7m",
        help="K6_DURATION to use for all runs, e.g. '7m' (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout",
        default="5s",
        help="K6_TIMEOUT per request, e.g. '5s' (default: %(default)s)",
    )
    parser.add_argument(
        "--cpu-mults",
        default="1.0",
        help=(
            "Comma-separated list of CPU multipliers to apply to the service chain "
            "(compose-post-service, text-service, user-mention-service, nginx-thrift). "
            "1.0 means 'as in service_values.yaml'. Example: '0.5,1.0,1.5'. "
            "For each multiplier we scale the base CPU mcore values."
        ),
    )
    parser.add_argument(
        "--out-csv",
        default=None,
        help=(
            "Optional path to write a CSV with all sweep results "
            "(default: k6/hpa_sweep_results.csv in repo root)."
        ),
    )
    parser.add_argument(
        "--hard-reset-testbed",
        action="store_true",
        help="Use --hard-reset-testbed before each config run (slower but fully isolated).",
    )

    args = parser.parse_args()

    try:
        targets = [int(x) for x in args.targets.split(",") if x.strip()]
    except ValueError:
        print(f"Invalid --targets '{args.targets}', must be comma-separated integers", file=sys.stderr)
        sys.exit(1)

    try:
        cpu_mults = [float(x) for x in args.cpu_mults.split(",") if x.strip()]
    except ValueError:
        print(f"Invalid --cpu-mults '{args.cpu_mults}', must be comma-separated floats", file=sys.stderr)
        sys.exit(1)

    print("Will sweep configurations over:")
    print(f"  HPA1:          {args.hpa1}")
    print(f"  HPA2:          {args.hpa2}")
    print(f"  K6_TARGETs:    {targets}")
    print(f"  CPU mults:     {cpu_mults}")
    print(f"  K6_DURATION:   {args.duration}")
    print(f"  K6_TIMEOUT:    {args.timeout}")
    print(f"  Hard reset:    {args.hard_reset_testbed}")

    # Base CPU values (mcore) as defined in deathstar-bench/hpa/service_values.yaml
    base_compose_cpu_m = 60
    base_text_cpu_m = 60
    base_mention_cpu_m = 60
    base_nginx_cpu_m = 100

    # Path to service_values.yaml (what hpa_comparison_test.sh applies)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    svc_values_path = os.path.join(repo_root, "deathstar-bench", "hpa", "service_values.yaml")

    # Sweep-level log file capturing Python-side sweep orchestration.
    logs_dir = os.path.join(repo_root, "logs")
    os.makedirs(logs_dir, exist_ok=True)
    sweep_ts = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    sweep_log_path: Optional[str] = os.path.join(logs_dir, f"hpa_sweep_{sweep_ts}.log")
    try:
        with open(sweep_log_path, "w", encoding="utf-8") as f:
            f.write("=== HPA sweep started ===\n")
            f.write(f"Timestamp (UTC): {sweep_ts}\n")
            f.write(f"HPA1: {args.hpa1}\n")
            f.write(f"HPA2: {args.hpa2}\n")
            f.write(f"K6_TARGETs: {targets}\n")
            f.write(f"CPU mults: {cpu_mults}\n")
            f.write(f"K6_DURATION: {args.duration}\n")
            f.write(f"K6_TIMEOUT: {args.timeout}\n")
            f.write(f"Hard reset: {args.hard_reset_testbed}\n")
    except OSError as e:
        print(f"[WARN] Failed to create sweep log at {sweep_log_path}: {e}", file=sys.stderr)
        sweep_log_path = None

    if sweep_log_path is not None:
        print(f"[INFO] Sweep log will be written to: {sweep_log_path}")

    # Ensure the testbed starts from a clean, known-good state before the sweep.
    print("\n[INFO] Performing initial testbed reset before HPA sweep...")
    initial_reset_cmd = [
        "./reset_testbed.sh",
        "--cluster-type",
        "kind",
        "--no-dns-resolution",
        "--persist-monitoring-data",
    ]
    try:
        subprocess.run(
            initial_reset_cmd,
            cwd=repo_root,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Initial reset_testbed.sh failed with exit code {e.returncode}", file=sys.stderr)
        sys.exit(1)

    results: List[Dict[str, object]] = []

    for cpu_mult in cpu_mults:
        for target in targets:
            test_name = f"{args.test_name_prefix}_vu{target}_cpu{cpu_mult:g}"

            hpa1_dir, hpa2_dir = run_hpa_comparison(
                hpa1=args.hpa1,
                hpa2=args.hpa2,
                test_name=test_name,
                k6_target=target,
                k6_duration=args.duration,
                k6_timeout=args.timeout,
                cpu_mult=cpu_mult,
                hard_reset=args.hard_reset_testbed,
                sweep_log_path=sweep_log_path,
            )

            print(f"\n[INFO] HPA1 grafana dir: {hpa1_dir}")
            print(f"[INFO] HPA2 grafana dir: {hpa2_dir}")

            m1 = extract_metrics(hpa1_dir)
            m2 = extract_metrics(hpa2_dir)

            results.append(
                {
                    "target": target,
                    "cpu_mult": cpu_mult,
                    "compose_cpu_m": base_compose_cpu_m * cpu_mult,
                    "text_cpu_m": base_text_cpu_m * cpu_mult,
                    "mention_cpu_m": base_mention_cpu_m * cpu_mult,
                    "nginx_cpu_m": base_nginx_cpu_m * cpu_mult,
                    "hpa": "context-aware",
                    "hpa_yaml": args.hpa1,
                    "test_name": test_name,
                    "run_dir": hpa1_dir,
                    "k6_duration": args.duration,
                    "k6_timeout": args.timeout,
                    **m1,
                }
            )
            results.append(
                {
                    "target": target,
                    "cpu_mult": cpu_mult,
                    "compose_cpu_m": base_compose_cpu_m * cpu_mult,
                    "text_cpu_m": base_text_cpu_m * cpu_mult,
                    "mention_cpu_m": base_mention_cpu_m * cpu_mult,
                    "nginx_cpu_m": base_nginx_cpu_m * cpu_mult,
                    "hpa": "default",
                    "hpa_yaml": args.hpa2,
                    "test_name": test_name,
                    "run_dir": hpa2_dir,
                    "k6_duration": args.duration,
                    "k6_timeout": args.timeout,
                    **m2,
                }
            )

            # Reset the testbed before the next configuration (if any).
            is_last_cpu = cpu_mult == cpu_mults[-1]
            is_last_target = target == targets[-1]
            if not (is_last_cpu and is_last_target):
                print("\n[INFO] Resetting testbed before next sweep configuration...")
                reset_cmd = [
                    "./reset_testbed.sh",
                    "--cluster-type",
                    "kind",
                    "--no-dns-resolution",
                    "--persist-monitoring-data",
                ]
                try:
                    subprocess.run(
                        reset_cmd,
                        cwd=repo_root,
                        check=True,
                    )
                except subprocess.CalledProcessError as e:
                    print(
                        f"[ERROR] reset_testbed.sh failed with exit code {e.returncode}",
                        file=sys.stderr,
                    )
                    sys.exit(1)

    # Optionally write CSV with full results
    out_csv = args.out_csv
    if out_csv is None:
        # Default location under repo root
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        out_csv = os.path.join(repo_root, "k6", "hpa_sweep_results.csv")

    try:
        df_results = pd.DataFrame(results)
        os.makedirs(os.path.dirname(out_csv), exist_ok=True)
        df_results.to_csv(out_csv, index=False)
        print(f"\n[INFO] Sweep results written to CSV: {out_csv}")
    except Exception as e:
        print(f"\n[WARN] Failed to write CSV to {out_csv}: {e}", file=sys.stderr)

    # Print summary table
    print("\n=== Sweep Summary ===")
    header = (
        f"{'K6_TARGET':>8}  {'cpu_mult':>8}  {'HPA':>13}  "
        f"{'p95_ms':>10}  {'fail_%':>8}  "
        f"{'maxR_comp':>9}  {'maxR_text':>9}  {'maxR_mention':>11}"
    )
    print(header)
    print("-" * len(header))
    for row in sorted(results, key=lambda r: (r["target"], r["cpu_mult"], r["hpa"])):  # type: ignore[index]
        print(
            f"{row['target']:>8}  {row['cpu_mult']:8.2f}  {row['hpa']:>13}  "
            f"{row['weighted_p95_ms']:10.1f}  {row['weighted_fail_pct']:8.2f}  "
            f"{row['max_repl_compose']:9.1f}  {row['max_repl_text']:9.1f}  {row['max_repl_mention']:11.1f}"
        )


if __name__ == "__main__":
    main()

