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
  deathstar-bench/hpa/context_aware_hpa_parent_child_step_up_down.yaml \
  deathstar-bench/hpa/default_hpa.yaml \
  reverse_Test_step_up_down
