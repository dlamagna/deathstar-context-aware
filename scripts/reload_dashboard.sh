#!/bin/bash

# reload_dashboard.sh - Reload the Grafana dashboard with fixed queries

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

# Debug logging (toggle with VERBOSE=1)
VERBOSE=${VERBOSE:-0}
log_debug() {
    if [ "$VERBOSE" = "1" ]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

# Configuration
PROJECT_ROOT="/home/dlamagna/projects/Context-Aware-HPA"
DASHBOARD_FILE="$PROJECT_ROOT/deathstar-bench/monitoring/davide-dashboard.json"
GRAFANA_NAMESPACE="monitoring"
GRAFANA_SVC="kube-prometheus-stack-grafana"
GRAFANA_LOCAL_PORT=3000
GRAFANA_REMOTE_PORT=80

# Function to check if Grafana is accessible
check_grafana() {
    log_info "Checking Grafana accessibility..."
    log_debug "Namespace: $GRAFANA_NAMESPACE, Service: $GRAFANA_SVC, LocalPort: $GRAFANA_LOCAL_PORT, RemotePort: $GRAFANA_REMOTE_PORT"
    
    if ! kubectl get pod -n "$GRAFANA_NAMESPACE" -l app.kubernetes.io/name=grafana >/dev/null 2>&1; then
        log_error "Grafana pod not found"
        return 1
    fi
    
    # Port forward Grafana
    log_info "Setting up port forwarding for Grafana..."
    kubectl port-forward -n "$GRAFANA_NAMESPACE" svc/"$GRAFANA_SVC" "$GRAFANA_LOCAL_PORT":"$GRAFANA_REMOTE_PORT" >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    log_debug "Started port-forward PID: $PORT_FORWARD_PID"
    
    # Wait for port forward to be ready (retry for ~20s)
    for i in {1..20}; do
        local hc
        hc=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$GRAFANA_LOCAL_PORT/api/health" || true)
        log_debug "Health check attempt #$i HTTP: ${hc:-n/a}"
        if [ "$hc" = "200" ]; then
            log_success "Grafana is accessible"
            return 0
        fi
        sleep 1
    done
    
    log_error "Grafana is not accessible"
    kill $PORT_FORWARD_PID 2>/dev/null || true
    return 1
}

# Discover and validate Grafana credentials
get_grafana_credentials() {
    # Try a prioritized list of secrets: service name first, then any with admin-password
    local candidate_secrets
    candidate_secrets=$(kubectl get secret -n "$GRAFANA_NAMESPACE" -o json \
        | jq -r --arg svc "$GRAFANA_SVC" '
            [ .items[]
              | {name: .metadata.name, data: .data}
              | select(.data["admin-password"]) ]
            | sort_by(.name != $svc)  # prefer the service-named secret if exists
            | .[].name')
    if [ -z "${candidate_secrets:-}" ]; then
        log_warning "No secrets with admin-password found in namespace $GRAFANA_NAMESPACE"
    else
        log_debug "Candidate secrets: $(echo "$candidate_secrets" | tr '\n' ' ')"
    fi

    local secret_name=""
    local grafana_user=""
    local grafana_password=""

    for name in $candidate_secrets; do
        log_debug "Trying credentials from secret: $name"
        local json
        if ! json=$(kubectl get secret -n "$GRAFANA_NAMESPACE" "$name" -o json 2>/dev/null); then
            continue
        fi
        grafana_user=$(echo "$json" | jq -r '.data["admin-user"] // empty' | base64 -d 2>/dev/null | tr -d '\n' || true)
        grafana_password=$(echo "$json" | jq -r '.data["admin-password"] // empty' | base64 -d 2>/dev/null | tr -d '\n' || true)
        if [ -z "${grafana_user:-}" ]; then grafana_user="admin"; fi
        if [ -n "${grafana_password:-}" ]; then
            secret_name="$name"
            # Validate credentials by calling /api/user
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" -u "$grafana_user:$grafana_password" \
                "http://localhost:$GRAFANA_LOCAL_PORT/api/user" || true)
            log_debug "Validation HTTP code for $name: $code (user=$grafana_user)"
            if [ "$code" = "200" ]; then
                log_success "Authenticated to Grafana with secret: $secret_name"
                echo "$grafana_user:$grafana_password"
                return 0
            else
                log_warning "Credentials from secret $name failed (HTTP $code). Trying next..."
            fi
        fi
    done

    log_error "Unable to authenticate to Grafana with discovered secrets"
    return 1
}

# Function to import dashboard
import_dashboard() {
    log_info "Importing updated dashboard via ConfigMap (Grafana sidecar)..."
    log_debug "Dashboard file: $DASHBOARD_FILE (size: $(stat -c%s \"$DASHBOARD_FILE\" 2>/dev/null || echo n/a) bytes)"

    # Create/Update ConfigMap from the dashboard file
    if kubectl create configmap davide-dashboard \
        --from-file=davide-dashboard.json="$DASHBOARD_FILE" \
        -n "$GRAFANA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -; then
        log_success "ConfigMap 'davide-dashboard' applied"
    else
        log_error "Failed to apply ConfigMap 'davide-dashboard'"
        return 1
    fi

    # Ensure it is labeled for Grafana sidecar discovery
    if kubectl label configmap davide-dashboard grafana_dashboard=1 -n "$GRAFANA_NAMESPACE" --overwrite >/dev/null 2>&1; then
        log_success "Labeled ConfigMap 'davide-dashboard' with grafana_dashboard=1"
    else
        log_warning "Failed to label ConfigMap; Grafana sidecar may not pick it up"
    fi

    # Nudge Grafana sidecar by annotating the ConfigMap to trigger update
    kubectl annotate configmap davide-dashboard dashboard-reload-ts=$(date +%s) -n "$GRAFANA_NAMESPACE" --overwrite >/dev/null 2>&1 || true

    log_info "Waiting briefly for Grafana sidecar to reload dashboards..."
    sleep 5

    log_success "Dashboard reload requested via ConfigMap"
    return 0
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Reload the Grafana dashboard with fixed queries to eliminate duplicates"
    echo ""
    echo "OPTIONS:"
    echo "  --help               Show this help message"
    echo ""
    echo "This script will:"
    echo "  1. Check Grafana accessibility"
    echo "  2. Import the updated dashboard"
    echo "  3. Provide the dashboard URL"
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
    
    log_info "Starting dashboard reload..."
    if [ "$VERBOSE" = "1" ]; then
        log_info "Verbose mode enabled (VERBOSE=1)"
        set -x
    fi
    
    # Check if dashboard file exists
    if [ ! -f "$DASHBOARD_FILE" ]; then
        log_error "Dashboard file not found: $DASHBOARD_FILE"
        exit 1
    fi
    
    # Check Grafana accessibility
    log_info "Ensuring Grafana is reachable via port-forward..."
    if ! check_grafana; then
        log_error "Cannot access Grafana - please ensure it's running"
        exit 1
    fi
    log_debug "Port-forward active with PID: ${PORT_FORWARD_PID:-unknown}"
    
    # Import dashboard
    if import_dashboard; then
        log_success "Dashboard reload completed successfully!"
        log_info "You can now view the updated dashboard in Grafana"
    else
        log_error "Dashboard reload failed"
        kill ${PORT_FORWARD_PID:-0} 2>/dev/null || true
        exit 1
    fi
    
    # Clean up port forward
    kill ${PORT_FORWARD_PID:-0} 2>/dev/null || true
}

# Trap to ensure cleanup on exit
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

# Run main function
main "$@"



