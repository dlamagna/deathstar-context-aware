#!/bin/bash

# HPA Comparison Test Script
# Automates the process of comparing two HPA configurations using k6 load testing
# Usage: ./hpa_comparison_test.sh <hpa1.yaml> <hpa2.yaml> <test_name>
#
# Enhanced Logging Features:
# - All script output is automatically logged to logs/hpa_comparison_YYYYMMDD_HHMMSS.log
# - Python subprocess output (enhanced_report.py, k6_report_comparison.py, hpa_metrics_analyzer.py) 
#   is captured and logged using the run_with_logging() function
# - k6 test output is also captured and logged
# - Cluster analysis output is captured and logged

set -e  # Exit on any error

# Logging to file (stream live to logs/ via tee)
# All script output and Python subprocess output will be captured in the log file
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hpa_comparison_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

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
    echo "  K6_DURATION     - k6 test duration (default: 120s)"
    echo "  K6_TARGET       - k6 target VUs (default: 50)"
    echo "  K6_TIMEOUT      - k6 request timeout (default: 5s)"
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

# Set output file names
OUTPUT_DIR="k6/reports"
HPA1_OUTPUT="${OUTPUT_DIR}/${TEST_NAME}_hpa1.csv"
HPA2_OUTPUT="${OUTPUT_DIR}/${TEST_NAME}_hpa2.csv"
COMPARISON_OUTPUT="${OUTPUT_DIR}/${TEST_NAME}_comparison.json"

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
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_status "Waiting for $deployment_name to be ready (attempt $attempt/$max_attempts)..."
        
        if kubectl wait --for=condition=ready pod -l app="$deployment_name" -n socialnetwork --timeout=60s; then
            print_success "$deployment_name is ready"
            return 0
        else
            print_warning "$deployment_name not ready, attempt $attempt failed"
            
            # Check pod status for debugging
            print_status "Pod status for $deployment_name:"
            kubectl get pods -n socialnetwork -l app="$deployment_name"
            
            # Check if pods are in error state
            local error_pods=$(kubectl get pods -n socialnetwork -l app="$deployment_name" --field-selector=status.phase!=Running --no-headers | wc -l)
            if [ $error_pods -gt 0 ]; then
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
    local warmup_target=$((target * 30 / 100))  # 30% of target for warmup
    local cooldown_target=1
    
    print_status "Stage 1 (Warmup):"
    print_status "  Duration: 1m"
    print_status "  Target VUs: $warmup_target"
    print_status ""
    print_status "Stage 2 (Main Load):"
    print_status "  Duration: $duration"
    print_status "  Target VUs: $target"
    print_status ""
    print_status "Stage 3 (Cooldown):"
    print_status "  Duration: 1m"
    print_status "  Target VUs: $cooldown_target"
    print_status ""
    print_status "Maximum VUs allocated: $target"
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
    print_status "Total test duration: ~${total_duration}s (including warmup and cooldown)"
    print_status "=========================================="
}

# Function to run k6 test
run_k6_test() {
    local output_file="$1"
    local test_desc="$2"
    
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
    
    # Run k6 with silent mode and redirect stderr to log file only
    # This suppresses progress output and captures error messages to the log file
    # while still showing the final summary (stdout) on the terminal
    local k6_cmd="k6 run -q k6/k6_loader.js --out csv=\"$output_file\" 2> \"$k6_log_file\""
    
    print_status "k6 warnings and errors will be logged to: $k6_log_file"
    
    # print_status "=== Starting k6 Load Test with Real-time Metrics ==="
    # print_status "Key metrics to watch:"
    # print_status "  - http_req_duration: Request duration statistics (avg, min, max, percentiles)"
    # print_status "  - http_reqs: Total requests per second"
    # print_status "  - http_req_failed: Failed request percentage"
    # print_status "  - checks: Check pass/fail rate"
    # print_status "=========================================="
    
    if run_with_logging "$k6_cmd" "k6 load test: $test_desc"; then
        print_success "k6 test completed successfully: $test_desc"
        print_status "k6 errors/warnings saved to: $k6_log_file"

    else
        print_error "k6 test failed: $test_desc"
        exit 1
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
    
    # Get current HPA status
    kubectl get hpa -n socialnetwork -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name | test("nginx-thrift|compose-post-service|text-service|user-mention-service")) | .metadata.name' | while read hpa_name; do
        if [ ! -z "$hpa_name" ]; then
            print_status "Resetting recommendations for $hpa_name"
            kubectl patch hpa "$hpa_name" -n socialnetwork --type='merge' -p='{"status":{"conditions":null}}' || true
        fi
    done
    
    sleep 5
}

# Function to wait for HPA to scale down replicas after applying new configuration
wait_for_hpa_to_stabilize() {
    print_status "Waiting for HPA to scale down replicas to baseline (1 replica each)..."
    
    local deployments=("nginx-thrift" "compose-post-service" "text-service" "user-mention-service")
    local all_ready=false
    local max_attempts=20
    local attempt=1
    
    while [ $attempt -le $max_attempts ] && [ "$all_ready" = false ]; do
        all_ready=true
        
        for deployment in "${deployments[@]}"; do
            local current_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            
            if [ "$current_replicas" != "1" ] || [ "$desired_replicas" != "1" ]; then
                print_status "$deployment: $current_replicas/$desired_replicas replicas (HPA scaling down to 1/1)..."
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
        print_success "HPA has scaled all deployments down to 1 replica"
    else
        print_warning "Timeout waiting for HPA to scale down, but continuing..."
    fi
    
    print_status "Current deployment status:"
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
}

# Function to wait for deployments to scale down to 1 replica
wait_for_pods_to_reset() {
    print_status "Waiting for all deployments to scale down to 1 replica..."
    
    local deployments=("nginx-thrift" "compose-post-service" "text-service" "user-mention-service")
    local all_ready=false
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ] && [ "$all_ready" = false ]; do
        all_ready=true
        
        for deployment in "${deployments[@]}"; do
            local current_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deploy "$deployment" -n socialnetwork -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            
            if [ "$current_replicas" != "1" ] || [ "$desired_replicas" != "1" ]; then
                print_status "$deployment: $current_replicas/$desired_replicas replicas (waiting for 1/1)..."
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
        print_success "All deployments have scaled down to 1 replica"
    else
        print_warning "Timeout waiting for replicas to scale down, but continuing..."
    fi
    
    print_status "Current pod status:"
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
}

# Function to force reset deployments by deleting HPA, scaling down, and restarting
force_reset_deployments() {
    print_status "=== Force Resetting Deployments for Clean State ==="
    
    local deployments=("nginx-thrift" "compose-post-service" "text-service" "user-mention-service")
    
    # Step 1: Delete all HPAs
    print_status "Step 1: Deleting all HPAs..."
    kubectl delete hpa -n socialnetwork --all --ignore-not-found=true
    sleep 5
    
    # Step 2: Scale down all deployments to 1 replica
    print_status "Step 2: Scaling down all deployments to 1 replica..."
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
    local prom_service_ip=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$prom_service_ip" ]; then
        echo "http://$prom_service_ip:9090"
    else
        echo "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    fi
}

# Function to check if Prometheus is accessible
check_prometheus() {
    local prom_url=$(get_prometheus_url)
    print_status "Checking Prometheus accessibility at $prom_url..."
    
    if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running; then
        print_success "Prometheus pod is running"
        # Test Prometheus API access from existing pod (workaround for DNS issues)
        if kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- wget -qO- "$prom_url/api/v1/query?query=up" >/dev/null 2>&1; then
            print_success "Prometheus API is accessible"
            return 0
        else
            print_warning "Prometheus API not accessible from within cluster"
            return 1
        fi
    else
        print_warning "Prometheus pod not found or not running"
        return 1
    fi
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
    
    print_status "Running: $desc"
    print_status "Command: $cmd"
    
    # Run command and capture both stdout and stderr, while also displaying them
    # Enhanced to highlight k6 metrics
    eval "$cmd" 2>&1 | while IFS= read -r line; do
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

# Function to generate enhanced reports with Prometheus metrics
generate_enhanced_reports() {
    local prom_url=$(get_prometheus_url)
    local services="nginx-thrift compose-post-service text-service user-mention-service"
    
    print_status "Generating enhanced reports with HPA scaling metrics..."
    print_status "Using Prometheus URL: $prom_url"
    
    # Check if Prometheus is available
    if ! check_prometheus; then
        print_warning "Prometheus not available - skipping enhanced reports"
        print_status "Enhanced reports will be generated with basic k6 metrics only"
        return 1
    fi
    
    # Generate enhanced report for HPA1
    print_status "Generating enhanced report for HPA1..."
    local cmd1="python3 enhanced_report.py \
        --k6-csv \"reports/${TEST_NAME}_hpa1.csv\" \
        --prom \"$prom_url\" \
        --namespace socialnetwork \
        --services $services \
        --bucket-sec 30 \
        --out \"reports/enhanced/${TEST_NAME}_hpa1_enhanced.csv\""
    
    if run_with_logging "$cmd1" "Enhanced report generation for HPA1"; then
        print_success "Enhanced report for HPA1 generated"
    else
        print_warning "Failed to generate enhanced report for HPA1"
    fi
    
    # Generate enhanced report for HPA2
    print_status "Generating enhanced report for HPA2..."
    local cmd2="python3 enhanced_report.py \
        --k6-csv \"reports/${TEST_NAME}_hpa2.csv\" \
        --prom \"$prom_url\" \
        --namespace socialnetwork \
        --services $services \
        --bucket-sec 30 \
        --out \"reports/enhanced/${TEST_NAME}_hpa2_enhanced.csv\""
    
    if run_with_logging "$cmd2" "Enhanced report generation for HPA2"; then
        print_success "Enhanced report for HPA2 generated"
    else
        print_warning "Failed to generate enhanced report for HPA2"
    fi
    
    return 0
}

# Function to run cluster HPA analysis
run_cluster_hpa_analysis() {
    print_status "Running cluster HPA analysis..."
    
    # Note: This function is called from within run_comparison() which has cd'd into k6 directory
    # So we need to get back to the parent directory to reference the file with k6/ prefix
    # Create ConfigMap with the cluster analyzer script (using absolute path or relative from project root)
    kubectl create configmap cluster-hpa-analyzer --from-file=cluster_hpa_analyzer.py -n socialnetwork --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    
    print_status "Running HPA metrics analysis inside cluster..."
    
    # Run the cluster analyzer inside the cluster
    local cluster_cmd="kubectl run cluster-hpa-analysis --image=python:3.9-slim --rm -i --restart=Never --overrides='
{
  \"spec\": {
    \"containers\": [
      {
        \"name\": \"cluster-hpa-analysis\",
        \"image\": \"python:3.9-slim\",
        \"command\": [\"/bin/bash\", \"-c\"],
        \"args\": [
          \"pip install pandas numpy urllib3 --quiet && python3 /tmp/cluster_hpa_analyzer.py --debug\"
        ],
        \"volumeMounts\": [
          {
            \"name\": \"analyzer-script\",
            \"mountPath\": \"/tmp\"
          }
        ]
      }
    ],
    \"volumes\": [
      {
        \"name\": \"analyzer-script\",
        \"configMap\": {
          \"name\": \"cluster-hpa-analyzer\"
        }
      }
    ]
  }
}'"
    
    if run_with_logging "$cluster_cmd" "Cluster HPA analysis"; then
        print_success "Cluster HPA analysis completed"
    else
        print_warning "Cluster HPA analysis failed"
    fi
    
    # Clean up ConfigMap
    kubectl delete configmap cluster-hpa-analyzer -n socialnetwork >/dev/null 2>&1
}

# Function to analyze HPA scaling behavior
analyze_hpa_scaling() {
    print_status "Analyzing HPA scaling behavior..."
    
    # Note: This function is called from within run_comparison() which has cd'd into k6 directory
    # So we use relative paths from the k6 directory
    local enhanced_hpa1="reports/enhanced/${TEST_NAME}_hpa1_enhanced.csv"
    local enhanced_hpa2="reports/enhanced/${TEST_NAME}_hpa2_enhanced.csv"
    
    # Check if enhanced reports exist
    if [ ! -f "$enhanced_hpa1" ] || [ ! -f "$enhanced_hpa2" ]; then
        print_warning "Enhanced reports not available - skipping HPA scaling analysis"
        print_status "Looking for files: $enhanced_hpa1 and $enhanced_hpa2"
        print_status "Current directory: $(pwd)"
        ls -la reports/enhanced/ 2>/dev/null || print_warning "Enhanced reports directory does not exist"
        return 1
    fi
    
    # Run cluster HPA analysis first
    run_cluster_hpa_analysis
    
    # Run HPA scaling analysis using the dedicated Python script
    # Note: We're in the k6 directory at this point, so use relative path
    if [ -f "hpa_metrics_analyzer.py" ]; then
        local prom_url=$(get_prometheus_url)
        local hpa_analysis_cmd="python3 hpa_metrics_analyzer.py \
            --hpa1 \"$enhanced_hpa1\" \
            --hpa2 \"$enhanced_hpa2\" \
            --prom \"$prom_url\" \
            --namespace \"socialnetwork\" \
            --services \"nginx-thrift\" \"compose-post-service\" \"text-service\" \"user-mention-service\""
        
        if run_with_logging "$hpa_analysis_cmd" "HPA metrics analysis"; then
            print_success "HPA scaling analysis completed"
        else
            print_warning "HPA scaling analysis failed"
        fi
    else
        print_warning "HPA metrics analyzer script not found - skipping detailed analysis"
    fi
}

# Function to run comparison
run_comparison() {
    print_status "Running comparison analysis..."
    cd k6
    
    # Create enhanced reports directory
    mkdir -p reports/enhanced
    
    # Generate enhanced reports with HPA metrics
    generate_enhanced_reports
    
    # Run standard k6 comparison
    local comparison_cmd="python3 k6_report_comparison.py \
        --a \"reports/${TEST_NAME}_hpa1.csv\" \
        --b \"reports/${TEST_NAME}_hpa2.csv\" \
        --out \"reports/${TEST_NAME}_comparison.json\""
    
    if run_with_logging "$comparison_cmd" "k6 report comparison analysis"; then
        print_success "Comparison completed successfully"
        print_status "Results saved to: k6/reports/${TEST_NAME}_comparison.json"
        print_status "Plots saved to: k6/plots/"
    else
        print_error "Comparison failed"
        exit 1
    fi
    
    # Run HPA scaling analysis
    analyze_hpa_scaling
    
    cd ..
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
    kubectl apply -f deathstar-bench/hpa/service_values.yaml -n socialnetwork --server-side --force-conflicts
    print_success "Service CPU requests applied"
    
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
    run_k6_test "$HPA1_OUTPUT" "HPA Configuration 1"
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
    run_k6_test "$HPA2_OUTPUT" "HPA Configuration 2"
    
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
    print_status "  HPA1 results: $HPA1_OUTPUT"
    print_status "  HPA2 results: $HPA2_OUTPUT"
    print_status "  Comparison: $COMPARISON_OUTPUT"
    print_status "  Plots: k6/plots/"
    print_status "  Enhanced reports: k6/reports/enhanced/"
    print_status ""
    print_status "=== Analysis Summary ==="
    print_status "[OK] Standard k6 comparison completed"
    print_status "[OK] Enhanced reports with HPA metrics generated (if Prometheus available)"
    print_status "[OK] HPA scaling behavior analysis completed"
    print_status "[OK] HTTP request duration metrics displayed on screen"
    print_status ""
    print_status "To view detailed HPA scaling analysis, check the enhanced reports in:"
    print_status "  k6/reports/enhanced/${TEST_NAME}_hpa1_enhanced.csv"
    print_status "  k6/reports/enhanced/${TEST_NAME}_hpa2_enhanced.csv"
}

# Run main function
main "$@"
