#!/bin/bash

# Parse arguments
LOOP_COUNT=1
WAIT_MINUTES=0
DO_AVERAGE=false
CPU_MULT=""

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
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--loop <number>] [--wait <minutes>] [--average] [--cpu-mult <multiplier>]"
      exit 1
      ;;
  esac
done

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

# Loop through the test
for i in $(seq 1 "$LOOP_COUNT"); do
  echo "=========================================="
  echo "Starting iteration $i of $LOOP_COUNT"
  echo "=========================================="
  
  # Reset the testbed with the desired configuration
  ./reset_testbed.sh \
    --cluster-type kind \
    --no-dns-resolution \
    --persist-monitoring-data

  # Run the HPA comparison test; tee so output is shown live and captured for parsing
  TMP_CAPTURE=$(mktemp)
  trap "rm -f $TMP_CAPTURE" EXIT
  SERVICE_CPU_MULT="${CPU_MULT:-}" \
  K6_DURATION=7m \
  K6_TARGET=120 \
  K6_TIMEOUT=5s \
  ./hpa_comparison_test.sh \
    --hard-reset-testbed \
    deathstar-bench/hpa/context_aware_hpa_dual_metric.yaml \
    deathstar-bench/hpa/default_hpa.yaml \
    dual_test_all_50 2>&1 | tee "$TMP_CAPTURE"

  # Extract the grafana run directories from machine-readable output
  hpa1_dir=$(grep '^HPA_RUN_DIR_HPA1=' "$TMP_CAPTURE" | tail -1 | cut -d= -f2-)
  hpa2_dir=$(grep '^HPA_RUN_DIR_HPA2=' "$TMP_CAPTURE" | tail -1 | cut -d= -f2-)

  if [ -n "$hpa1_dir" ]; then
    HPA1_RUN_DIRS+=("$hpa1_dir")
    echo "[AGGREGATE] Collected HPA1 run dir: $hpa1_dir"
  else
    echo "[AGGREGATE] WARNING: No HPA1 run dir found for iteration $i"
  fi

  if [ -n "$hpa2_dir" ]; then
    HPA2_RUN_DIRS+=("$hpa2_dir")
    echo "[AGGREGATE] Collected HPA2 run dir: $hpa2_dir"
  else
    echo "[AGGREGATE] WARNING: No HPA2 run dir found for iteration $i"
  fi
  
  echo "=========================================="
  echo "Completed iteration $i of $LOOP_COUNT"
  echo "=========================================="
  
  # Add a small delay between iterations (except for the last one)
  if [ "$i" -lt "$LOOP_COUNT" ]; then
    echo "Waiting before next iteration..."
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
