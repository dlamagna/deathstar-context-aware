#!/bin/bash

# test_snapshot.sh - Test Prometheus snapshot functionality

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
# Allow overriding PROJECT_ROOT via environment, otherwise derive it from this script's location
if [ -z "${PROJECT_ROOT:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Function to check cluster status
check_cluster_status() {
    log_info "Checking cluster status..."
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cluster is not accessible"
        return 1
    fi
    
    log_success "Cluster is accessible"
    
    # Check monitoring namespace
    if ! kubectl get namespace monitoring >/dev/null 2>&1; then
        log_warning "Monitoring namespace does not exist"
        return 1
    fi
    
    log_success "Monitoring namespace exists"
    
    # Check Prometheus pod
    if ! kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 >/dev/null 2>&1; then
        log_warning "Prometheus pod not found"
        return 1
    fi
    
    log_success "Prometheus pod exists"
    
    # Check if Prometheus is ready
    if ! kubectl wait --for=condition=ready pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 --timeout=30s >/dev/null 2>&1; then
        log_warning "Prometheus pod not ready"
        return 1
    fi
    
    log_success "Prometheus pod is ready"
    
    # Check Prometheus API
    if ! kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- wget -qO- 'http://localhost:9090/api/v1/query?query=up' >/dev/null 2>&1; then
        log_warning "Prometheus API not accessible"
        return 1
    fi
    
    log_success "Prometheus API is accessible"
    return 0
}

# Function to test snapshot creation
test_snapshot_creation() {
    log_info "Testing snapshot creation..."
    
    local snapshot_dir="$PROJECT_ROOT/snapshots"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local snapshot_name="test_snapshot_$timestamp"
    local snapshot_path="$snapshot_dir/$snapshot_name"
    
    # Create snapshot directory
    mkdir -p "$snapshot_path"
    
    # Create snapshot using Prometheus snapshot API
    log_info "Creating snapshot via Prometheus API..."
    local snapshot_response=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- wget -qO- 'http://localhost:9090/api/v1/admin/tsdb/snapshot' 2>/dev/null || echo "")
    
    if [ -n "$snapshot_response" ]; then
        local snapshot_name_from_api=$(echo "$snapshot_response" | jq -r '.data.name' 2>/dev/null || echo "")
        if [ -n "$snapshot_name_from_api" ] && [ "$snapshot_name_from_api" != "null" ]; then
            log_success "Snapshot created: $snapshot_name_from_api"
            
            # Copy snapshot data from Prometheus pod
            log_info "Copying snapshot data..."
            kubectl cp "monitoring/prometheus-kube-prometheus-stack-prometheus-0:/prometheus/snapshots/$snapshot_name_from_api" "$snapshot_path/" 2>/dev/null || log_warning "Failed to copy snapshot data"
            
            # Create snapshot info file
            cat > "$snapshot_path/snapshot_info.json" << EOF
{
    "timestamp": "$timestamp",
    "snapshot_name": "$snapshot_name",
    "prometheus_snapshot_name": "$snapshot_name_from_api",
    "created_at": "$(date -Iseconds)",
    "test_mode": true
}
EOF
            
            log_success "Test snapshot completed: $snapshot_path"
            log_info "Snapshot contents:"
            ls -la "$snapshot_path/"
            
            return 0
        else
            log_error "Failed to create snapshot via API"
            rm -rf "$snapshot_path"
            return 1
        fi
    else
        log_error "Failed to create snapshot - Prometheus API not accessible"
        rm -rf "$snapshot_path"
        return 1
    fi
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Test Prometheus snapshot functionality"
    echo ""
    echo "OPTIONS:"
    echo "  --help               Show this help message"
    echo ""
}

# Main function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    log_info "Starting Prometheus snapshot test..."
    
    # Check cluster status
    if ! check_cluster_status; then
        log_error "Cluster status check failed - cannot proceed with snapshot test"
        exit 1
    fi
    
    # Test snapshot creation
    if test_snapshot_creation; then
        log_success "Snapshot test completed successfully!"
        log_info "You can now test the full reset script with --persist-monitoring-data"
    else
        log_error "Snapshot test failed"
        exit 1
    fi
}

# Run main function
main "$@"



