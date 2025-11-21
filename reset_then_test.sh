#!/bin/bash

# Parse arguments
LOOP_COUNT=1
WAIT_MINUTES=0

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
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--loop <number>] [--wait <minutes>]"
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

# Wait before starting if requested
if [ "${WAIT_MINUTES:-0}" -gt 0 ]; then
  WAIT_SECONDS=$((WAIT_MINUTES * 60))
  echo "Waiting for $WAIT_MINUTES minute(s) ($WAIT_SECONDS seconds) before starting..."
  sleep "$WAIT_SECONDS"
  echo "Wait completed. Starting the test sequence."
fi

# # Reset the testbed with the desired configuration
# ./reset_testbed.sh \
#   --cluster-type kind \
#   --no-dns-resolution \
#   --persist-monitoring-data

# # Run the HPA comparison test with environment variables
# K6_DURATION=10m \
# K6_TARGET=50 \
# K6_TIMEOUT=5s \
# ./hpa_comparison_test.sh \
#   --hard-reset-testbed \
#   deathstar-bench/hpa/default_hpa.yaml \
#   deathstar-bench/hpa/default_hpa.yaml \
#   parity_test_default_hpa

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

  # Run the HPA comparison test with environment variables
  K6_DURATION=10m \
  K6_TARGET=50 \
  K6_TIMEOUT=5s \
  ./hpa_comparison_test.sh \
    --hard-reset-testbed \
    deathstar-bench/hpa/context_aware_hpa_parent_child_combo.yaml \
    deathstar-bench/hpa/default_hpa.yaml \
    reverse_Test_combo_45_40
  
  echo "=========================================="
  echo "Completed iteration $i of $LOOP_COUNT"
  echo "=========================================="
  
  # Add a small delay between iterations (except for the last one)
  if [ "$i" -lt "$LOOP_COUNT" ]; then
    echo "Waiting before next iteration..."
    sleep 2
  fi
done
