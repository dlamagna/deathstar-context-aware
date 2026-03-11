#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 --iterations <n> [--continue-from <reset_then_test_log>]"
  echo ""
  echo "  --iterations <n>          Total number of successful runs required"
  echo "  --continue-from <log>     Resume from a previous reset_then_test log."
  echo "                            Only iterations with actual result dirs count."
  echo "                            New runs append to the same log file."
  exit 1
}

ITERATIONS=""
CONTINUE_FROM_LOG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --iterations)
      [ -z "${2:-}" ] && { echo "Error: --iterations requires a number"; exit 1; }
      ITERATIONS="$2"; shift 2 ;;
    --continue-from)
      [ -z "${2:-}" ] && { echo "Error: --continue-from requires a log file path"; exit 1; }
      CONTINUE_FROM_LOG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[ -z "$ITERATIONS" ] && { echo "Error: --iterations is required"; usage; }
if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
  echo "Error: --iterations must be a positive integer"; exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo "Run Aggregated Experiment"
echo "Timestamp: $(date)"
echo "Requested iterations: $ITERATIONS"
[ -n "$CONTINUE_FROM_LOG" ] && echo "Continue from: $CONTINUE_FROM_LOG"
echo "=========================================="

# ── 1. Kill all existing related processes ────────────────────────────────────
echo ""
echo "[SETUP] Killing existing related processes..."
# Exclude this script, its parent shell, and the grep itself from the kill list
mapfile -t pids < <(ps aux \
  | grep -E "(reset_then_test|hpa_comparison_test|reset_testbed\.sh|monitor_reset_then_test|/k6 run)" \
  | grep -v grep \
  | awk '{print $2}' \
  | grep -vxF "$$" \
  | grep -vxF "$PPID" \
  || true)
if [ ${#pids[@]} -gt 0 ]; then
  echo "[SETUP] Killing PIDs: ${pids[*]}"
  kill -9 "${pids[@]}" 2>/dev/null || true
  sleep 2
  echo "[SETUP] Processes killed."
else
  echo "[SETUP] No related processes found."
fi

# ── 2. Clear cron monitor entries ────────────────────────────────────────────
echo "[SETUP] Clearing monitor cron entries..."
existing_cron=$(crontab -l 2>/dev/null | grep monitor_reset_then_test || true)
if [ -n "$existing_cron" ]; then
  crontab -l 2>/dev/null | grep -v monitor_reset_then_test | grep -v '^[[:space:]]*$' | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
  echo "[SETUP] Cron entries removed."
else
  echo "[SETUP] No cron entries found."
fi

# ── 3. Resolve resume parameters ──────────────────────────────────────────────
loop_count="$ITERATIONS"
continue_arg=""
successful_count=0
last_completed=0

if [ -n "$CONTINUE_FROM_LOG" ]; then
  if [ ! -f "$CONTINUE_FROM_LOG" ]; then
    echo "Error: --continue-from log file not found: $CONTINUE_FROM_LOG"
    exit 1
  fi

  # Count iterations that actually produced result dirs (not just "Completed" markers)
  successful_count=$(grep -c '^\[AGGREGATE\] Collected HPA1 run dir: ' "$CONTINUE_FROM_LOG" 2>/dev/null || true)
  successful_count=${successful_count:-0}

  # Last iteration number marked Completed (used to set START_ITERATION in reset_then_test.sh)
  last_completed=$(grep -oP 'Completed iteration \K\d+' "$CONTINUE_FROM_LOG" | sort -n | tail -1 || true)
  last_completed=${last_completed:-0}

  echo ""
  echo "[RESUME] Previous log:              $CONTINUE_FROM_LOG"
  echo "[RESUME] Successful runs with data: $successful_count"
  echo "[RESUME] Last completed iter num:   $last_completed"

  remaining=$((ITERATIONS - successful_count))

  if [ "$remaining" -le 0 ]; then
    echo "[RESUME] Already have $successful_count/$ITERATIONS successful runs."
    echo "[RESUME] Running aggregation only."
    # Pass --loop = last_completed so START_ITERATION > LOOP_COUNT → skip straight to aggregation
    loop_count="$last_completed"
  else
    echo "[RESUME] Need $remaining more run(s)."
    loop_count=$((last_completed + remaining))
    echo "[RESUME] Setting --loop $loop_count (resumes from iteration $((last_completed + 1)))."
  fi

  continue_arg="--continue-from $CONTINUE_FROM_LOG"
fi

# ── 4. Launch reset_then_test.sh ──────────────────────────────────────────────
echo ""
echo "[LAUNCH] Starting reset_then_test.sh --loop $loop_count --average $continue_arg"
# shellcheck disable=SC2086
nohup "$PROJECT_ROOT/scripts/experiment/reset_then_test.sh" --loop "$loop_count" --average $continue_arg \
  > /tmp/reset_then_test_launcher.log 2>&1 &
NEW_PID=$!
echo "[LAUNCH] PID: $NEW_PID"

# Wait briefly for the script to create/open its log file
sleep 3

# ── 5. Determine log file path ────────────────────────────────────────────────
if [ -n "$CONTINUE_FROM_LOG" ]; then
  LOG_FILE="$CONTINUE_FROM_LOG"
else
  LOG_FILE=$(ls -t "$PROJECT_ROOT/logs/reset_then_test_"*.log 2>/dev/null | head -1 || true)
fi

echo "[LAUNCH] Log file: ${LOG_FILE:-<not yet created — check logs/>}"

# ── 6. Set up cron monitor ────────────────────────────────────────────────────
echo ""
echo "[MONITOR] Setting up 5-minute cron monitor for PID $NEW_PID..."
(crontab -l 2>/dev/null; echo "*/5 * * * * $PROJECT_ROOT/scripts/monitor/monitor_reset_then_test.sh $NEW_PID $PROJECT_ROOT") | crontab -
echo "[MONITOR] Cron entry added."
echo "[MONITOR] Verify with: crontab -l"

echo ""
echo "=========================================="
echo "Experiment running"
echo "  PID:        $NEW_PID"
echo "  Log:        ${LOG_FILE:-<check logs/>}"
echo "  Monitor:    every 5 min via cron"
echo "  Track log:  tail -f ${LOG_FILE:-logs/reset_then_test_*.log}"
echo "=========================================="
