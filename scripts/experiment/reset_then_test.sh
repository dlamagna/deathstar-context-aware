#!/bin/bash

# Parse arguments
LOOP_COUNT=1
WAIT_MINUTES=0
DO_AVERAGE=false
CPU_MULT=""
CONTINUE_FROM_LOG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --loop)
      if [ -z "$2" ]; then
        echo "Error: --loop requires a number"
        exit 1
      fi
      LOOP_COUNT="$2"
      shift 2
      ;;
    --wait)
      if [ -z "$2" ]; then
        echo "Error: --wait requires a number"
        exit 1
      fi
      WAIT_MINUTES="$2"
      shift 2
      ;;
    --average)
      DO_AVERAGE=true
      shift
      ;;
    --cpu-mult)
      if [ -z "$2" ]; then
        echo "Error: --cpu-mult requires a multiplier value (e.g. 0.8)"
        exit 1
      fi
      CPU_MULT="$2"
      shift 2
      ;;
    --continue-from)
      if [ -z "$2" ]; then
        echo "Error: --continue-from requires a log file path"
        exit 1
      fi
      CONTINUE_FROM_LOG="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--loop <number>] [--wait <minutes>] [--average] [--cpu-mult <multiplier>] [--continue-from <logfile>]"
      exit 1
      ;;
  esac
done

# Set up logging – stream all output to logs/ with a timestamp
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
if [ -n "$CONTINUE_FROM_LOG" ] && [ -f "$CONTINUE_FROM_LOG" ]; then
  LOG_FILE="$CONTINUE_FROM_LOG"
else
  LOG_FILE="$LOG_DIR/reset_then_test_$(date +%Y%m%d_%H%M%S).log"
fi
if command -v stdbuf >/dev/null 2>&1; then
  exec > >(stdbuf -oL tee -a "$LOG_FILE") 2>&1
else
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo "=========================================="
echo "Reset Then Test Script Started"
echo "Timestamp: $(date)"
echo "Log file: $LOG_FILE"
echo "Project root: $PROJECT_ROOT"
echo "Command invoked: $0 $*"
echo "=========================================="

# Validate loop count
if ! [[ "$LOOP_COUNT" =~ ^[0-9]+$ ]] || [ "$LOOP_COUNT" -lt 1 ]; then
  echo "Error: --loop must be followed by a positive integer"
  exit 1
fi

# Validate wait time - allow empty/unset or numeric values >= 0
if [ -n "$WAIT_MINUTES" ] && ! [[ "$WAIT_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "Error: --wait must be followed by a non-negative integer"
  exit 1
fi

if [ "$DO_AVERAGE" = true ] && [ "$LOOP_COUNT" -lt 2 ]; then
  echo "Warning: --average requires --loop >= 2 to be meaningful. Proceeding anyway."
fi

# Wait before starting if requested
if [ "${WAIT_MINUTES:-0}" -gt 0 ]; then
  WAIT_SECONDS=$((WAIT_MINUTES * 60))
  echo "Waiting for $WAIT_MINUTES minute(s) ($WAIT_SECONDS seconds) before starting..."
  sleep "$WAIT_SECONDS"
  echo "Wait completed. Starting the test sequence."
fi

# Arrays to collect grafana run directories across iterations
HPA1_RUN_DIRS=()
HPA2_RUN_DIRS=()
START_ITERATION=1

# Handle --continue-from: resume a previous run by parsing its log file
if [ -n "$CONTINUE_FROM_LOG" ]; then
  if [ ! -f "$CONTINUE_FROM_LOG" ]; then
    echo "Error: --continue-from log file not found: $CONTINUE_FROM_LOG"
    exit 1
  fi

  echo "[CONTINUE] Resuming from log: $CONTINUE_FROM_LOG"

  # Detect original LOOP_COUNT from the log when --loop was not explicitly given
  if [ "$LOOP_COUNT" -eq 1 ]; then
    prev_loop_count=$(grep -oP 'Starting iteration \d+ of \K\d+' "$CONTINUE_FROM_LOG" | tail -1 || true)
    if [ -n "$prev_loop_count" ]; then
      LOOP_COUNT="$prev_loop_count"
      echo "[CONTINUE] Detected original LOOP_COUNT=$LOOP_COUNT from previous log"
    fi
  fi

  # Find the last successfully completed iteration
  last_completed=$(grep -oP 'Completed iteration \K\d+' "$CONTINUE_FROM_LOG" | tail -1 || true)
  if [ -n "$last_completed" ]; then
    START_ITERATION=$((last_completed + 1))
    echo "[CONTINUE] Last completed iteration: $last_completed. Resuming from iteration $START_ITERATION."
  else
    echo "[CONTINUE] No completed iterations found in previous log. Starting from iteration 1."
  fi

  # Re-populate HPA run dirs from the previous log so aggregation includes all runs
  while IFS= read -r dir; do
    [ -n "$dir" ] && HPA1_RUN_DIRS+=("$dir")
  done < <(grep '^\[AGGREGATE\] Collected HPA1 run dir: ' "$CONTINUE_FROM_LOG" \
             | sed 's/\[AGGREGATE\] Collected HPA1 run dir: //' || true)

  while IFS= read -r dir; do
    [ -n "$dir" ] && HPA2_RUN_DIRS+=("$dir")
  done < <(grep '^\[AGGREGATE\] Collected HPA2 run dir: ' "$CONTINUE_FROM_LOG" \
             | sed 's/\[AGGREGATE\] Collected HPA2 run dir: //' || true)

  echo "[CONTINUE] Pre-loaded ${#HPA1_RUN_DIRS[@]} HPA1 run dir(s) and ${#HPA2_RUN_DIRS[@]} HPA2 run dir(s) from previous log"
  [ ${#HPA1_RUN_DIRS[@]} -gt 0 ] && printf "[CONTINUE]   HPA1: %s\n" "${HPA1_RUN_DIRS[@]}"
  [ ${#HPA2_RUN_DIRS[@]} -gt 0 ] && printf "[CONTINUE]   HPA2: %s\n" "${HPA2_RUN_DIRS[@]}"

  if [ "$START_ITERATION" -gt "$LOOP_COUNT" ]; then
    echo "[CONTINUE] All $LOOP_COUNT iteration(s) already completed."
    if [ "$DO_AVERAGE" = false ]; then
      echo "[CONTINUE] Nothing left to do. Pass --average to regenerate aggregated plots."
      exit 0
    fi
    echo "[CONTINUE] Running aggregation only with previously collected runs..."
  fi
fi

# Track summary info across all iterations for final report
declare -a ITER_RESET_LOGS=()
declare -a ITER_HPA_LOGS=()
declare -a ITER_COMPARISON_DIRS=()

# Loop through the test
for i in $(seq "$START_ITERATION" "$LOOP_COUNT"); do
  max_retries=3
  attempt=0
  hpa1_dir=""
  hpa2_dir=""
  reset_log=""
  hpa_log=""
  comparison_dir=""

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))

    echo "=========================================="
    if [ $attempt -gt 1 ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RETRY] Iteration $i attempt $attempt/$max_retries"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting iteration $i of $LOOP_COUNT"
    fi
    echo "=========================================="

    # ── 1. Reset testbed ────────────────────────────────────────────────────
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP] Running reset_testbed.sh ..."
    RESET_TMP=$(mktemp)
    trap "rm -f $RESET_TMP" EXIT
    "$PROJECT_ROOT/scripts/deploy/reset_testbed.sh" \
      --cluster-type kind \
      --no-dns-resolution \
      --persist-monitoring-data > "$RESET_TMP" 2>&1

    reset_log=$(grep 'Log file:' "$RESET_TMP" | head -1 | sed 's/.*Log file: //' | tr -d '[:space:]')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POINTER] reset_testbed.sh log → ${reset_log:-<not found>}"

    # ── 2. HPA comparison test ──────────────────────────────────────────────
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP] Running hpa_comparison_test.sh ..."
    TMP_CAPTURE=$(mktemp)
    trap "rm -f $TMP_CAPTURE" EXIT
    SERVICE_CPU_MULT="${CPU_MULT:-}" \
    K6_DURATION=7m \
    K6_TARGET=35 \
    K6_TIMEOUT=5s \
    "$PROJECT_ROOT/scripts/experiment/hpa_comparison_test.sh" \
      --hard-reset-testbed \
      deathstar-bench/hpa/default_hpa.yaml \
      deathstar-bench/hpa/context_aware_hpa_dual_metric.yaml \
      dual_test_35_vus > "$TMP_CAPTURE" 2>&1

    hpa_log=$(grep 'Log file:.*hpa_comparison_' "$TMP_CAPTURE" | head -1 | sed 's/.*Log file: //' | tr -d '[:space:]')
    hpa1_dir=$(grep '^HPA_RUN_DIR_HPA1=' "$TMP_CAPTURE" | tail -1 | cut -d= -f2-)
    hpa2_dir=$(grep '^HPA_RUN_DIR_HPA2=' "$TMP_CAPTURE" | tail -1 | cut -d= -f2-)
    comparison_log_path=$(grep 'Full comparison log saved to:' "$TMP_CAPTURE" | tail -1 | sed 's/.*Full comparison log saved to: //' | tr -d '[:space:]')
    comparison_dir="${comparison_log_path%/comparison.log}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POINTER] hpa_comparison_test.sh log → ${hpa_log:-<not found>}"

    if [ -n "$hpa1_dir" ] && [ -n "$hpa2_dir" ]; then
      break  # iteration succeeded
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] Iteration $i attempt $attempt produced no run dirs (hpa_comparison_test.sh likely failed)."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING]   reset_testbed log → ${reset_log:-<not found>}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING]   hpa_comparison log → ${hpa_log:-<not found>}"
    if [ $attempt -lt $max_retries ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] Retrying iteration $i..."
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] Giving up on iteration $i after $max_retries attempts."
    fi
  done

  if [ -n "$hpa1_dir" ] && [ -n "$hpa2_dir" ]; then
    ITER_RESET_LOGS+=("${reset_log:-<unknown>}")
    ITER_HPA_LOGS+=("${hpa_log:-<unknown>}")
    ITER_COMPARISON_DIRS+=("${comparison_dir:-<unknown>}")
    HPA1_RUN_DIRS+=("$hpa1_dir")
    echo "[AGGREGATE] Collected HPA1 run dir: $hpa1_dir"
    HPA2_RUN_DIRS+=("$hpa2_dir")
    echo "[AGGREGATE] Collected HPA2 run dir: $hpa2_dir"

    echo ""
    echo "=========================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Completed iteration $i of $LOOP_COUNT"
    echo "=========================================="
    echo "[ITER $i] Log files:"
    echo "  reset_testbed    → ${reset_log:-<not captured>}"
    echo "  hpa_comparison   → ${hpa_log:-<not captured>}"
    echo "[ITER $i] HPA run directories:"
    echo "  HPA1 run dir     → $hpa1_dir"
    echo "  HPA2 run dir     → $hpa2_dir"
    echo "  HPA1 data        → $hpa1_dir/unified_report.csv"
    echo "  HPA1 plots       → $hpa1_dir/plots/"
    echo "  HPA2 data        → $hpa2_dir/unified_report.csv"
    echo "  HPA2 plots       → $hpa2_dir/plots/"
    echo "[ITER $i] Comparison:"
    if [ -n "$comparison_dir" ]; then
      echo "  Comparison dir   → $comparison_dir"
      echo "  Overlay plots    → $comparison_dir/"
      echo "  Comparison log   → $comparison_dir/comparison.log"
      echo "  Latency breakdown→ $comparison_dir/latency_breakdown/"
    else
      echo "  Comparison dir   → <not found>"
    fi
    echo "=========================================="
    echo ""
  else
    echo ""
    echo "=========================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED iteration $i after $max_retries attempt(s) - skipping"
    echo "=========================================="
    echo ""
  fi

  # Small delay between iterations (except last)
  if [ "$i" -lt "$LOOP_COUNT" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting 2s before next iteration..."
    sleep 2
  fi
done

# Run aggregation if --average was specified and we have collected runs
if [ "$DO_AVERAGE" = true ]; then
  echo ""
  echo "=========================================="
  echo "Running Aggregation Across $LOOP_COUNT Iterations"
  echo "=========================================="

  if [ ${#HPA1_RUN_DIRS[@]} -lt 1 ] || [ ${#HPA2_RUN_DIRS[@]} -lt 1 ]; then
    echo "[ERROR] Not enough runs collected for aggregation."
    echo "  HPA1 dirs: ${#HPA1_RUN_DIRS[@]}"
    echo "  HPA2 dirs: ${#HPA2_RUN_DIRS[@]}"
    exit 1
  fi

  echo "[AGGREGATE] HPA1 runs (${#HPA1_RUN_DIRS[@]}):"
  printf "  %s\n" "${HPA1_RUN_DIRS[@]}"
  echo "[AGGREGATE] HPA2 runs (${#HPA2_RUN_DIRS[@]}):"
  printf "  %s\n" "${HPA2_RUN_DIRS[@]}"

  TODAY=$(date -u +%Y-%m-%d)
  AGG_TS=$(date -u +%H%M%SZ)
  AGG_DIR="k6/grafana/${TODAY}/aggregated_${AGG_TS}"
  python3 k6/aggregate_runs.py \
    --hpa1-dirs "${HPA1_RUN_DIRS[@]}" \
    --hpa2-dirs "${HPA2_RUN_DIRS[@]}" \
    --out-dir "$AGG_DIR" \
    --label-a "Context-Aware HPA" \
    --label-b "Default HPA"

  echo ""
  echo "=========================================="
  echo "Aggregation Complete"
  echo "=========================================="
  echo "Results saved to: $AGG_DIR/"
  echo "  $AGG_DIR/hpa1/       - averaged data + plots"
  echo "  $AGG_DIR/hpa2/       - averaged data + plots"
  echo "  $AGG_DIR/comparison/ - comparison plots + log"
fi

# ── Grand summary ─────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Grand Summary: All Iterations"
echo "=========================================="
echo "This session log → $LOG_FILE"
echo ""
# Number of iterations across all runs (including those loaded from --continue-from)
total_runs=${#HPA1_RUN_DIRS[@]}
# Offset: how many runs came from a previous log vs this session
prev_runs=$((total_runs - ${#ITER_HPA_LOGS[@]}))
for idx in "${!HPA1_RUN_DIRS[@]}"; do
  iter_num=$((idx + 1))
  echo "--- Iteration $iter_num ---"
  # Logs are only available for runs executed in this session
  session_idx=$((idx - prev_runs))
  if [ "$session_idx" -ge 0 ] && [ "$session_idx" -lt "${#ITER_HPA_LOGS[@]}" ]; then
    echo "  Logs:"
    echo "    reset_testbed  → ${ITER_RESET_LOGS[$session_idx]:-<unknown>}"
    echo "    hpa_comparison → ${ITER_HPA_LOGS[$session_idx]:-<unknown>}"
    echo "  Comparison dir → ${ITER_COMPARISON_DIRS[$session_idx]:-<unknown>}"
  else
    echo "  (run from previous session — see --continue-from log for details)"
  fi
  echo "  HPA1 run dir   → ${HPA1_RUN_DIRS[$idx]}"
  echo "    data         → ${HPA1_RUN_DIRS[$idx]}/unified_report.csv"
  echo "    plots        → ${HPA1_RUN_DIRS[$idx]}/plots/"
  if [ "$idx" -lt "${#HPA2_RUN_DIRS[@]}" ]; then
    echo "  HPA2 run dir   → ${HPA2_RUN_DIRS[$idx]}"
    echo "    data         → ${HPA2_RUN_DIRS[$idx]}/unified_report.csv"
    echo "    plots        → ${HPA2_RUN_DIRS[$idx]}/plots/"
  fi
done
if [ "$DO_AVERAGE" = true ] && [ -n "${AGG_DIR:-}" ]; then
  echo ""
  echo "--- Aggregated Results ---"
  echo "  Aggregation dir → $AGG_DIR/"
  echo "    HPA1 avg      → $AGG_DIR/hpa1/"
  echo "    HPA2 avg      → $AGG_DIR/hpa2/"
  echo "    Comparison    → $AGG_DIR/comparison/"
fi
echo "=========================================="
