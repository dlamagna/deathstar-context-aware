#!/bin/bash

# HPA Comparison Test Script
# Automates the process of comparing two HPA configurations using k6 load testing
# Usage: ./hpa_comparison_test.sh <hpa1.yaml> <hpa2.yaml> <test_name>
#
# Enhanced Logging Features:
# - All script output is automatically logged to logs/hpa_comparison_YYYYMMDD_HHMMSS.log
# - Python subprocess output (k6_report_comparison.py, scrape_grafana_dashboard.py)
#   is captured and logged using the run_with_logging() function
# - k6 test output is also captured and logged

set -e  # Exit on any error

# Logging to file (stream live to logs/ via tee)
# All script output and Python subprocess output will be captured in the log file
# Use line-buffered tee when available so output appears on terminal immediately
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hpa_comparison_$(date +%Y%m%d_%H%M%S).log"
if command -v stdbuf >/dev/null 2>&1; then
    exec > >(stdbuf -oL tee -a "$LOG_FILE") 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Log startup message with command used to invoke script
echo "=========================================="
echo "HPA Comparison Test Script Started"
echo "Timestamp: $(date)"
echo "Log file: $LOG_FILE"
echo "Project root: $PROJECT_ROOT"
echo "Command invoked: $0 $*"
echo "=========================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output with timestamps
print_status() {
    echo -e "${BLUE}[INFO]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Apply service_values.yaml, optionally scaling CPU via SERVICE_CPU_MULT/CPU_MULT.
apply_service_values_with_multiplier() {
    local base_file="deathstar-bench/hpa/service_values.yaml"
    local mult="${SERVICE_CPU_MULT:-${CPU_MULT:-1}}"

    if [ ! -f "$base_file" ]; then
        print_warning "Service values file not found at $base_file, skipping CPU scaling."
        return 1
    fi

    # If multiplier is unset or effectively 1, apply as-is.
    if [ -z "$mult" ] || [ "$mult" = "1" ] || [ "$mult" = "1.0" ]; then
        print_status "Applying service CPU values without scaling (multiplier=${mult:-1})..."
        kubectl apply -f "$base_file" -n socialnetwork --server-side --force-conflicts
        return $?
    fi

    print_status "Applying service CPU values with multiplier $mult (compose/text/mention/nginx)..."

    # Scale any cpu: "<number>m" lines by the multiplier. This keeps YAML structure intact.
    local tmp_file
    tmp_file=$(mktemp)
    awk -v mult="$mult" '
        /cpu: *"[0-9]+m"/ {
            if (match($0, /"([0-9]+)m"/, m)) {
                v = int(m[1] * mult + 0.5);
                if (v < 1) v = 1;
                sub(/"[0-9]+m"/, "\"" v "m\"");
            }
        }
        { print }
    ' "$base_file" > "$tmp_file"

    kubectl apply -f "$tmp_file" -n socialnetwork --server-side --force-conflicts
    local rc=$?
    rm -f "$tmp_file"
    return $rc
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <hpa1.yaml> <hpa2.yaml> <test_name> [--force-reset-hpa] [--hard-reset-testbed] [--no-dns-resolution]"
    echo ""
    echo "Arguments:"
    echo "  hpa1.yaml    - First HPA configuration file"
    echo "  hpa2.yaml    - Second HPA configuration file"
    echo "  test_name    - Name for this test run (used in output files)"
    echo ""
    echo "Options:"
    echo "  --force-reset-hpa     - Use aggressive reset (delete HPA, scale down, restart) between tests"
    echo "  --hard-reset-testbed  - Use full testbed reset (calls reset_testbed.sh) between tests"
    echo "  --no-dns-resolution   - Skip DNS workarounds in testbed reset (for environments without DNS issues)"
    echo "  --help        - Show this help message"
    echo ""
    echo "Environment Variables (optional):"
    echo "  K6_DURATION       - k6 test duration (default: 120s)"
    echo "  K6_TARGET         - k6 target VUs (default: 50)"
    echo "  K6_TIMEOUT        - k6 request timeout (default: 5s)"
    echo "  SERVICE_CPU_MULT  - CPU multiplier for compose-post/text/user-mention/nginx services (default: 1.0)"
    echo "                       e.g. SERVICE_CPU_MULT=0.8 scales 60m -> 48m, 100m -> 80m"
    echo ""
    echo "  HPA-specific overrides (take precedence over global values):"
    echo "  K6_TIMEOUT_HPA1  - k6 timeout for first HPA test"
    echo "  K6_TIMEOUT_HPA2  - k6 timeout for second HPA test"
    echo "  K6_DURATION_HPA1 - k6 duration for first HPA test"
    echo "  K6_DURATION_HPA2 - k6 duration for second HPA test"
    echo "  K6_TARGET_HPA1   - k6 target VUs for first HPA test"
    echo "  K6_TARGET_HPA2   - k6 target VUs for second HPA test"
    echo ""
    echo "Example:"
    echo "  $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml parity_test"
    echo ""
    echo "Example with force reset for guaranteed clean state:"
    echo "  $0 --force-reset-hpa deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml clean_test"
    echo ""
    echo "Example with hard reset (full testbed reset):"
    echo "  $0 --hard-reset-testbed deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml hard_reset_test"
    echo ""
    echo "Example with hard reset and no DNS workarounds:"
    echo "  $0 --hard-reset-testbed --no-dns-resolution deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml clean_test"
    echo ""
    echo "Example with custom parameters:"
    echo "  K6_DURATION=300s K6_TARGET=100 K6_TIMEOUT=10s $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml long_test"
    echo ""
    echo "Example with different timeouts per HPA:"
    echo "  K6_TIMEOUT_HPA1=5s K6_TIMEOUT_HPA2=10s $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml timeout_test"
    echo ""
    echo "Example with global timeout applied to both HPAs:"
    echo "  K6_TIMEOUT=10s $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml long_timeout_test"
    exit 1
}

# Initialize variables
FORCE_RESET_HPA=false
HARD_RESET_TESTBED=false
NO_DNS_RESOLUTION=false

# Parse flags (can be in any order)
while [[ $# -gt 0 ]]; do
    case $1 in
        --force-reset-hpa)
            FORCE_RESET_HPA=true
            shift
            ;;
        --hard-reset-testbed)
            HARD_RESET_TESTBED=true
            shift
            ;;
        --no-dns-resolution)
            NO_DNS_RESOLUTION=true
            shift
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            # Not a flag, break out of loop
            break
            ;;
    esac
done

# Check arguments (after potential shift)
if [ $# -ne 3 ]; then
    print_error "Invalid number of arguments"
    show_usage
fi

# Validate that both reset flags are not used together
if [ "$FORCE_RESET_HPA" = true ] && [ "$HARD_RESET_TESTBED" = true ]; then
    print_error "Cannot use both --force-reset-hpa and --hard-reset-testbed flags together"
    print_error "Choose either --force-reset-hpa (aggressive reset) or --hard-reset-testbed (full testbed reset)"
    exit 1
fi

HPA1_FILE="$1"
HPA2_FILE="$2"
TEST_NAME="$3"

# Validate files exist
if [ ! -f "$HPA1_FILE" ]; then
    print_error "HPA file 1 not found: $HPA1_FILE"
    exit 1
fi

if [ ! -f "$HPA2_FILE" ]; then
    print_error "HPA file 2 not found: $HPA2_FILE"
    exit 1
fi

# Set output file names with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="k6/reports"
HPA1_OUTPUT="${OUTPUT_DIR}/${TEST_NAME}_hpa1_${TIMESTAMP}.csv"
HPA2_OUTPUT="${OUTPUT_DIR}/${TEST_NAME}_hpa2_${TIMESTAMP}.csv"
COMPARISON_OUTPUT="${OUTPUT_DIR}/${TEST_NAME}_comparison_${TIMESTAMP}.json"

print_status "Starting HPA Comparison Test: $TEST_NAME"
print_status "HPA1: $HPA1_FILE"
print_status "HPA2: $HPA2_FILE"

# Show reset method that will be used
if [ "$HARD_RESET_TESTBED" = true ]; then
    print_status "Reset method: Hard reset (full testbed reset via reset_testbed.sh)"
elif [ "$FORCE_RESET_HPA" = true ]; then
    print_status "Reset method: Force reset (aggressive reset - delete HPA, scale down, restart)"
else
    print_status "Reset method: Standard reset (wait for HPA to scale down naturally)"
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Function to get nginx service endpoint
get_nginx_endpoint() {
    local NODE_PORT=$(kubectl get svc nginx-thrift -n socialnetwork -o jsonpath='{.spec.ports[0].nodePort}')
    local NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    echo "$NODE_IP:$NODE_PORT"
}

# Function to wait for deployments to stabilize
wait_for_stabilization() {
    print_status "Waiting for deployments to stabilize..."
    kubectl rollout restart deploy -n socialnetwork nginx-thrift compose-post-service text-service user-mention-service
    sleep 30
    print_status "Deployments restarted, waiting for pods to be ready..."
    
    # Wait for deployments to be ready with retries
    wait_for_deployment_ready "nginx-thrift"
    wait_for_deployment_ready "compose-post-service"
    wait_for_deployment_ready "text-service"
    wait_for_deployment_ready "user-mention-service"
    
    print_success "All deployments are ready"
    sleep 30
}

# Function to wait for a specific deployment to be ready with retries
wait_for_deployment_ready() {
    local deployment_name="$1"

    # nginx-thrift has heavier init logic (git clone, etc.), so give it more time.
    local max_attempts=5
    local timeout="60s"
    if [ "$deployment_name" = "nginx-thrift" ]; then
        max_attempts=10
        timeout="120s"
        print_status "Using extended readiness wait for $deployment_name (max_attempts=$max_attempts, timeout=$timeout)"
    fi

    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_status "Waiting for $deployment_name to be ready (attempt $attempt/$max_attempts)..."
        
        # Use rollout status on the deployment instead of pod-level waits so
        # old terminating pods don't cause spurious timeouts.
        if kubectl rollout status deployment/"$deployment_name" -n socialnetwork --timeout="$timeout"; then
            print_success "$deployment_name is ready"
            return 0
        else
            print_warning "$deployment_name not ready, attempt $attempt failed"
            
            # Check pod status for debugging
            print_status "Pod status for $deployment_name:"
            kubectl get pods -n socialnetwork -l app="$deployment_name"
            
            # Check if pods are in error state
            local error_pods
            error_pods=$(kubectl get pods -n socialnetwork -l app="$deployment_name" --field-selector=status.phase!=Running --no-headers | wc -l)
            if [ "$error_pods" -gt 0 ]; then
                print_warning "Found $error_pods pods not running for $deployment_name"
                kubectl describe pods -n socialnetwork -l app="$deployment_name" | grep -A 5 -B 5 "Events:"
            fi
            
            attempt=$((attempt + 1))
            if [ $attempt -le $max_attempts ]; then
                print_status "Retrying in 30 seconds..."
                sleep 30
            fi
        fi
    done
    
    print_error "Failed to get $deployment_name ready after $max_attempts attempts"
    return 1
}

# Function to print k6 stage information
print_k6_stages() {
    local target="${K6_TARGET:-50}"
    local duration="${K6_DURATION:-120s}"
    local timeout="${K6_TIMEOUT:-5s}"
    
    print_status "=== k6 Load Test Configuration ==="
    print_status "Target VUs: $target"
    print_status "Main Duration: $duration"
    print_status "Request Timeout: $timeout"
    print_status ""
    print_status "=== k6 Test Stages ==="
    
    # Calculate stage targets (matching k6_loader.js logic)
    local first_warmup_target=$((target * 60 / 100))  # 30% of target for warmup
    local second_warmup_target=$((target * 90 / 100))  # 30% of target for warmup
    local cooldown_target=1
    
    print_status "Stage 1 (Warmup):"
    print_status "  Duration: 30s"
    print_status "  Start VUs: 0 (ramps from zero)"
    print_status "  Target VUs: $first_warmup_target"
    print_status ""
    print_status "Stage 2 (Ramp to Full Load):"
    print_status "  Duration: 30s"
    print_status "  Target VUs: $second_warmup_target"
    print_status ""
    print_status "Stage 3 (Sustained Load):"
    print_status "  Duration: $duration"
    print_status "  Target VUs: $target (held constant)"
    print_status ""
    print_status "Stage 4 (Cooldown):"
    print_status "  Duration: 1m"
    print_status "  Target VUs: $cooldown_target"
    print_status ""
    # Calculate total duration in seconds for display
    local duration_secs
    if [[ $duration =~ ^([0-9]+)m$ ]]; then
        duration_secs=$((${BASH_REMATCH[1]} * 60))
    elif [[ $duration =~ ^([0-9]+)s$ ]]; then
        duration_secs=${BASH_REMATCH[1]}
    else
        duration_secs=120  # fallback
    fi
    local total_duration=$((duration_secs + 120))
    print_status "Total test duration: ~${total_duration}s (30s warmup + 30s ramp + ${duration} sustained + 1m cooldown)"
    print_status "=========================================="
}

# Function to run k6 test
# Save a snapshot of all relevant configuration into a run's config/ directory
save_run_config() {
    local run_dir="$1"
    local test_desc="$2"
    local hpa_label="$3"
    local k6_csv="$4"
    local config_dir="$run_dir/config"
    mkdir -p "$config_dir"

    # Copy HPA YAML used for this run
    local hpa_file
    if [ "$hpa_label" = "hpa1" ]; then
        hpa_file="$HPA1_FILE"
    else
        hpa_file="$HPA2_FILE"
    fi
    if [ -f "$hpa_file" ]; then
        cp "$hpa_file" "$config_dir/hpa_config.yaml"
    fi

    # Copy service resource definitions
    if [ -f "deathstar-bench/hpa/service_values.yaml" ]; then
        cp "deathstar-bench/hpa/service_values.yaml" "$config_dir/service_values.yaml"
    fi

    # Copy Prometheus adapter values
    if [ -f "prom/prometheus-adapter-values-parent-child.yaml" ]; then
        cp "prom/prometheus-adapter-values-parent-child.yaml" "$config_dir/prometheus_adapter_values.yaml"
    fi

    # Copy Grafana dashboard JSON
    if [ -f "deathstar-bench/monitoring/davide-dashboard.json" ]; then
        cp "deathstar-bench/monitoring/davide-dashboard.json" "$config_dir/grafana_dashboard.json"
    fi

    # Copy k6 loader script
    if [ -f "k6/k6_loader.js" ]; then
        cp "k6/k6_loader.js" "$config_dir/k6_loader.js"
    fi

    # Write a human-readable run summary
    cat > "$config_dir/run_details.txt" <<RUNEOF
=== Run Configuration ===
Date:             $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Test Name:        $TEST_NAME
Test Description: $test_desc
HPA Label:        $hpa_label
Run Directory:    $run_dir

=== Command ===
$0 $HPA1_FILE $HPA2_FILE $TEST_NAME

=== k6 Parameters ===
K6_DURATION:      ${K6_DURATION:-120s}
K6_TARGET (VUs):  ${K6_TARGET:-50}
K6_TIMEOUT:       ${K6_TIMEOUT:-5s}
K6 CSV Output:    $k6_csv

=== HPA Configuration ===
HPA File:         $hpa_file
HPA YAML (inline):
$(cat "$hpa_file" 2>/dev/null || echo "(not available)")

=== Environment ===
Reset Method:        $(if [ "$HARD_RESET_TESTBED" = true ]; then echo "Hard reset"; elif [ "$FORCE_RESET_HPA" = true ]; then echo "Force reset"; else echo "Standard reset"; fi)
Service CPU Mult:    ${SERVICE_CPU_MULT:-1.0}
Kubernetes Context:  $(kubectl config current-context 2>/dev/null || echo "(unknown)")
Cluster Nodes:
$(kubectl get nodes -o wide 2>/dev/null | head -5 || echo "(unavailable)")

=== HPA Status at Test Start ===
$(kubectl get hpa -n socialnetwork 2>/dev/null || echo "(unavailable)")

=== Deployment Status at Test Start ===
$(kubectl get deploy -n socialnetwork 2>/dev/null | grep -E "(NAME|nginx-thrift|compose-post-service|text-service|user-mention-service)" || echo "(unavailable)")

=== Files in config/ ===
hpa_config.yaml              - HPA YAML used for this run ($hpa_file)
service_values.yaml          - Service CPU/memory resource definitions
prometheus_adapter_values.yaml - Prometheus adapter external metrics config
grafana_dashboard.json       - Grafana dashboard used for metric scraping
k6_loader.js                 - k6 load test script
run_details.txt              - This file
RUNEOF

    print_status "Saved run configuration to $config_dir/"
}

run_k6_test() {
    local output_file="$1"
    local test_desc="$2"
    local hpa_label="${3:-}"  # e.g. "hpa1" or "hpa2", used to tag Grafana CSV
    
    print_status "Running k6 test: $test_desc"
    print_status "Output file: $output_file"
    
    # Get nginx endpoint
    local nginx_endpoint=$(get_nginx_endpoint)
    export NGINX_HOST="$nginx_endpoint"
    export K6_DURATION="${K6_DURATION:-120s}"
    export K6_TARGET="${K6_TARGET:-50}"
    export K6_TIMEOUT="${K6_TIMEOUT:-5s}"
    
    print_status "NGINX endpoint: $NGINX_HOST"
    
    # Print k6 stage information
    print_k6_stages
    
    # Create log file for k6 warnings/errors (messages starting with "time=")
    local k6_log_file="$LOG_DIR/k6_test_$(date +%Y%m%d_%H%M%S)_$$.log"
    
    # Determine start/end window (±60s)
    local K6_START_EPOCH=$(date +%s)
    # Run k6 with silent mode and redirect stderr to log file only
    local k6_cmd="k6 run -q k6/k6_loader.js --out csv=\"$output_file\" 2> \"$k6_log_file\""
    
    print_status "k6 warnings and errors will be logged to: $k6_log_file"
    print_status "k6 request timeout for this run: ${K6_TIMEOUT}"
    
    if run_with_logging "$k6_cmd" "k6 load test: $test_desc"; then
        print_success "k6 test completed successfully: $test_desc"
        print_status "k6 errors/warnings saved to: $k6_log_file"
    else
        print_error "k6 test failed: $test_desc"
        exit 1
    fi
    local K6_END_EPOCH=$(date +%s)

    # Scrape Grafana dashboard queries (Prometheus) for the test window ±60s
    local prom_url=$(get_prometheus_url)
    local start_window=$((K6_START_EPOCH-60))
    local end_window=$((K6_END_EPOCH+60))
    local grafana_ref="${TEST_NAME}"
    if [ -n "$hpa_label" ]; then
        grafana_ref="${TEST_NAME}_${hpa_label}"
    fi
    print_status "Scraping Grafana dashboard queries for time window ${start_window}..${end_window} (±60s)"
    local scrape_output
    scrape_output=$(python3 k6/scrape_grafana_dashboard.py \
      --dashboard-json deathstar-bench/monitoring/davide-dashboard.json \
      --prom "$prom_url" \
      --start "$start_window" \
      --end "$end_window" \
      --ref-name "$grafana_ref" \
      --out-dir k6/grafana 2>&1) || print_warning "Grafana scraping failed for $test_desc"
    echo "$scrape_output"

    # Merge k6 + Grafana into a unified report, then generate per-run plots
    local grafana_run_dir
    grafana_run_dir=$(echo "$scrape_output" | grep '^GRAFANA_RUN_DIR=' | tail -1 | cut -d= -f2-)
    if [ -n "$grafana_run_dir" ] && [ -f "$grafana_run_dir/grafana_master.csv" ]; then
        local run_plots_dir="$grafana_run_dir/plots"

        print_status "Merging k6 + Grafana data into unified report..."
        python3 k6/merge_k6_grafana.py \
          --k6-csv "$output_file" \
          --grafana-csv "$grafana_run_dir/grafana_master.csv" \
          --bucket-sec 15 || print_warning "k6+Grafana merge failed for $test_desc"

        # Per-run k6 plots (latency, throughput, success rate, distribution)
        print_status "Generating per-run k6 plots..."
        python3 k6/k6_csv_report_parser.py \
          --k6-csv "$output_file" \
          --out-dir "$run_plots_dir" \
          --label "$grafana_ref" || print_warning "k6 per-run plots failed for $test_desc"

        # 4-panel overview (success rate, error rate, replicas, CPU)
        if [ -f "$grafana_run_dir/unified_report.csv" ]; then
            print_status "Generating 4-panel overview plot..."
            python3 k6/4by4plots.py \
              --unified-csv "$grafana_run_dir/unified_report.csv" \
              --out-dir "$run_plots_dir" \
              --label "$grafana_ref" || print_warning "4-panel overview failed for $test_desc"

            # Summarize nginx-thrift CPU usage to help detect bottlenecks
            print_status "Summarizing nginx-thrift CPU usage for bottleneck check..."
            python3 k6/nginx_cpu_summary.py \
              --unified "$grafana_run_dir/unified_report.csv" \
              --label "$grafana_ref" || print_warning "nginx CPU summary failed (non-fatal)"
        fi
    else
        print_warning "Skipping k6+Grafana merge and per-run plots (no Grafana run directory found)"
    fi

    # Save config snapshot into the run directory
    if [ -n "$grafana_run_dir" ] && [ -d "$grafana_run_dir" ]; then
        save_run_config "$grafana_run_dir" "$test_desc" "$hpa_label" "$output_file"
    fi

    # Export the run directory so the caller (and wrapper scripts) can find it
    if [ -n "$hpa_label" ] && [ -n "$grafana_run_dir" ]; then
        export "GRAFANA_DIR_${hpa_label}=$grafana_run_dir"
    fi
}

# Function to apply HPA and verify
apply_hpa() {
    local hpa_file="$1"
    local desc="$2"
    
    print_status "Applying HPA: $desc"
    kubectl apply -f "$hpa_file" -n socialnetwork
    
    if [ $? -eq 0 ]; then
        print_success "HPA applied successfully: $desc"
    else
        print_error "Failed to apply HPA: $desc"
        exit 1
    fi
    
    # Wait a moment for HPA to be recognized
    sleep 10
    
    # Reset HPA recommendations if needed
    reset_hpa_recommendations
}

# Function to reset HPA recommendations
reset_hpa_recommendations() {
    print_status "Resetting HPA recommendations..."
    
    # Get current HPA status (only for downstream autoscaled services)
    kubectl get hpa -n socialnetwork -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name | test("compose-post-service|text-service|user-mention-service")) | .metadata.name' | while read hpa_name; do
        if [ ! -z "$hpa_name" ]; then
            print_status "Resetting recommendations for $hpa_name"
            kubectl patch hpa "$hpa_name" -n socialnetwork --type='merge' -p='{"status":{"conditions":null}}' || true
        fi
    done
    
    sleep 5
}

# Function to wait for HPA to reach baseline after applying new configuration
wait_for_hpa_to_stabilize() {
    # Baseline: downstream services at 1 replica; nginx-thrift is managed independently by its own HPA.
    print_status "Waiting for HPA to reach baseline (downstream services at 1 replica)..."
    
    # Only downstream services are checked here; nginx-thrift is not forced to a fixed replica count.
    local deployments=("compose-post-service" "text-service" "user-mention-service")
    local all_ready=false
    local max_attempts=20
    local attempt=1
    
    while [ $attempt -le $max_attempts ] && [ "$all_ready" = false ]; do
        all_ready=true
        
        for deployment in "${deployments[@]}"; do
            local current_replicas
            local desired_replicas

            current_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            desired_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            
            if [ "$current_replicas" != "1" ] || [ "$desired_replicas" != "1" ]; then
                print_status "$deployment: $current_replicas/$desired_replicas replicas (HPA moving toward 1/1 baseline)..."
                all_ready=false
            fi
        done
        
        if [ "$all_ready" = false ]; then
            print_status "Attempt $attempt/$max_attempts: Waiting for HPA to scale down replicas..."
            sleep 15
            attempt=$((attempt + 1))
        fi
    done
    
    if [ "$all_ready" = true ]; then
        print_success "HPA has driven all downstream deployments to 1 replica"
    else
        print_warning "Timeout waiting for HPA to scale down, but continuing..."
    fi
    
    print_status "Current deployment status:"
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
}

# Function to wait for deployments to return to baseline (downstream services at 1)
wait_for_pods_to_reset() {
    print_status "Waiting for deployments to return to baseline (downstream services at 1 replica)..."
    
    # Only downstream services are reset to 1; nginx-thrift is not forced to a fixed replica count
    local deployments=("compose-post-service" "text-service" "user-mention-service")
    local all_ready=false
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ] && [ "$all_ready" = false ]; do
        all_ready=true
        
        for deployment in "${deployments[@]}"; do
            local current_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            
            if [ "$current_replicas" != "1" ] || [ "$desired_replicas" != "1" ]; then
                print_status "$deployment: $current_replicas/$desired_replicas replicas (waiting for 1/1 baseline)..."
                all_ready=false
            fi
        done
        
        if [ "$all_ready" = false ]; then
            print_status "Attempt $attempt/$max_attempts: Still waiting for replicas to scale down..."
            sleep 30
            attempt=$((attempt + 1))
        fi
    done
    
    if [ "$all_ready" = true ]; then
        print_success "Downstream deployments have returned to 1 replica"
    else
        print_warning "Timeout waiting for replicas to scale down, but continuing..."
    fi
    
    print_status "Current pod status:"
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
}

# Function to force reset deployments by deleting HPA, scaling down, and restarting
force_reset_deployments() {
    print_status "=== Force Resetting Deployments for Clean State ==="
    
    # Only downstream services participate in force reset; nginx-thrift is left to its own HPA
    local deployments=("compose-post-service" "text-service" "user-mention-service")
    
    # Step 1: Delete all HPAs
    print_status "Step 1: Deleting all HPAs..."
    kubectl delete hpa -n socialnetwork --all --ignore-not-found=true
    sleep 5
    
    # Step 2: Scale downstream deployments to 1 replica
    print_status "Step 2: Scaling downstream deployments to 1 replica..."
    for deployment in "${deployments[@]}"; do
        print_status "Scaling $deployment to 1 replica..."
        kubectl scale deployment "$deployment" -n socialnetwork --replicas=1
    done
    
    # Step 3: Wait for deployments to be ready
    print_status "Step 3: Waiting for deployments to be ready..."
    for deployment in "${deployments[@]}"; do
        kubectl rollout status deployment/"$deployment" -n socialnetwork --timeout=300s
    done
    
    # Step 4: Restart all deployments
    print_status "Step 4: Restarting all deployments for clean state..."
    for deployment in "${deployments[@]}"; do
        print_status "Restarting $deployment..."
        kubectl rollout restart deployment/"$deployment" -n socialnetwork
    done
    
    # Step 5: Wait for all deployments to be ready after restart
    print_status "Step 5: Waiting for all deployments to be ready after restart..."
    for deployment in "${deployments[@]}"; do
        kubectl rollout status deployment/"$deployment" -n socialnetwork --timeout=300s
    done
    
    print_success "Force reset completed - all deployments are at 1 replica with fresh pods"
    print_status "Current deployment status:"
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
}

# Function to perform hard reset using reset_testbed.sh script
hard_reset_testbed() {
    print_status "=== Hard Reset: Calling reset_testbed.sh for Full Testbed Reset ==="
    
    # Check if reset_testbed.sh exists
    local reset_script="./reset_testbed.sh"
    if [ ! -f "$reset_script" ]; then
        print_error "reset_testbed.sh script not found at: $reset_script"
        print_error "Please ensure the script exists before using --hard-reset-testbed"
        exit 1
    fi
    
    print_status "Executing full testbed reset..."
    print_warning "This will completely tear down and rebuild the testbed"
    
    # Make script executable
    chmod +x "$reset_script"
    
    # Use the exact command specified by the user
    local reset_cmd="$reset_script --cluster-type kind --no-dns-resolution --persist-monitoring-data"
    
    print_status "Running: $reset_cmd"
    
    if eval "$reset_cmd"; then
        print_success "Hard reset completed successfully"
        print_status "Testbed has been completely rebuilt"
        
        # Wait a bit for everything to stabilize
        print_status "Waiting for testbed to stabilize after hard reset..."
        sleep 30
        
        # Verify deployments are ready
        print_status "Verifying deployments are ready..."
        kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
        
    else
        print_error "Hard reset failed"
        print_error "Please check the reset_testbed.sh script execution"
        exit 1
    fi
}

# Function to get Prometheus URL (IP-based workaround for DNS issues)
get_prometheus_url() {
    # port-forward.sh maps kube-prometheus-stack to localhost:9091
    for port in 9091 9090; do
        if curl -sS --max-time 3 "http://127.0.0.1:${port}/api/v1/query?query=up" >/dev/null 2>&1; then
            echo "http://127.0.0.1:${port}"
            return
        fi
    done

    # Try cluster IP directly
    local prom_service_ip=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$prom_service_ip" ]; then
        if curl -sS --max-time 3 "http://$prom_service_ip:9090/api/v1/query?query=up" >/dev/null 2>&1; then
            echo "http://$prom_service_ip:9090"
            return
        fi
    fi

    # Start a port-forward as last resort (use 9091 to match port-forward.sh convention)
    if ! lsof -i :9091 -sTCP:LISTEN >/dev/null 2>&1; then
        print_status "Starting temporary port-forward to Prometheus on localhost:9091"
        kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9091:9090 >/dev/null 2>&1 &
        sleep 3
    fi
    echo "http://localhost:9091"
}

# Function to check if Prometheus is accessible
check_prometheus() {
    local prom_url=$(get_prometheus_url)
    print_status "Checking Prometheus accessibility at $prom_url..."
    
    if curl -sS --max-time 3 "$prom_url/api/v1/query?query=up" >/dev/null 2>&1; then
        print_success "Prometheus is accessible at $prom_url"
        return 0
    fi
    
    print_warning "Prometheus not responding at $prom_url"
    return 1
}

# Function to install Python dependencies
install_python_dependencies() {
    print_status "Checking Python dependencies for k6 analysis scripts..."
    
    # Check if pip is available
    if ! command -v pip3 &> /dev/null; then
        print_error "pip3 not found. Please install pip3 first."
        print_error "On Ubuntu/Debian: sudo apt install python3-pip"
        print_error "On CentOS/RHEL: sudo yum install python3-pip"
        exit 1
    fi
    
    # Check if dependencies are already installed
    if python3 -c "import pandas, numpy, matplotlib" 2>/dev/null; then
        print_success "Python dependencies already installed (pandas, numpy, matplotlib)"
        return 0
    fi
    
    print_status "Installing missing Python dependencies..."
    
    # Install dependencies from requirements.txt
    if [ -f "k6/requirements.txt" ]; then
        print_status "Installing dependencies from k6/requirements.txt..."
        if pip3 install -r k6/requirements.txt --quiet; then
            print_success "Python dependencies installed successfully"
        else
            print_error "Failed to install Python dependencies"
            print_error "Please install manually: pip3 install pandas numpy matplotlib"
            exit 1
        fi
    else
        print_warning "requirements.txt not found, installing basic dependencies..."
        if pip3 install pandas numpy matplotlib --quiet; then
            print_success "Basic Python dependencies installed successfully"
        else
            print_error "Failed to install basic Python dependencies"
            exit 1
        fi
    fi
}

# Function to run command with full logging capture
run_with_logging() {
    local cmd="$1"
    local desc="$2"
    local log_file="${3:-}"
    
    print_status "Running: $desc"
    print_status "Command: $cmd"
    
    # Run command and capture both stdout and stderr, while also displaying them
    # Optionally append raw output to log_file (third argument)
    eval "$cmd" 2>&1 | while IFS= read -r line; do
        [ -n "$log_file" ] && echo "$line" >> "$log_file"
        # Highlight k6 metrics with special formatting
        if echo "$line" | grep -q "http_req_duration.*avg=\|http_reqs.*[0-9]/s\|http_req_failed.*[0-9]%\|checks.*[0-9]%"; then
            echo -e "${GREEN}[METRICS]${NC} $line"
        elif echo "$line" | grep -q "running\|paused\|stopped"; then
            echo -e "${BLUE}[STATUS]${NC} $line"
        elif echo "$line" | grep -q "✓\|✗"; then
            echo -e "${YELLOW}[CHECK]${NC} $line"
        elif echo "$line" | grep -q "TOTAL RESULTS\|HTTP\|EXECUTION\|NETWORK"; then
            echo -e "${BLUE}[SUMMARY]${NC} $line"
        else
            echo "$line"  # Regular output
        fi
    done
    
    return ${PIPESTATUS[0]}
}

# Function to run comparison
run_comparison() {
    print_status "Running comparison analysis..."

    # Build comparison output folder next to the per-HPA run folders
    local today=$(date -u +%Y-%m-%d)
    local comparison_ts=$(date -u +%H%M%SZ)
    local comparison_dir="k6/grafana/${today}/${TEST_NAME}_comparison_${comparison_ts}"
    mkdir -p "$comparison_dir"

    # Log file capturing all comparison script output
    local comparison_log="${comparison_dir}/comparison.log"
    echo "=== HPA Comparison Log ===" > "$comparison_log"
    echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$comparison_log"
    echo "Test Name: $TEST_NAME" >> "$comparison_log"
    echo "" >> "$comparison_log"

    cd k6
    
    # Derive human-readable labels from HPA YAML filenames (without path and extension)
    local label_a
    local label_b
    label_a=$(basename "$HPA1_FILE" .yaml)
    label_b=$(basename "$HPA2_FILE" .yaml)

    echo "Label A: $label_a" >> "../${comparison_log}"
    echo "Label B: $label_b" >> "../${comparison_log}"
    echo "" >> "../${comparison_log}"

    # Run standard k6 comparison with plots going into the comparison folder
    echo "========================================" >> "../${comparison_log}"
    echo "  k6 Report Comparison" >> "../${comparison_log}"
    echo "========================================" >> "../${comparison_log}"
    local comparison_cmd="python3 k6_report_comparison.py \
        --a \"reports/${TEST_NAME}_hpa1_${TIMESTAMP}.csv\" \
        --b \"reports/${TEST_NAME}_hpa2_${TIMESTAMP}.csv\" \
        --label-a \"$label_a\" \
        --label-b \"$label_b\" \
        --out \"../${comparison_dir}/comparison_result.json\" \
        --plots-dir \"../${comparison_dir}\""
    
    if run_with_logging "$comparison_cmd" "k6 report comparison analysis" "../${comparison_log}"; then
        print_success "Comparison completed successfully"
        print_status "Comparison results saved to: ${comparison_dir}/"
    else
        print_error "Comparison failed"
        exit 1
    fi
    
    cd ..

    # Generate overlay plots from unified_report.csv files
    local hpa1_unified="${GRAFANA_DIR_hpa1:-}/unified_report.csv"
    local hpa2_unified="${GRAFANA_DIR_hpa2:-}/unified_report.csv"
    if [ -f "$hpa1_unified" ] && [ -f "$hpa2_unified" ]; then
        print_status "Generating overlay comparison plots..."
        echo "" >> "$comparison_log"
        echo "========================================" >> "$comparison_log"
        echo "  Overlay Plots" >> "$comparison_log"
        echo "========================================" >> "$comparison_log"
        local overlay_cmd="python3 k6/overlay_plots.py \
          --csv-a \"$hpa1_unified\" \
          --csv-b \"$hpa2_unified\" \
          --out-dir \"$comparison_dir\" \
          --label-a \"$label_a\" \
          --label-b \"$label_b\""
        run_with_logging "$overlay_cmd" "Overlay comparison plots" "$comparison_log" || print_warning "Overlay plots failed (non-fatal)"
    else
        print_warning "Skipping overlay plots (unified_report.csv not found for both HPAs)"
    fi

    # List all run folders for this day
    print_status "Grafana runs for today:"
    find "k6/grafana/${today}/" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' 2>/dev/null || print_warning "No run folders found"
    
    # Run latency breakdown comparison (output into the comparison folder)
    print_status "Running latency breakdown comparison..."
    local latency_cmp_dir="${comparison_dir}/latency_breakdown"
    mkdir -p "$latency_cmp_dir"
    
    # Use absolute paths for CSV files (we're in project root after cd ..)
    local hpa1_csv="${PROJECT_ROOT}/${OUTPUT_DIR}/${TEST_NAME}_hpa1_${TIMESTAMP}.csv"
    local hpa2_csv="${PROJECT_ROOT}/${OUTPUT_DIR}/${TEST_NAME}_hpa2_${TIMESTAMP}.csv"
    
    # Get Prometheus URL for latency breakdown comparison
    local prom_url=$(get_prometheus_url)
    local latency_cmp_cmd="python3 ${PROJECT_ROOT}/python/compare_latency_breakdown.py \
        --k6-csv1 \"$hpa1_csv\" \
        --k6-csv2 \"$hpa2_csv\" \
        --name1 \"HPA1\" \
        --name2 \"HPA2\" \
        --bucket-sec 30 \
        --out-dir \"${PROJECT_ROOT}/$latency_cmp_dir\""
    
    # Add Prometheus URL if available
    if [ -n "$prom_url" ]; then
        if check_prometheus "$prom_url" 2>/dev/null; then
            # Exclude nginx-thrift from latency breakdown services; focus only on autoscaled internals.
            latency_cmp_cmd+=" --prom \"$prom_url\" --namespace socialnetwork --services compose-post-service text-service user-mention-service"
        fi
    fi
    
    echo "" >> "$comparison_log"
    echo "========================================" >> "$comparison_log"
    echo "  Latency Breakdown Comparison" >> "$comparison_log"
    echo "========================================" >> "$comparison_log"
    if run_with_logging "$latency_cmp_cmd" "Latency breakdown comparison" "$comparison_log"; then
        print_success "Latency breakdown comparison completed"
        print_status "Latency breakdown results saved to: $latency_cmp_dir/"
    else
        print_warning "Latency breakdown comparison failed (non-fatal)"
    fi

    print_status "Full comparison log saved to: $comparison_log"
}

# Main execution
main() {
    print_status "=== HPA Comparison Test Started ==="
    
    # Step 0: Install Python dependencies
    print_status "Step 0: Installing Python dependencies..."
    install_python_dependencies
    
    # Step 1: Apply Prometheus Adapter values
    print_status "Step 1: Applying Prometheus Adapter configuration..."
    if [ -f "prom/prometheus-adapter-values-parent-child.yaml" ]; then
        # Get Prometheus service IP to avoid DNS issues
        local prom_ip=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        if [ -n "$prom_ip" ]; then
            print_status "Using Prometheus IP: $prom_ip (avoiding DNS issues)"
            helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
                -n monitoring --create-namespace \
                --set prometheus.url=http://$prom_ip \
                --set prometheus.port=9090 \
                -f prom/prometheus-adapter-values-parent-child.yaml
        else
            print_warning "Could not get Prometheus IP, using default URL"
            helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
                -n monitoring --create-namespace \
                -f prom/prometheus-adapter-values-parent-child.yaml
        fi
        print_success "Prometheus Adapter configuration applied"
    else
        print_warning "Prometheus Adapter values file not found: prom/prometheus-adapter-values-parent-child.yaml"
        print_warning "Continuing without updating adapter configuration..."
    fi
    
    # Step 2: Apply service values (CPU requests) using server-side apply
    print_status "Step 2: Ensuring CPU requests are set for all services..."
    if apply_service_values_with_multiplier; then
        print_success "Service CPU requests applied"
    else
        print_warning "Falling back to unscaled service_values.yaml due to error applying scaled values"
        kubectl apply -f deathstar-bench/hpa/service_values.yaml -n socialnetwork --server-side --force-conflicts
    fi
    
    # Step 3: Test with first HPA configuration
    print_status "=== Testing HPA Configuration 1 ==="
    apply_hpa "$HPA1_FILE" "HPA Configuration 1"
    wait_for_hpa_to_stabilize
    print_status "=== Current replica status after first test setup==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    wait_for_stabilization
    print_status "=== HPA status before k6 test (HPA1) ==="
    kubectl get hpa -n socialnetwork
    # Use HPA1-specific timeout if set, otherwise use global K6_TIMEOUT, otherwise default to 5s
    if [ -n "${K6_TIMEOUT_HPA1:-}" ]; then
        export K6_TIMEOUT="$K6_TIMEOUT_HPA1"
    elif [ -n "${K6_TIMEOUT:-}" ]; then
        export K6_TIMEOUT="$K6_TIMEOUT"
    else
        export K6_TIMEOUT="5s"
    fi
    # Apply same logic for other variables
    if [ -n "${K6_DURATION_HPA1:-}" ]; then
        export K6_DURATION="$K6_DURATION_HPA1"
    elif [ -n "${K6_DURATION:-}" ]; then
        export K6_DURATION="$K6_DURATION"
    else
        export K6_DURATION="120s"
    fi
    if [ -n "${K6_TARGET_HPA1:-}" ]; then
        export K6_TARGET="$K6_TARGET_HPA1"
    elif [ -n "${K6_TARGET:-}" ]; then
        export K6_TARGET="$K6_TARGET"
    else
        export K6_TARGET="50"
    fi
    print_status "HPA1 Configuration: K6_TIMEOUT=$K6_TIMEOUT, K6_DURATION=$K6_DURATION, K6_TARGET=$K6_TARGET"
    run_k6_test "$HPA1_OUTPUT" "HPA Configuration 1" "hpa1"
    sleep 60s
    # Step 4: Reset deployments for clean state
    if [ "$HARD_RESET_TESTBED" = true ]; then
        print_status "Using hard reset approach (full testbed reset)"
        hard_reset_testbed
    elif [ "$FORCE_RESET_HPA" = true ]; then
        print_status "Using force reset approach for guaranteed clean state"
        force_reset_deployments
    else
        print_status "Using standard reset approach (waiting for HPA to scale down)"
        wait_for_pods_to_reset
    fi
    print_status "=== Current replica status after reset ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    
    # Step 5: Test with second HPA configuration
    print_status "=== Testing HPA Configuration 2 ==="
    apply_hpa "$HPA2_FILE" "HPA Configuration 2"
    wait_for_hpa_to_stabilize
    print_status "=== Current replica status after HPA configuration 2 applied ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    wait_for_stabilization
    print_status "=== Current replica status after second test setup ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    print_status "=== HPA status before k6 test (HPA2) ==="
    kubectl get hpa -n socialnetwork
    # Use HPA2-specific timeout if set, otherwise use global K6_TIMEOUT, otherwise default to 5s
    if [ -n "${K6_TIMEOUT_HPA2:-}" ]; then
        export K6_TIMEOUT="$K6_TIMEOUT_HPA2"
    elif [ -n "${K6_TIMEOUT:-}" ]; then
        export K6_TIMEOUT="$K6_TIMEOUT"
    else
        export K6_TIMEOUT="5s"
    fi
    # Apply same logic for other variables
    if [ -n "${K6_DURATION_HPA2:-}" ]; then
        export K6_DURATION="$K6_DURATION_HPA2"
    elif [ -n "${K6_DURATION:-}" ]; then
        export K6_DURATION="$K6_DURATION"
    else
        export K6_DURATION="120s"
    fi
    if [ -n "${K6_TARGET_HPA2:-}" ]; then
        export K6_TARGET="$K6_TARGET_HPA2"
    elif [ -n "${K6_TARGET:-}" ]; then
        export K6_TARGET="$K6_TARGET"
    else
        export K6_TARGET="50"
    fi
    print_status "HPA2 Configuration: K6_TIMEOUT=$K6_TIMEOUT, K6_DURATION=$K6_DURATION, K6_TARGET=$K6_TARGET"
    run_k6_test "$HPA2_OUTPUT" "HPA Configuration 2" "hpa2"
    
    # Step 6: Run comparison
    print_status "=== Running Comparison Analysis ==="
    run_comparison
    
    print_success "=== HPA Comparison Test Completed Successfully ==="
    print_status "=== Final replica status ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    
    # Display final metrics summary for both tests
    print_status ""
    print_status "=== Final Metrics Summary ==="
    print_status "HTTP Request Duration Metrics Comparison:"
    
    print_status "Test results:"
    print_status "  HPA1 k6 results: $HPA1_OUTPUT"
    print_status "  HPA2 k6 results: $HPA2_OUTPUT"
    print_status "  k6 comparison:   $COMPARISON_OUTPUT"
    print_status "  k6 plots:        k6/plots/"
    print_status "  Per-HPA runs:    k6/grafana/<date>/<TestName>_hpa1_*/ and hpa2_*/"
    print_status "    Each contains: grafana_master.csv, unified_report.csv, plots/"
    print_status "  Comparison:      k6/grafana/<date>/<TestName>_comparison/"
    print_status "  Latency breakdown: k6/comparison_output/"
    print_status ""
    print_status "=== Analysis Summary ==="
    print_status "[OK] Standard k6 comparison completed"
    print_status "[OK] Grafana dashboard data exported to CSV (per HPA)"
    print_status "[OK] Latency breakdown comparison completed"

    # Machine-readable output for wrapper scripts (e.g. reset_then_test.sh --average)
    echo "HPA_RUN_DIR_HPA1=${GRAFANA_DIR_hpa1:-}"
    echo "HPA_RUN_DIR_HPA2=${GRAFANA_DIR_hpa2:-}"
}

# Run main function
main "$@"
