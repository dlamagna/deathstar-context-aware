#!/bin/bash

# HPA Comparison Test Script
# Automates the process of comparing two HPA configurations using k6 load testing
# Usage: ./hpa_comparison_test.sh <hpa1.yaml> <hpa2.yaml> <test_name>

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <hpa1.yaml> <hpa2.yaml> <test_name> [--force-reset]"
    echo ""
    echo "Arguments:"
    echo "  hpa1.yaml    - First HPA configuration file"
    echo "  hpa2.yaml    - Second HPA configuration file"
    echo "  test_name    - Name for this test run (used in output files)"
    echo ""
    echo "Options:"
    echo "  --force-reset - Use aggressive reset (delete HPA, scale down, restart) between tests"
    echo "  --help        - Show this help message"
    echo ""
    echo "Environment Variables (optional):"
    echo "  K6_DURATION     - k6 test duration (default: 120s)"
    echo "  K6_TARGET       - k6 target VUs (default: 50)"
    echo "  K6_TIMEOUT      - k6 request timeout (default: 5s)"
    echo "  K6_TIMEOUT_HPA1 - k6 timeout for first HPA test (default: 5s)"
    echo "  K6_TIMEOUT_HPA2 - k6 timeout for second HPA test (default: 5s)"
    echo ""
    echo "Example:"
    echo "  $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml parity_test"
    echo ""
    echo "Example with force reset for guaranteed clean state:"
    echo "  $0 --force-reset deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml clean_test"
    echo ""
    echo "Example with custom parameters:"
    echo "  K6_DURATION=300s K6_TARGET=100 K6_TIMEOUT=10s $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml long_test"
    echo ""
    echo "Example with different timeouts per HPA:"
    echo "  K6_TIMEOUT_HPA1=5s K6_TIMEOUT_HPA2=10s $0 deathstar-bench/hpa/default_hpa.yaml deathstar-bench/hpa/context_aware_hpa_values.yaml timeout_test"
    exit 1
}

# Initialize variables
FORCE_RESET=false

# Check for help flag
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_usage
fi

# Check for force-reset flag
if [ "$1" = "--force-reset" ]; then
    FORCE_RESET=true
    shift  # Remove --force-reset from arguments
fi

# Check arguments (after potential shift)
if [ $# -ne 3 ]; then
    print_error "Invalid number of arguments"
    show_usage
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
    print_status "Test duration: $K6_DURATION"
    print_status "Target VUs: $K6_TARGET"
    print_status "Request timeout: $K6_TIMEOUT"
    
    # Run k6
    k6 run k6/k6_loader.js --out csv="$output_file"
    
    if [ $? -eq 0 ]; then
        print_success "k6 test completed successfully: $test_desc"
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
    
    # Show HPA status
    print_status "Current HPA status:"
    kubectl get hpa -n socialnetwork
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

# Function to run comparison
run_comparison() {
    print_status "Running comparison analysis..."
    cd k6
    python3 k6_report_comparison.py \
        --a "reports/${TEST_NAME}_hpa1.csv" \
        --b "reports/${TEST_NAME}_hpa2.csv" \
        --out "reports/${TEST_NAME}_comparison.json"
    
    if [ $? -eq 0 ]; then
        print_success "Comparison completed successfully"
        print_status "Results saved to: k6/reports/${TEST_NAME}_comparison.json"
        print_status "Plots saved to: k6/plots/"
    else
        print_error "Comparison failed"
        exit 1
    fi
    cd ..
}

# Main execution
main() {
    print_status "=== HPA Comparison Test Started ==="
    
    # Step 1: Apply service values (CPU requests)
    print_status "Step 1: Ensuring CPU requests are set for all services..."
    kubectl apply -f deathstar-bench/hpa/service_values.yaml -n socialnetwork
    print_success "Service CPU requests applied"
    
    # Step 2: Test with first HPA configuration
    print_status "=== Testing HPA Configuration 1 ==="
    apply_hpa "$HPA1_FILE" "HPA Configuration 1"
    wait_for_hpa_to_stabilize
    print_status "=== Current replica status after first test setup==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    wait_for_stabilization
    export K6_TIMEOUT="${K6_TIMEOUT_HPA1:-5s}"
    run_k6_test "$HPA1_OUTPUT" "HPA Configuration 1"
    
    # Step 3: Reset deployments for clean state
    if [ "$FORCE_RESET" = true ]; then
        print_status "Using force reset approach for guaranteed clean state"
        force_reset_deployments
    else
        print_status "Using standard reset approach (waiting for HPA to scale down)"
        wait_for_pods_to_reset
    fi
    print_status "=== Current replica status after reset ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    
    # Step 4: Test with second HPA configuration
    print_status "=== Testing HPA Configuration 2 ==="
    apply_hpa "$HPA2_FILE" "HPA Configuration 2"
    wait_for_hpa_to_stabilize
    print_status "=== Current replica status after HPA configuration 2 applied ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    wait_for_stabilization
    print_status "=== Current replica status after second test setup ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    export K6_TIMEOUT="${K6_TIMEOUT_HPA2:-5s}"
    run_k6_test "$HPA2_OUTPUT" "HPA Configuration 2"
    
    # Step 5: Run comparison
    print_status "=== Running Comparison Analysis ==="
    run_comparison
    
    print_success "=== HPA Comparison Test Completed Successfully ==="
    print_status "=== Final replica status ==="
    kubectl get deploy -n socialnetwork | grep -E "(nginx-thrift|compose-post-service|text-service|user-mention-service)"
    print_status "Test results:"
    print_status "  HPA1 results: $HPA1_OUTPUT"
    print_status "  HPA2 results: $HPA2_OUTPUT"
    print_status "  Comparison: $COMPARISON_OUTPUT"
    print_status "  Plots: k6/plots/"
}

# Run main function
main "$@"
