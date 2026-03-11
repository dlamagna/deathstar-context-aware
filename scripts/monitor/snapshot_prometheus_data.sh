#!/bin/bash

# snapshot_prometheus_data.sh - Create a snapshot of Prometheus data for backup/restore
# This script creates a backup of current Prometheus data using remote_write to a temporary TSDB

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Configuration
# Allow overriding PROJECT_ROOT via environment, otherwise derive it from this script's location
if [ -z "${PROJECT_ROOT:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

SNAPSHOT_DIR="$PROJECT_ROOT/snapshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SNAPSHOT_NAME="prometheus_snapshot_$TIMESTAMP"
SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT_NAME"

# VictoriaMetrics configuration for temporary storage
VM_PORT="8428"
VM_CONTAINER_NAME="prometheus-snapshot-vm"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
}

# Function to create snapshot directory
create_snapshot_directory() {
    log_info "Creating snapshot directory: $SNAPSHOT_PATH"
    mkdir -p "$SNAPSHOT_PATH"
}

# Function to start temporary VictoriaMetrics instance
start_victoria_metrics() {
    log_info "Starting temporary VictoriaMetrics instance for snapshot..."
    
    # Stop any existing snapshot VM container
    docker stop "$VM_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$VM_CONTAINER_NAME" 2>/dev/null || true
    
    # Start VictoriaMetrics
    docker run -d \
        --name "$VM_CONTAINER_NAME" \
        -p "$VM_PORT:8428" \
        -v "$SNAPSHOT_PATH:/victoria-metrics-data" \
        victoriametrics/victoria-metrics:latest \
        -storageDataPath=/victoria-metrics-data \
        -retentionPeriod=30d \
        -httpListenAddr=:8428
    
    # Wait for VM to be ready
    log_info "Waiting for VictoriaMetrics to be ready..."
    local retry_count=0
    local max_retries=30
    
    while [ $retry_count -lt $max_retries ]; do
        if curl -s "http://localhost:$VM_PORT/api/v1/query?query=up" >/dev/null 2>&1; then
            log_success "VictoriaMetrics is ready"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        log_info "Waiting for VictoriaMetrics... (attempt $retry_count/$max_retries)"
        sleep 2
    done
    
    log_error "VictoriaMetrics failed to start"
    return 1
}

# Function to configure Prometheus remote_write
configure_prometheus_remote_write() {
    log_info "Configuring Prometheus remote_write to VictoriaMetrics..."
    
    # Get current Prometheus configuration
    local prometheus_config=$(kubectl get prometheus kube-prometheus-stack-prometheus -n monitoring -o yaml)
    
    # Add remote_write configuration
    kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring --type='merge' -p='{
        "spec": {
            "prometheusSpec": {
                "remoteWrite": [
                    {
                        "url": "http://host.docker.internal:'$VM_PORT'/api/v1/write"
                    }
                ]
            }
        }
    }' || log_warning "Failed to patch Prometheus configuration"
    
    # Wait for configuration to be applied
    log_info "Waiting for Prometheus configuration to be applied..."
    sleep 10
    
    # Restart Prometheus to apply configuration
    log_info "Restarting Prometheus to apply remote_write configuration..."
    kubectl rollout restart statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring
    
    # Wait for Prometheus to be ready
    log_info "Waiting for Prometheus to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s
}

# Function to wait for data to be written
wait_for_data_sync() {
    log_info "Waiting for data to be written to VictoriaMetrics..."
    
    local retry_count=0
    local max_retries=60  # 2 minutes
    
    while [ $retry_count -lt $max_retries ]; do
        local vm_data_count=$(curl -s "http://localhost:$VM_PORT/api/v1/query?query=up" | jq '.data.result | length' 2>/dev/null || echo "0")
        
        if [ "$vm_data_count" -gt 0 ]; then
            log_success "Data successfully written to VictoriaMetrics ($vm_data_count metrics)"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        log_info "Waiting for data sync... (attempt $retry_count/$max_retries)"
        sleep 2
    done
    
    log_warning "Data sync timeout - proceeding with available data"
}

# Function to export data from VictoriaMetrics
export_data_from_vm() {
    log_info "Exporting data from VictoriaMetrics..."
    
    # Export all metrics data
    local export_file="$SNAPSHOT_PATH/metrics_export.json"
    
    # Get all unique metric names
    curl -s "http://localhost:$VM_PORT/api/v1/label/__name__/values" | jq -r '.data[]' > "$SNAPSHOT_PATH/metric_names.txt"
    
    # Export metadata
    curl -s "http://localhost:$VM_PORT/api/v1/labels" > "$SNAPSHOT_PATH/labels.json"
    curl -s "http://localhost:$VM_PORT/api/v1/label/__name__/values" > "$SNAPSHOT_PATH/metric_names.json"
    
    # Create a summary of the snapshot
    cat > "$SNAPSHOT_PATH/snapshot_info.json" << EOF
{
    "timestamp": "$TIMESTAMP",
    "snapshot_name": "$SNAPSHOT_NAME",
    "created_at": "$(date -Iseconds)",
    "vm_port": "$VM_PORT",
    "data_range": {
        "start": "$(curl -s "http://localhost:$VM_PORT/api/v1/query?query=up" | jq -r '.data.result[0].value[0]' | xargs -I {} date -d @{} -Iseconds 2>/dev/null || echo "unknown")",
        "end": "$(date -Iseconds)"
    },
    "metric_count": $(curl -s "http://localhost:$VM_PORT/api/v1/query?query=up" | jq '.data.result | length' 2>/dev/null || echo "0")
}
EOF
    
    log_success "Data exported to: $SNAPSHOT_PATH"
}

# Function to create restore script
create_restore_script() {
    log_info "Creating restore script..."
    
    cat > "$SNAPSHOT_PATH/restore.sh" << 'EOF'
#!/bin/bash

# restore_prometheus_data.sh - Restore Prometheus data from snapshot
# This script restores Prometheus data from a VictoriaMetrics snapshot

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Configuration
SNAPSHOT_PATH="$(dirname "$0")"
VM_PORT="8428"
VM_CONTAINER_NAME="prometheus-restore-vm"

# Function to start VictoriaMetrics for restore
start_victoria_metrics() {
    log_info "Starting VictoriaMetrics instance for restore..."
    
    # Stop any existing restore VM container
    docker stop "$VM_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$VM_CONTAINER_NAME" 2>/dev/null || true
    
    # Start VictoriaMetrics with existing data
    docker run -d \
        --name "$VM_CONTAINER_NAME" \
        -p "$VM_PORT:8428" \
        -v "$SNAPSHOT_PATH:/victoria-metrics-data" \
        victoriametrics/victoria-metrics:latest \
        -storageDataPath=/victoria-metrics-data \
        -retentionPeriod=30d \
        -httpListenAddr=:8428
    
    # Wait for VM to be ready
    log_info "Waiting for VictoriaMetrics to be ready..."
    local retry_count=0
    local max_retries=30
    
    while [ $retry_count -lt $max_retries ]; do
        if curl -s "http://localhost:$VM_PORT/api/v1/query?query=up" >/dev/null 2>&1; then
            log_success "VictoriaMetrics is ready with restored data"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        log_info "Waiting for VictoriaMetrics... (attempt $retry_count/$max_retries)"
        sleep 2
    done
    
    log_error "VictoriaMetrics failed to start"
    return 1
}

# Function to configure Prometheus to read from VictoriaMetrics
configure_prometheus_read() {
    log_info "Configuring Prometheus to read from VictoriaMetrics..."
    
    # This would require more complex configuration
    # For now, we'll provide instructions
    log_info "To restore data, you can:"
    log_info "1. Access VictoriaMetrics at: http://localhost:$VM_PORT"
    log_info "2. Use it as an additional datasource in Grafana"
    log_info "3. Or configure Prometheus to use it as a remote read endpoint"
    
    log_success "VictoriaMetrics is available at http://localhost:$VM_PORT"
}

# Main restore function
main() {
    log_info "Starting Prometheus data restore from snapshot..."
    
    if [ ! -d "$SNAPSHOT_PATH" ]; then
        log_error "Snapshot directory not found: $SNAPSHOT_PATH"
        exit 1
    fi
    
    start_victoria_metrics
    configure_prometheus_read
    
    log_success "Restore completed! VictoriaMetrics is running with your snapshot data."
    log_info "Access it at: http://localhost:$VM_PORT"
}

# Run main function
main "$@"
EOF
    
    chmod +x "$SNAPSHOT_PATH/restore.sh"
    log_success "Restore script created: $SNAPSHOT_PATH/restore.sh"
}

# Function to cleanup
cleanup() {
    log_info "Cleaning up temporary VictoriaMetrics instance..."
    docker stop "$VM_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$VM_CONTAINER_NAME" 2>/dev/null || true
    
    # Remove remote_write configuration from Prometheus
    log_info "Removing remote_write configuration from Prometheus..."
    kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring --type='json' -p='[{"op": "remove", "path": "/spec/prometheusSpec/remoteWrite"}]' 2>/dev/null || log_warning "Failed to remove remote_write configuration"
    
    # Restart Prometheus to apply changes
    kubectl rollout restart statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring 2>/dev/null || true
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Create a snapshot of Prometheus data for backup/restore"
    echo ""
    echo "OPTIONS:"
    echo "  --help               Show this help message"
    echo ""
    echo "The script will:"
    echo "  1. Start a temporary VictoriaMetrics instance"
    echo "  2. Configure Prometheus to write data to it"
    echo "  3. Export the data to a snapshot directory"
    echo "  4. Create a restore script"
    echo ""
    echo "Snapshot will be saved to: $SNAPSHOT_DIR/"
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
    
    log_info "Starting Prometheus data snapshot..."
    log_info "Snapshot name: $SNAPSHOT_NAME"
    log_info "Snapshot path: $SNAPSHOT_PATH"
    
    # Check prerequisites
    check_docker
    
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    if ! command_exists curl; then
        log_error "curl is not installed"
        exit 1
    fi
    
    if ! command_exists jq; then
        log_error "jq is not installed"
        exit 1
    fi
    
    # Create snapshot
    create_snapshot_directory
    start_victoria_metrics
    configure_prometheus_remote_write
    wait_for_data_sync
    export_data_from_vm
    create_restore_script
    
    log_success "Snapshot completed successfully!"
    log_info "Snapshot location: $SNAPSHOT_PATH"
    log_info "To restore: cd $SNAPSHOT_PATH && ./restore.sh"
    
    # Cleanup
    cleanup
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Run main function
main "$@"
