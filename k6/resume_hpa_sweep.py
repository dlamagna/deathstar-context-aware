#!/usr/bin/env python3
"""
Resume/continue an HPA sweep across multiple days and build one combined CSV.

Key features:
  - Scans existing run folders under k6/grafana/YYYY-MM-DD/ to detect which
    configurations have already completed (both HPA1 and HPA2 unified_report.csv).
  - Runs only missing configurations (cross product of VU targets and CPU multipliers).
  - Writes a single combined CSV (old + new) at the end, built from run folders
    (not from in-memory state), so it works even if the process is interrupted.

Run folder naming convention (as produced by sweep_hpa_configs.py / hpa_comparison_test.sh):
  {test_name_prefix}_vu{target}_cpu{cpu_mult}_hpa{1|2}_{HHMMSSZ}

Notes:
  - We treat a config (target, cpu_mult) as complete only if BOTH hpa1 and hpa2
    runs exist and contain a readable unified_report.csv.
  - We choose the newest run per (target, cpu_mult, hpa) if multiple exist.
  - CPU scaling is applied by temporarily rewriting deathstar-bench/hpa/service_values.yaml
    for the duration of each config.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, TextIO, Tuple

import pandas as pd


RE_HPA_DIR_HPA1 = re.compile(r"^HPA_RUN_DIR_HPA1=(.+)$")
RE_HPA_DIR_HPA2 = re.compile(r"^HPA_RUN_DIR_HPA2=(.+)$")

# Example: grid_search_vu60_cpu0.8_hpa1_182645Z
RUN_DIR_RE = re.compile(
    r"^(?P<prefix>.+)_vu(?P<target>\d+)_cpu(?P<cpu_mult>[0-9.]+)_hpa(?P<hpa>[12])_(?P<hhmmss>\d{6}Z)$"
)


@dataclass(frozen=True)
class SweepConfig:
    target: int
    cpu_mult: float


@dataclass(frozen=True)
class RunRef:
    date: str  # YYYY-MM-DD
    run_dir: str  # full path
    target: int
    cpu_mult: float
    hpa_num: int  # 1 or 2
    hhmmss: str  # HHMMSSZ

    @property
    def key(self) -> Tuple[int, float, int]:
        return (self.target, self.cpu_mult, self.hpa_num)

    @property
    def run_dt(self) -> Optional[datetime]:
        # best-effort parse; return None if unexpected
        try:
            # drop trailing Z for parsing
            t = self.hhmmss[:-1]
            dt = datetime.strptime(f"{self.date} {t}", "%Y-%m-%d %H%M%S")
            return dt.replace(tzinfo=timezone.utc)
        except Exception:
            return None


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def list_grafana_dates(root: str) -> List[str]:
    grafana_root = os.path.join(root, "k6", "grafana")
    if not os.path.isdir(grafana_root):
        return []
    out: List[str] = []
    for name in os.listdir(grafana_root):
        # YYYY-MM-DD
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", name) and os.path.isdir(os.path.join(grafana_root, name)):
            out.append(name)
    return sorted(out)


def scan_existing_runs(
    root: str,
    test_name_prefix: str,
    dates: Optional[List[str]] = None,
) -> List[RunRef]:
    """
    Scan k6/grafana/<date>/ for matching run directories and return RunRef entries.
    """
    if dates is None:
        dates = list_grafana_dates(root)
    runs: List[RunRef] = []
    for date in dates:
        day_dir = os.path.join(root, "k6", "grafana", date)
        if not os.path.isdir(day_dir):
            continue
        for entry in os.listdir(day_dir):
            m = RUN_DIR_RE.match(entry)
            if not m:
                continue
            prefix = m.group("prefix")
            if not prefix.startswith(test_name_prefix):
                continue
            target = int(m.group("target"))
            cpu_mult = float(m.group("cpu_mult"))
            hpa_num = int(m.group("hpa"))
            hhmmss = m.group("hhmmss")
            runs.append(
                RunRef(
                    date=date,
                    run_dir=os.path.join(day_dir, entry),
                    target=target,
                    cpu_mult=cpu_mult,
                    hpa_num=hpa_num,
                    hhmmss=hhmmss,
                )
            )
    return runs


def newest_run_by_key(runs: Iterable[RunRef]) -> Dict[Tuple[int, float, int], RunRef]:
    """
    Choose newest run per (target, cpu_mult, hpa_num).
    """
    best: Dict[Tuple[int, float, int], RunRef] = {}
    for r in runs:
        k = r.key
        cur = best.get(k)
        if cur is None:
            best[k] = r
            continue
        # Prefer parsed datetime, fallback to mtime
        dt_r = r.run_dt
        dt_c = cur.run_dt
        if dt_r is not None and dt_c is not None:
            if dt_r > dt_c:
                best[k] = r
            continue
        try:
            if os.path.getmtime(r.run_dir) > os.path.getmtime(cur.run_dir):
                best[k] = r
        except OSError:
            # ignore and keep current
            pass
    return best


def unified_report_path(run_dir: str) -> str:
    return os.path.join(run_dir, "unified_report.csv")


def is_complete_run(run_dir: str) -> bool:
    p = unified_report_path(run_dir)
    if not os.path.isfile(p):
        return False
    try:
        df = pd.read_csv(p, nrows=5)
    except Exception:
        return False
    # Minimal column check
    needed = {"k6_reqs", "k6_fail_pct", "k6_p95_ms"}
    return needed.issubset(set(df.columns))


def extract_metrics(run_dir: str) -> Dict[str, float]:
    csv_path = unified_report_path(run_dir)
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
    return {
        "weighted_p95_ms": weighted_p95_ms,
        "weighted_fail_pct": weighted_fail_pct,
        "max_repl_compose": float(df["Replicas_per_Service__compose-post"].max()),
        "max_repl_text": float(df["Replicas_per_Service__text-service"].max()),
        "max_repl_mention": float(df["Replicas_per_Service__user-mention-service"].max()),
    }



def run_hpa_comparison(
    root: str,
    hpa1: str,
    hpa2: str,
    test_name: str,
    k6_target: int,
    k6_duration: str,
    k6_timeout: str,
    hard_reset: bool,
) -> Tuple[str, str]:
    env = os.environ.copy()
    env["K6_TARGET"] = str(k6_target)
    env["K6_DURATION"] = k6_duration
    env["K6_TIMEOUT"] = k6_timeout
    # Drive CPU scaling through SERVICE_CPU_MULT env used by hpa_comparison_test.sh
    env["SERVICE_CPU_MULT"] = str(cfg.cpu_mult)

    cmd: List[str] = ["./hpa_comparison_test.sh"]
    if hard_reset:
        cmd.append("--hard-reset-testbed")
    cmd.extend([hpa1, hpa2, test_name])

    print(f"\n=== Running: {test_name} (VUs={k6_target}, duration={k6_duration}, timeout={k6_timeout}) ===")
    proc = subprocess.run(
        cmd,
        env=env,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    out = proc.stdout
    sys.stdout.write(out)
    if proc.returncode != 0:
        raise RuntimeError(f"hpa_comparison_test.sh failed (exit {proc.returncode}) for {test_name}")

    hpa1_dir = ""
    hpa2_dir = ""
    for line in out.splitlines():
        m1 = RE_HPA_DIR_HPA1.match(line.strip())
        if m1:
            hpa1_dir = m1.group(1)
        m2 = RE_HPA_DIR_HPA2.match(line.strip())
        if m2:
            hpa2_dir = m2.group(1)
    if not hpa1_dir or not hpa2_dir:
        raise RuntimeError(f"Failed to parse HPA run dirs for {test_name}")
    return hpa1_dir, hpa2_dir


def reset_testbed(root: str) -> None:
    cmd = [
        "./reset_testbed.sh",
        "--cluster-type",
        "kind",
        "--no-dns-resolution",
        "--persist-monitoring-data",
    ]
    subprocess.run(cmd, cwd=root, check=True)


def build_combined_csv_from_runs(
    root: str,
    test_name_prefix: str,
    out_csv: str,
    dates: Optional[List[str]] = None,
) -> None:
    runs = scan_existing_runs(root, test_name_prefix=test_name_prefix, dates=dates)
    newest = newest_run_by_key([r for r in runs if is_complete_run(r.run_dir)])

    rows: List[Dict[str, object]] = []
    for (target, cpu_mult, hpa_num), r in sorted(newest.items(), key=lambda x: (x[0][0], x[0][1], x[0][2])):
        metrics = extract_metrics(r.run_dir)
        rows.append(
            {
                "date": r.date,
                "hhmmss": r.hhmmss,
                "target": target,
                "cpu_mult": cpu_mult,
                "hpa": "context-aware" if hpa_num == 1 else "default",
                "run_dir": os.path.relpath(r.run_dir, root),
                **metrics,
            }
        )

    os.makedirs(os.path.dirname(out_csv), exist_ok=True)
    pd.DataFrame(rows).to_csv(out_csv, index=False)
    print(f"\n[INFO] Combined sweep CSV written: {out_csv} ({len(rows)} rows)")


def main() -> None:
    p = argparse.ArgumentParser(description="Resume HPA sweep and build one combined CSV.")
    p.add_argument("--hpa1", default="deathstar-bench/hpa/context_aware_hpa_dual_metric.yaml")
    p.add_argument("--hpa2", default="deathstar-bench/hpa/default_hpa.yaml")
    p.add_argument("--test-name-prefix", default="grid_search")
    p.add_argument("--targets", default="50,60,70,80,90")
    p.add_argument("--cpu-mults", default="0.6,0.8,1.0,1.2,1.5")
    p.add_argument("--duration", default="7m")
    p.add_argument("--timeout", default="5s")
    p.add_argument("--hard-reset-testbed", action="store_true")
    p.add_argument(
        "--dates",
        default="",
        help="Optional comma-separated YYYY-MM-DD list to scan/build from. Default: scan all dates.",
    )
    p.add_argument(
        "--out-csv",
        default="",
        help="Output CSV path. Default: k6/hpa_sweep_results_all.csv under repo root.",
    )
    p.add_argument(
        "--sweep-log",
        default="",
        help=(
            "Optional path to append sweep log output, e.g. "
            "logs/hpa_sweep_20260226_113610.log. Relative paths are resolved "
            "from the repo root."
        ),
    )
    p.add_argument(
        "--reset-between-configs",
        action="store_true",
        help="Reset testbed between sweep configurations (recommended).",
    )
    p.add_argument(
        "--continue-from-existing",
        action="store_true",
        help="Skip configurations that already have completed HPA1+HPA2 runs.",
    )
    args = p.parse_args()

    root = repo_root()
    dates = [d.strip() for d in args.dates.split(",") if d.strip()] or None

    try:
        targets = [int(x) for x in args.targets.split(",") if x.strip()]
    except ValueError:
        raise SystemExit("--targets must be comma-separated ints")
    try:
        cpu_mults = [float(x) for x in args.cpu_mults.split(",") if x.strip()]
    except ValueError:
        raise SystemExit("--cpu-mults must be comma-separated floats")

    out_csv = args.out_csv.strip()
    if not out_csv:
        out_csv = os.path.join(root, "k6", "hpa_sweep_results_all.csv")

    # Optional sweep log (append mode) so resume continues an existing log file
    sweep_log_path = args.sweep_log.strip()
    sweep_log_file: Optional[TextIO] = None
    if sweep_log_path:
        if not os.path.isabs(sweep_log_path):
            sweep_log_path = os.path.join(root, sweep_log_path)
        os.makedirs(os.path.dirname(sweep_log_path), exist_ok=True)
        try:
            sweep_log_file = open(sweep_log_path, "a", encoding="utf-8")
            ts = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
            sweep_log_file.write(f"\n=== HPA sweep resumed at {ts} UTC ===\n")
            sweep_log_file.flush()
        except OSError as e:
            print(f"[WARN] Failed to open sweep log '{sweep_log_path}' for append: {e}", file=sys.stderr)
            sweep_log_file = None

    def log(msg: str) -> None:
        print(msg)
        if sweep_log_file is not None:
            try:
                sweep_log_file.write(msg + "\n")
                sweep_log_file.flush()
            except OSError:
                # Don't crash sweep because of logging failure
                pass

    # Backup service_values.yaml so we can always restore
    svc_values_path = os.path.join(root, "deathstar-bench", "hpa", "service_values.yaml")
    if os.path.isfile(svc_values_path):
        with open(svc_values_path, "r", encoding="utf-8") as f:
            original_svc_values = f.read()
    else:
        original_svc_values = ""

    desired: List[SweepConfig] = [SweepConfig(t, m) for m in cpu_mults for t in targets]

    # Determine which configs are already complete
    completed: set[Tuple[int, float]] = set()
    if args.continue_from_existing:
        existing_runs = scan_existing_runs(root, test_name_prefix=args.test_name_prefix, dates=dates)
        newest = newest_run_by_key(existing_runs)
        for cfg in desired:
            r1 = newest.get((cfg.target, cfg.cpu_mult, 1))
            r2 = newest.get((cfg.target, cfg.cpu_mult, 2))
            if r1 and r2 and is_complete_run(r1.run_dir) and is_complete_run(r2.run_dir):
                completed.add((cfg.target, cfg.cpu_mult))

        log(f"[INFO] Detected {len(completed)}/{len(desired)} completed configs (will skip).")

    # Ensure we start from a clean cluster if we will run anything
    to_run = [cfg for cfg in desired if (cfg.target, cfg.cpu_mult) not in completed]
    if to_run:
        log("\n[INFO] Resetting testbed before resuming sweep...")
        reset_testbed(root)

    try:
        for i, cfg in enumerate(to_run):
            log(f"\n[INFO] Sweep progress: {i+1}/{len(to_run)} remaining configs")

            if original_svc_values:
                write_scaled_service_values(svc_values_path, cfg.cpu_mult)

            test_name = f"{args.test_name_prefix}_vu{cfg.target}_cpu{cfg.cpu_mult:g}"
            log(
                f"=== Sweep config: test_name={test_name}, "
                f"target={cfg.target}, duration={args.duration}, timeout={args.timeout} ==="
            )
            run_hpa_comparison(
                root=root,
                hpa1=args.hpa1,
                hpa2=args.hpa2,
                test_name=test_name,
                k6_target=cfg.target,
                k6_duration=args.duration,
                k6_timeout=args.timeout,
                hard_reset=args.hard_reset_testbed,
            )

            # Reset between configs for isolation
            if args.reset_between_configs and i < len(to_run) - 1:
                log("\n[INFO] Resetting testbed before next configuration...")
                reset_testbed(root)
    finally:
        if original_svc_values:
            with open(svc_values_path, "w", encoding="utf-8") as f:
                f.write(original_svc_values)
            log(f"\n[INFO] Restored original service_values.yaml at {svc_values_path}")
        if sweep_log_file is not None:
            try:
                sweep_log_file.close()
            except OSError:
                pass

    # Build combined CSV from runs (across days)
    build_combined_csv_from_runs(
        root=root,
        test_name_prefix=args.test_name_prefix,
        out_csv=out_csv,
        dates=dates,
    )


if __name__ == "__main__":
    main()

