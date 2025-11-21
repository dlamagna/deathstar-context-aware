#!/bin/bash

# fix_grafana_datasource.sh - Quick fix for Grafana datasource configuration
# This script configures the Prometheus datasource and updates the dashboard

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

# Configuration (portable)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Optional override via env; otherwise use server public IP if set in reset_testbed.sh convention
PUBLIC_SERVER_IP="${PUBLIC_SERVER_IP:-}" # allow caller to export, else auto-detect below

log_info "Project root: $PROJECT_ROOT"

log_info "Starting Grafana datasource fix..."

# Get Grafana admin credentials
log_info "Getting Grafana admin credentials..."
admin_password=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "$admin_password" ]; then
    log_error "Could not get Grafana admin password"
    exit 1
fi

log_success "Got Grafana admin password"

# Determine cluster type if possible (kind or minikube)
CLUSTER_TYPE="${CLUSTER_TYPE:-}"
if [ -z "$CLUSTER_TYPE" ]; then
    if kubectl config current-context 2>/dev/null | grep -q '^kind-'; then
        CLUSTER_TYPE="kind"
    elif kubectl config current-context 2>/dev/null | grep -q '^minikube$'; then
        CLUSTER_TYPE="minikube"
    else
        CLUSTER_TYPE="unknown"
    fi
fi

# Get Grafana service details
grafana_port=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30900")

grafana_ip="localhost"
if [ "$CLUSTER_TYPE" = "minikube" ]; then
    grafana_ip=$(minikube ip 2>/dev/null || echo "localhost")
elif [ -n "$PUBLIC_SERVER_IP" ]; then
    grafana_ip="$PUBLIC_SERVER_IP"
fi

log_info "Grafana endpoint: http://$grafana_ip:$grafana_port"

# Wait for Grafana to be ready
log_info "Waiting for Grafana to be ready..."
retry_count=0
max_retries=30

while [ $retry_count -lt $max_retries ]; do
    if curl -s -u "admin:$admin_password" "http://$grafana_ip:$grafana_port/api/health" >/dev/null 2>&1; then
        log_success "Grafana is ready"
        break
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
        log_info "Waiting for Grafana... (attempt $retry_count/$max_retries)"
        sleep 5
    fi
done

if [ $retry_count -eq $max_retries ]; then
    log_error "Grafana not ready after $max_retries attempts"
    exit 1
fi

# Check if Prometheus datasource already exists
log_info "Checking for existing Prometheus datasource..."
existing_datasource=$(curl -s -u "admin:$admin_password" "http://$grafana_ip:$grafana_port/api/datasources" 2>/dev/null | jq -r '.[] | select(.type=="prometheus") | .uid' 2>/dev/null || echo "")

datasource_uid=""

if [ -n "$existing_datasource" ]; then
    log_info "Prometheus datasource already exists with UID: $existing_datasource"
    datasource_uid="$existing_datasource"
else
    # Create Prometheus datasource
    log_info "Creating Prometheus datasource in Grafana..."
    
    prometheus_url="http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    
    datasource_config=$(cat <<EOF
{
    "name": "Prometheus",
    "type": "prometheus",
    "url": "$prometheus_url",
    "access": "proxy",
    "isDefault": true,
    "basicAuth": false,
    "jsonData": {
        "httpMethod": "POST"
    }
}
EOF
)
    
    create_response=$(curl -s -X POST -u "admin:$admin_password" \
        -H "Content-Type: application/json" \
        -d "$datasource_config" \
        "http://$grafana_ip:$grafana_port/api/datasources" 2>/dev/null)
    
    # Extract UID from response
    datasource_uid=$(echo "$create_response" | jq -r '.datasource.uid' 2>/dev/null || echo "")
    
    if [ -n "$datasource_uid" ] && [ "$datasource_uid" != "null" ]; then
        log_success "Prometheus datasource created with UID: $datasource_uid"
    else
        log_warning "Failed to create Prometheus datasource: $create_response"
        # Try to get existing datasource UID as fallback
        datasource_uid=$(curl -s -u "admin:$admin_password" "http://$grafana_ip:$grafana_port/api/datasources" 2>/dev/null | jq -r '.[] | select(.type=="prometheus") | .uid' 2>/dev/null || echo "")
        if [ -n "$datasource_uid" ]; then
            log_info "Using existing Prometheus datasource UID: $datasource_uid"
        else
            log_error "Could not determine Prometheus datasource UID"
            exit 1
        fi
    fi
fi

log_success "Prometheus datasource UID: $datasource_uid"

# Update dashboard with correct datasource UID
log_info "Updating dashboard with correct Prometheus datasource UID..."

dashboard_file="$PROJECT_ROOT/deathstar-bench/monitoring/davide-dashboard.json"
temp_dashboard="/tmp/davide-dashboard-updated.json"

if [ ! -f "$dashboard_file" ]; then
    log_error "Dashboard file not found: $dashboard_file"
    exit 1
fi

# Replace the hardcoded datasource UID with the correct one
sed "s/bexfug0nscoowa/$datasource_uid/g" "$dashboard_file" > "$temp_dashboard"

# Update the ConfigMap with the corrected dashboard
kubectl create configmap davide-dashboard \
  --from-file=davide-dashboard.json="$temp_dashboard" \
  -n monitoring --dry-run=client -o yaml | kubectl apply -f -

# Label ConfigMap for Grafana sidecar to pick it up
kubectl label configmap davide-dashboard grafana_dashboard=1 -n monitoring --overwrite

# Clean up temporary file
rm -f "$temp_dashboard"

log_success "Dashboard updated with correct datasource UID: $datasource_uid"

# Wait for dashboard to be updated
log_info "Waiting for dashboard to be updated by Grafana..."
sleep 10

# Verify dashboard was updated
dashboard_check=$(curl -s "http://admin:$admin_password@$grafana_ip:$grafana_port/api/search?type=dash-db" 2>/dev/null | grep -q "91f6cb1c-9c6a-438b-af3b-5603e7b2db5c" && echo "true" || echo "false")

if [ "$dashboard_check" = "true" ]; then
    log_success "Davide dashboard updated successfully!"
    log_info "Dashboard URL: http://$grafana_ip:$grafana_port/d/91f6cb1c-9c6a-438b-af3b-5603e7b2db5c/davide-hpa-dashboard"
    log_info "Prometheus datasource UID: $datasource_uid"
else
    log_warning "Dashboard update verification failed, but ConfigMap was updated"
fi

log_success "Grafana datasource fix completed!"
