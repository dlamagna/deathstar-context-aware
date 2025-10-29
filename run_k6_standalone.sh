#!/bin/bash

# Standalone k6 Load Testing Script
# This script sets up HPA configuration, Prometheus Adapter, service values, and runs k6 tests
# Usage: ./run_k6_standalone.sh <hpa.yaml> [output_file]

set -e

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
    echo "Usage: $0 <hpa.yaml> [output_file]"
    echo ""
    echo "Arguments:"
    echo "  hpa.yaml     - HPA configuration file to apply"
    echo "  output_file  - Optional output file path (default: k6/reports/standalone_test_TIMESTAMP.csv)"
    echo ""
    echo "Options:"
    echo "  --help       - Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  K6_DURATION  - k6 test duration (default: 120s)"
    echo "  K6_TARGET    - k6 target VUs (default: 50)"
    echo "  K6_TIMEOUT   - k6 request timeout (default: 5s)"
    echo "  K6_OUTPUT    - Output file path"
    echo ""
    echo "Example:"
    echo "  $0 deathstar-bench/hpa/default_hpa.yaml"
    echo ""
    echo "Example with custom output:"
    echo "  $0 deathstar-bench/hpa/default_hpa.yaml k6/reports/my_test.csv"
    echo ""
    echo "Example with custom parameters:"
    echo "  K6_DURATION=300s K6_TARGET=100 $0 deathstar-bench/hpa/default_hpa.yaml"
    exit 1
}

echo "=========================================="
echo "Standalone k6 Load Testing Script"
echo "=========================================="

# Parse command line arguments
HPA_FILE=""
OUTPUT_FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_usage
            ;;
        *)
            if [ -z "$HPA_FILE" ]; then
                HPA_FILE="$1"
            else
                OUTPUT_FILE_OVERRIDE="$1"
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$HPA_FILE" ]; then
    print_error "HPA file is required"
    show_usage
fi

# Validate HPA file exists
if [ ! -f "$HPA_FILE" ]; then
    print_error "HPA file not found: $HPA_FILE"
    exit 1
fi

# Set up log directory
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"

# Function to wait for deployments to stabilize
wait_for_stabilization() {
    print_status "Waiting for deployments to stabilize..."
    kubectl rollout restart deploy -n socialnetwork nginx-thrift compose-post-service text-service user-mention-service
    sleep 30
    print_status "Deployments restarted, waiting for pods to be ready..."
    
    # Wait for deployments to be ready
    local deployments=("nginx-thrift" "compose-post-service" "text-service" "user-mention-service")
    for deployment in "${deployments[@]}"; do
        print_status "Waiting for $deployment to be ready..."
        if kubectl wait --for=condition=ready pod -l app="$deployment" -n socialnetwork --timeout=120s; then
            print_success "$deployment is ready"
        else
            print_warning "$deployment not ready, continuing..."
        fi
    done
    
    print_success "All deployments are ready"
    sleep 30
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
    
    # Show HPA status
    print_status "Current HPA status:"
    kubectl get hpa -n socialnetwork
}

# Function to wait for HPA to stabilize
wait_for_hpa_to_stabilize() {
    print_status "Waiting for HPA to stabilize and scale deployments to baseline (1 replica each)..."
    
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

# Function to get NGINX service endpoint
get_nginx_endpoint() {
    local NODE_PORT=$(kubectl get svc nginx-thrift -n socialnetwork -o jsonpath='{.spec.ports[0].nodePort}')
    local NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    
    if [ -z "$NODE_PORT" ] || [ -z "$NODE_IP" ]; then
        print_error "Could not determine NGINX endpoint"
        print_error "NODE_PORT: $NODE_PORT"
        print_error "NODE_IP: $NODE_IP"
        exit 1
    fi
    
    echo "$NODE_IP:$NODE_PORT"
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

# Main execution
print_status "Starting Standalone k6 Load Testing"
print_status "HPA file: $HPA_FILE"

# Step 1: Apply Prometheus Adapter configuration
print_status "Step 1: Applying Prometheus Adapter configuration..."
if [ -f "prom/prometheus-adapter-values-parent-child.yaml" ]; then
    # Get Prometheus service IP to avoid DNS issues
    prom_ip=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
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
if [ -f "deathstar-bench/hpa/service_values.yaml" ]; then
    kubectl apply -f deathstar-bench/hpa/service_values.yaml -n socialnetwork --server-side --force-conflicts
    print_success "Service CPU requests applied"
else
    print_warning "Service values file not found: deathstar-bench/hpa/service_values.yaml"
    print_warning "Continuing without applying service values..."
fi

# Step 3: Apply HPA configuration
print_status "Step 3: Applying HPA configuration..."
apply_hpa "$HPA_FILE" "Standalone HPA Configuration"

# Step 4: Wait for HPA to stabilize
print_status "Step 4: Waiting for HPA to stabilize..."
wait_for_hpa_to_stabilize

# Step 5: Wait for deployments to stabilize
print_status "Step 5: Restarting deployments and waiting for them to stabilize..."
wait_for_stabilization

# Step 6: Get NGINX endpoint and prepare for k6 test
print_status "Step 6: Getting NGINX service endpoint..."
NGINX_ENDPOINT=$(get_nginx_endpoint)
print_success "NGINX endpoint: $NGINX_ENDPOINT"

# Step 7: Check pod status
print_status "Step 7: Checking pod status..."
kubectl get pods -n socialnetwork | grep -E "(nginx-thrift|compose-post|text-service|user-mention)"

# Step 8: Set k6 environment variables
export NGINX_HOST="$NGINX_ENDPOINT"
export K6_DURATION="${K6_DURATION:-120s}"
export K6_TARGET="${K6_TARGET:-50}"
export K6_TIMEOUT="${K6_TIMEOUT:-5s}"

print_status ""
print_status "=== k6 Test Configuration ==="
print_status "NGINX endpoint: $NGINX_HOST"
print_status "Test duration: $K6_DURATION"
print_status "Target VUs: $K6_TARGET"
print_status "Request timeout: $K6_TIMEOUT"
print_status ""

# Step 9: Create reports directory and determine output file
mkdir -p k6/reports
OUTPUT_FILE="${K6_OUTPUT:-${OUTPUT_FILE_OVERRIDE:-k6/reports/standalone_test_$(date +%Y%m%d_%H%M%S).csv}}"
print_status "Output file: $OUTPUT_FILE"
print_status ""

# Step 10: Print k6 stage information
print_k6_stages

# Step 11: Run k6 test
print_status ""
print_status "=========================================="
print_status "Starting k6 load test..."
print_status "=========================================="

# Create log file for k6 warnings/errors (messages starting with "time=")
K6_LOG_FILE="$LOG_DIR/k6_test_$(date +%Y%m%d_%H%M%S)_$$.log"
print_status "k6 warnings and errors will be logged to: $K6_LOG_FILE"

# Log the effective k6 timeout that will be used in this run
print_status "k6 request timeout for this run: ${K6_TIMEOUT}"

# Run k6 with silent mode and redirect stderr to log file only
# This suppresses progress output and captures error messages to the log file
# while still showing the final summary (stdout) on the terminal
if k6 run -q k6/k6_loader.js --out csv="$OUTPUT_FILE" 2> "$K6_LOG_FILE"; then
    print_success "k6 test completed successfully"
    print_status "k6 errors/warnings saved to: $K6_LOG_FILE"
else
    print_error "k6 test failed"
    print_error "k6 errors saved to: $K6_LOG_FILE"
    exit 1
fi

print_status ""
print_status "=========================================="
print_status "Test completed!"
print_status "Results saved to: $OUTPUT_FILE"
print_status "=========================================="