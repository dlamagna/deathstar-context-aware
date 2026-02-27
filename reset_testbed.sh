#!/bin/bash

# reset_testbed.sh - Complete testbed reset and reinstall script
# This script completely tears down and rebuilds the Kubernetes cluster
# with monitoring stack and Social Network application

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions with timestamps
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

# Function to print Grafana credentials (optionally including the admin password)
print_grafana_credentials() {
    local print_password="${1:-false}"
    local ns="monitoring"
    local secret_name="kube-prometheus-stack-grafana"

    # Best-effort discovery: prefer the well-known chart secret, otherwise find any secret with admin-password
    if ! kubectl -n "$ns" get secret "$secret_name" >/dev/null 2>&1; then
        secret_name="$(kubectl -n "$ns" get secrets -o json 2>/dev/null \
            | jq -r '.items[] | select(.data["admin-password"]) | .metadata.name' 2>/dev/null \
            | head -n 1 || true)"
    fi

    if [ -z "${secret_name:-}" ]; then
        log_warning "Grafana admin secret not found in namespace '$ns' (skipping credential print)"
        return 0
    fi

    local admin_user
    admin_user="$(kubectl -n "$ns" get secret "$secret_name" -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -z "${admin_user:-}" ]; then
        admin_user="admin"
    fi

    log_info "Grafana credentials:"
    log_info "  namespace: $ns"
    log_info "  secret:    $secret_name"
    log_info "  username:  $admin_user"

    if [ "$print_password" = true ]; then
        local admin_password
        admin_password="$(kubectl -n "$ns" get secret "$secret_name" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
        if [ -n "${admin_password:-}" ]; then
            log_warning "Grafana admin password is being printed because --print-grafana-password was set"
            log_info "  password:  $admin_password"
        else
            log_warning "Could not decode Grafana admin password from secret '$secret_name'"
        fi
    else
        log_info "  password:  (not printed)"
        log_info "  to get it: kubectl -n monitoring get secret $secret_name -o jsonpath='{.data.admin-password}' | base64 -d ; echo"
    fi
}

# Best-effort: ensure Grafana's persistent DB admin password matches the Kubernetes Secret.
# This prevents 401s from the sidecar reloaders when persistence is enabled.
sync_grafana_admin_password_to_secret() {
    local ns="monitoring"
    local secret_name="kube-prometheus-stack-grafana"

    if ! kubectl -n "$ns" get secret "$secret_name" >/dev/null 2>&1; then
        return 0
    fi

    local pw
    pw="$(kubectl -n "$ns" get secret "$secret_name" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -z "${pw:-}" ]; then
        return 0
    fi

    local pod
    pod="$(kubectl -n "$ns" get pods -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod:-}" ]; then
        return 0
    fi

    log_info "Syncing Grafana admin password in persistent DB (best effort)..."
    # Prefer new CLI, fall back to legacy grafana-cli
    kubectl -n "$ns" exec "$pod" -c grafana -- grafana cli --homepath /usr/share/grafana admin reset-admin-password "$pw" >/dev/null 2>&1 \
      || kubectl -n "$ns" exec "$pod" -c grafana -- grafana-cli --homepath /usr/share/grafana admin reset-admin-password "$pw" >/dev/null 2>&1 \
      || log_warning "Failed to sync Grafana admin password (continuing)"
}

# Configuration
CLUSTER_NAME="socialnetwork"

# Allow overriding PROJECT_ROOT via environment, otherwise derive it from this script's location
if [ -z "${PROJECT_ROOT:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$SCRIPT_DIR"
fi

CLUSTER_TYPE=""  # Will be set via --cluster-type parameter
# Public IP of the server hosting the cluster (used for remote access hints)
# Set this to your server's reachable IP/DNS so the script prints copy/paste URLs
PUBLIC_SERVER_IP="147.83.130.68"

# Docker image cache configuration
DOCKER_IMAGE_CACHE_DIR="$PROJECT_ROOT/docker_images"
REQUIRED_IMAGES=(
    # Metrics server (always needed)
    "registry.k8s.io/metrics-server/metrics-server:v0.8.0"
    # Monitoring stack images
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.3"
    "quay.io/kiwigrid/k8s-sidecar:1.30.10"
    "quay.io/prometheus/node-exporter:v1.9.1"
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0"
    "quay.io/prometheus-operator/prometheus-operator:v0.86.1"
    "docker.io/grafana/grafana:12.2.0"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.86.1"
    "quay.io/prometheus/prometheus:v3.7.1"
    "quay.io/prometheus/alertmanager:v0.28.1"
    "registry.k8s.io/prometheus-adapter/prometheus-adapter:v0.12.0"
    # Social network application images (optional, only with --preload-images)
    "deathstarbench/social-network-microservices:latest"
    "mongo:4.4.6"
    "redis:6.2.4"
    "memcached:1.6.7"
    "alpine/git:latest"
    "yg397/openresty-thrift:xenial"
    "yg397/media-frontend:xenial"
    "jaegertracing/all-in-one:1.62.0"
)

# Logging to file (stream live to logs/ via tee)
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/reset_testbed_$(date +%Y%m%d_%H%M%S).log"
# Stream stdout/stderr to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Log startup message with command used to invoke script
echo "=========================================="
echo "Reset Testbed Script Started"
echo "Timestamp: $(date)"
echo "Log file: $LOG_FILE"
echo "Project root: $PROJECT_ROOT"
echo "Command invoked: $0 $*"
echo "=========================================="

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to start port-forward script in background
start_port_forward_background() {
    local pf_script="$PROJECT_ROOT/port-forward.sh"
    if [ ! -f "$pf_script" ]; then
        log_warning "Port-forward script not found: $pf_script"
        return 0
    fi

    # Avoid duplicate background runs
    if pgrep -f "bash .*port-forward.sh" >/dev/null 2>&1 || pgrep -f "/bin/bash .*port-forward.sh" >/dev/null 2>&1; then
        log_info "port-forward.sh already running; skipping start"
        return 0
    fi

    # Ensure monitoring namespace exists before starting
    if ! kubectl get ns monitoring >/dev/null 2>&1; then
        log_warning "Namespace 'monitoring' not present yet; delaying port-forward start"
        return 0
    fi

    local pf_log="$LOG_DIR/port_forward_$(date +%Y%m%d_%H%M%S).log"
    log_info "Starting port-forward.sh in background (logs: $pf_log)"
    nohup bash "$pf_script" > "$pf_log" 2>&1 &
}

# Function to check if image exists locally in Docker
image_exists_locally() {
    local image="$1"
    # This checks if the image exists in Docker's local registry (not in cache directory)
    docker image inspect "$image" >/dev/null 2>&1
}

# Function to check if image is already loaded in minikube
image_loaded_in_minikube() {
    local image="$1"
    if [ "$CLUSTER_TYPE" = "minikube" ]; then
        minikube image ls 2>/dev/null | grep -q "^$image$" || return 1
    elif [ "$CLUSTER_TYPE" = "kind" ]; then
        # For kind, we can't easily check, so assume not loaded
        return 1
    fi
}

# Function to save image to cache directory
save_image_to_cache() {
    local image="$1"
    local image_name=$(echo "$image" | sed 's/[:\/]/_/g')
    local cache_file="$DOCKER_IMAGE_CACHE_DIR/${image_name}.tar"
    
    log_info "Saving image to cache: $image"
    docker save "$image" -o "$cache_file" || log_warning "Failed to save $image to cache"
}

# Function to load image from cache directory
load_image_from_cache() {
    local image="$1"
    local image_name=$(echo "$image" | sed 's/[:\/]/_/g')
    local cache_file="$DOCKER_IMAGE_CACHE_DIR/${image_name}.tar"
    
    if [ -f "$cache_file" ]; then
        log_info "Loading image from cache: $image"
        docker load -i "$cache_file" || log_warning "Failed to load $image from cache"
        return 0
    else
        return 1
    fi
}

# Function to ensure required images are available
ensure_images_available() {
    local images_to_check=("$@")
    local missing_images=()
    
    log_info "Checking for required images..."
    
    # Create cache directory if it doesn't exist
    mkdir -p "$DOCKER_IMAGE_CACHE_DIR"
    
    # Check each required image
    local total_check_images=${#images_to_check[@]}
    local current_check_image=0
    
    for image in "${images_to_check[@]}"; do
        current_check_image=$((current_check_image + 1))
        if image_exists_locally "$image"; then
            log_info "✓ Image available locally ($current_check_image/$total_check_images): $image"
        else
            log_warning "✗ Image missing ($current_check_image/$total_check_images): $image"
            missing_images+=("$image")
        fi
    done
    
    # If images are missing, try to load from cache first, then download
    if [ ${#missing_images[@]} -gt 0 ]; then
        log_info "Attempting to load missing images from cache..."
        for image in "${missing_images[@]}"; do
            if load_image_from_cache "$image"; then
                log_success "Loaded from cache: $image"
                missing_images=($(printf '%s\n' "${missing_images[@]}" | grep -v "^$image$"))
            fi
        done
        
        # Download remaining missing images
        if [ ${#missing_images[@]} -gt 0 ]; then
            log_info "Downloading remaining missing images..."
            local total_missing=${#missing_images[@]}
            local current_download=0
            
            for image in "${missing_images[@]}"; do
                current_download=$((current_download + 1))
                log_info "Pulling image ($current_download/$total_missing): $image"
            find . -name "$image"
            
        if docker pull "$image" --platform linux/amd64; then
                    log_success "✓ Downloaded: $image"
                    save_image_to_cache "$image"
                else
                    log_error "✗ Failed to download: $image"
                    return 1
                fi
            done
        fi
    else
        log_success "All required images are available locally"
    fi
    
    return 0
}

# Function to wait for pods to be ready
wait_for_pods() {
    local namespace=$1
    local timeout=${2:-300} # 5 minutes default
    local selector=${3:-""}
    local exclude_patterns=${4:-""}
    
    log_info "Waiting for pods to be ready in namespace '$namespace'..."
    
    # Wait for pods with retry logic
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        if [ -n "$selector" ]; then
            kubectl wait --for=condition=ready pod -l "$selector" -n "$namespace" --timeout="${timeout}s" && break
        else
            kubectl wait --for=condition=ready pod --all -n "$namespace" --timeout="${timeout}s" && break
        fi
        
        retry_count=$((retry_count + 1))
        log_warning "Attempt $retry_count failed, checking for stuck pods..."
        
        # Check for stuck pods and restart them
        check_and_restart_stuck_pods "$namespace" "$exclude_patterns"
        
        if [ $retry_count -lt $max_retries ]; then
            log_info "Retrying in 30 seconds..."
            sleep 30
        fi
    done
    
    # Final status check
    if [ -n "$selector" ]; then
        kubectl get pods -n "$namespace" -l "$selector"
    else
        kubectl get pods -n "$namespace"
    fi
}

# Function to check and restart stuck pods
check_and_restart_stuck_pods() {
    local namespace=$1
    local exclude_patterns=${2:-""}
    
    log_info "Checking for stuck pods in namespace '$namespace'..."
    
    # Get pods that are not running or completed
    local stuck_pods=$(kubectl get pods -n "$namespace" --no-headers -o custom-columns=":metadata.name" | while read pod; do
        if [ -n "$exclude_patterns" ]; then
            # Skip excluded patterns
            echo "$exclude_patterns" | grep -q "$pod" && continue
        fi
        
        local status=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$status" != "Running" ] && [ "$status" != "Completed" ] && [ "$status" != "Succeeded" ]; then
            echo "$pod"
        fi
    done)
    
    if [ -n "$stuck_pods" ]; then
        log_warning "Found stuck pods, restarting them..."
        echo "$stuck_pods" | while read pod; do
            if [ -n "$pod" ]; then
                log_info "Restarting stuck pod: $pod"
                kubectl delete pod "$pod" -n "$namespace" --grace-period=0 --force 2>/dev/null || true
            fi
        done
        
        # Wait a bit for pods to be recreated
        sleep 15
    fi
}

# Function to check if cluster exists
cluster_exists() {
    if [ "$CLUSTER_TYPE" = "kind" ]; then
        kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" || return 1
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        minikube status >/dev/null 2>&1 || return 1
    else
        log_error "Invalid cluster type: $CLUSTER_TYPE"
        return 1
    fi
}

# Function to flush Prometheus data before reset
flush_prometheus_data() {
    if [ "$persist_monitoring_data" = false ]; then
        return 0  # Skip if persistence not enabled
    fi
    
    log_info "Flushing Prometheus WAL data before reset..."
    
    # Check if Prometheus exists
    if ! kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running; then
        log_info "Prometheus not running, skipping flush"
        return 0
    fi
    
    local prometheus_pod=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    
    if [ -z "$prometheus_pod" ]; then
        log_info "Prometheus pod not found, skipping flush"
        return 0
    fi
    
    # Give Prometheus time to sync any pending writes to disk
    # NOTE: This helps preserve WAL data but cannot guarantee 100% data preservation
    # Data less than 2 hours old is at risk of being lost during hard reset
    log_info "Waiting for Prometheus to sync pending writes to disk..."
    log_warning "Recent data (< 2 hours old) may still be lost during hard reset"
    log_warning "This is a limitation of hard resets with Kind clusters"
    
    sleep 60  # Give time for pending operations to complete
    
    log_success "Attempted to preserve data (best effort)"
    log_info "For guaranteed data preservation, use --force-reset-hpa instead of --hard-reset-testbed"
}

# Function to cleanup existing cluster
cleanup_cluster() {
    log_info "Cleaning up existing cluster..."
    
    if [ "$skip_monitoring" = true ]; then
        log_info "Skipping cluster recreation (--skip-monitoring flag set)"
        log_info "Only cleaning up socialnetwork namespace..."
        
        # Only clean up socialnetwork namespace, preserve monitoring
        kubectl delete namespace socialnetwork --ignore-not-found=true || true
        sleep 5
        
        # Clean up any remaining Docker containers/networks (but don't prune too aggressively)
        log_info "Cleaning up Docker resources..."
        docker system prune -f >/dev/null 2>&1 || true
        
        log_success "Social network cleanup completed (monitoring preserved)"
        return 0
    fi
    
    # Flush Prometheus data before reset if persistence is enabled
    if [ "$persist_monitoring_data" = true ]; then
        flush_prometheus_data
    fi
    
    # Full cluster cleanup (when not skipping monitoring)
    if cluster_exists; then
        if [ "$CLUSTER_TYPE" = "kind" ]; then
            log_info "Deleting existing Kind cluster: $CLUSTER_NAME"
            kind delete cluster --name "$CLUSTER_NAME"
        elif [ "$CLUSTER_TYPE" = "minikube" ]; then
            log_info "Deleting existing minikube cluster"
            minikube delete
        fi
        log_success "Cluster deleted successfully"
    else
        log_info "No existing cluster found"
    fi
    
    # Clean up monitoring namespace (only in full reset mode)
    log_info "Cleaning up monitoring namespace..."
    kubectl delete namespace monitoring --ignore-not-found=true || true
    sleep 5

    # Clean up any remaining Docker containers/networks
    log_info "Cleaning up Docker resources..."
    docker system prune -f >/dev/null 2>&1 || true
}

# Function to install prerequisites
install_prerequisites() {
    log_info "Installing prerequisites..."
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    
    # Check if required cluster tool is installed
    if [ "$CLUSTER_TYPE" = "kind" ]; then
        if ! command_exists kind; then
            log_error "Kind is not installed. Please install Kind first:"
            echo "  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64"
            echo "  chmod +x ./kind"
            echo "  sudo mv ./kind /usr/local/bin/kind"
            exit 1
        fi
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        if ! command_exists minikube; then
            log_error "Minikube is not installed. Please install minikube first:"
            echo "  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
            echo "  sudo install minikube-linux-amd64 /usr/local/bin/minikube"
            exit 1
        fi
    else
        log_error "Invalid cluster type: $CLUSTER_TYPE. Must be 'kind' or 'minikube'"
        exit 1
    fi
    
    # Check if kubectl is installed
    if ! command_exists kubectl; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    # Check if Helm is installed
    if ! command_exists helm; then
        log_error "Helm is not installed. Please install Helm first:"
        echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        exit 1
    fi
    
    # Check if k6 is installed (optional but recommended)
    if ! command_exists k6; then
        log_warning "k6 is not installed. Load testing will not be available."
    fi
    
    log_success "Prerequisites check completed"
}

# Function to create Kind cluster
create_cluster() {
    if [ "$CLUSTER_TYPE" = "kind" ]; then
        log_info "Creating Kind cluster: $CLUSTER_NAME"
        
        # Create cluster with proper configuration and increased resources
        if [ "$persist_monitoring_data" = true ]; then
        cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
        max-pods: "110"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  extraMounts:
  - hostPath: /srv/kind-monitoring
    containerPath: /mnt/monitoring
- role: worker
  extraMounts:
  - hostPath: /srv/kind-monitoring
    containerPath: /mnt/monitoring
- role: worker
  extraMounts:
  - hostPath: /srv/kind-monitoring
    containerPath: /mnt/monitoring
EOF
        else
        cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
        max-pods: "110"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
EOF
        fi
        
        # Set kubectl context
        kubectl cluster-info --context "kind-$CLUSTER_NAME"
        
        # Fix DNS issues in Kind cluster
        fix_dns_issues
        
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        log_info "Creating minikube cluster"
        
        # Create minikube cluster with sufficient resources
        minikube start --memory=8192 --cpus=8 --disk-size=20g
        
        # Set kubectl context
        kubectl cluster-info --context minikube
        
        # Fix DNS issues in minikube cluster
        fix_minikube_dns
        
    else
        log_error "Invalid cluster type: $CLUSTER_TYPE"
        exit 1
    fi
    
    log_success "Cluster created successfully"
}

# Function to fix DNS issues in Kind cluster
fix_dns_issues() {
    if [ "$no_dns_resolution" = true ]; then
        log_info "Skipping DNS fixes (--no-dns-resolution flag set)"
        return 0
    fi
    
    log_info "Fixing DNS issues in Kind cluster..."
    
    # Wait for cluster to be ready
    sleep 15
    
    # Patch CoreDNS to use external DNS servers with more conservative settings
    kubectl patch configmap/coredns -n kube-system --type merge -p='{"data":{"Corefile":".:53 {\n    errors\n    health {\n       lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n       fallthrough in-addr.arpa ip6.arpa\n       ttl 30\n    }\n    prometheus :9153\n    forward . 8.8.8.8 8.8.4.4 1.1.1.1 {\n       except cba.upc.edu\n    }\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"}}' || log_warning "Failed to patch CoreDNS configmap"
    
    # Restart CoreDNS pods to apply changes
    kubectl rollout restart deployment/coredns -n kube-system || log_warning "Failed to restart CoreDNS deployment"
    
    # Wait for CoreDNS to be ready with retry logic
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        if kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=120s 2>/dev/null; then
            log_success "CoreDNS is ready"
            break
        else
            retry_count=$((retry_count + 1))
            log_warning "CoreDNS not ready, attempt $retry_count/$max_retries"
            
            if [ $retry_count -lt $max_retries ]; then
                # Try to fix CoreDNS by deleting problematic pods
                kubectl delete pods -n kube-system -l k8s-app=kube-dns --grace-period=0 --force 2>/dev/null || true
                sleep 10
            fi
        fi
    done
    
    # Final check - if CoreDNS is still not working, skip the DNS fix
    if ! kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running | grep -q "coredns"; then
        log_warning "CoreDNS is not working properly, continuing without DNS fix"
        return 0
    fi
    
    log_success "DNS issues fixed"
}

# Function to fix DNS issues in minikube cluster
fix_minikube_dns() {
    if [ "$no_dns_resolution" = true ]; then
        log_info "Skipping minikube DNS fixes (--no-dns-resolution flag set)"
        return 0
    fi
    
    log_info "Fixing DNS issues in minikube cluster..."
    
    # Configure minikube to use external DNS servers directly
    log_info "Configuring minikube DNS to use external servers..."
    minikube ssh -- "sudo mkdir -p /etc/systemd/resolved.conf.d && sudo tee /etc/systemd/resolved.conf.d/dns_override.conf > /dev/null <<EOF
[Resolve]
DNS=8.8.8.8 8.8.4.4 1.1.1.1
FallbackDNS=1.0.0.1
EOF"
    
    # Restart systemd-resolved to apply DNS changes
    minikube ssh -- "sudo systemctl restart systemd-resolved" || log_warning "Failed to restart systemd-resolved"
    
    # Update /etc/resolv.conf to use the new DNS servers
    minikube ssh -- "sudo rm -f /etc/resolv.conf && sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf" || log_warning "Failed to update resolv.conf"
    
    # Wait a bit for DNS changes to take effect
    sleep 10
    
    # Test DNS resolution
    log_info "Testing DNS resolution in minikube..."
    if minikube ssh -- "nslookup github.com" >/dev/null 2>&1; then
        log_success "DNS resolution working in minikube"
    else
        log_warning "DNS resolution still not working, trying alternative approach..."
        
        # Alternative: Update CoreDNS to use external DNS servers
        kubectl patch configmap/coredns -n kube-system --type merge -p='{"data":{"Corefile":".:53 {\n    errors\n    health {\n       lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n       fallthrough in-addr.arpa ip6.arpa\n       ttl 30\n    }\n    prometheus :9153\n    forward . 8.8.8.8 8.8.4.4 1.1.1.1 {\n       except cba.upc.edu\n    }\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"}}' || log_warning "Failed to patch CoreDNS configmap"
        
        # Restart CoreDNS pods
        kubectl rollout restart deployment/coredns -n kube-system || log_warning "Failed to restart CoreDNS deployment"
        
        # Wait for CoreDNS to be ready
        kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=120s 2>/dev/null || log_warning "CoreDNS not ready after restart"
    fi
    
    log_success "Minikube DNS configuration completed"
}

# Function to test DNS resolution in cluster
test_dns_resolution() {
    if [ "$no_dns_resolution" = true ]; then
        log_info "Skipping DNS resolution test (--no-dns-resolution flag set)"
        return 0
    fi
    
    log_info "Testing DNS resolution in cluster..."
    
    # Create a temporary pod to test DNS
    kubectl run dns-test-$(date +%s) --image=busybox --restart=Never --rm --command -- nslookup github.com >/dev/null 2>&1
    local dns_test_exit_code=$?
    
    if [ $dns_test_exit_code -eq 0 ]; then
        log_success "DNS resolution test passed"
        return 0
    else
        log_warning "DNS resolution test failed, exit code: $dns_test_exit_code"
        return 1
    fi
}

# Function to preload all Docker images (including social network) to avoid pull issues
preload_all_images() {
    log_info "Preloading all Docker images to avoid pull issues..."
    
    # Define all images (essential + social network)
    local all_images=(
        # Essential monitoring images
        "registry.k8s.io/metrics-server/metrics-server:v0.8.0"
        "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.3"
        "quay.io/kiwigrid/k8s-sidecar:1.30.10"
        "quay.io/prometheus/node-exporter:v1.9.1"
        "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0"
        "quay.io/prometheus-operator/prometheus-operator:v0.86.1"
        "docker.io/grafana/grafana:12.2.0"
        "quay.io/prometheus-operator/prometheus-config-reloader:v0.86.1"
        "quay.io/prometheus/prometheus:v3.7.1"
        "quay.io/prometheus/alertmanager:v0.28.1"
        "registry.k8s.io/prometheus-adapter/prometheus-adapter:v0.12.0"
        # Social network application images
        "deathstarbench/social-network-microservices:latest"
        "mongo:4.4.6"
        "redis:6.2.4"
        "memcached:1.6.7"
        "alpine/git:latest"
        "yg397/openresty-thrift:xenial"
        "yg397/media-frontend:xenial"
        "jaegertracing/all-in-one:1.62.0"
    )
    
    # Ensure all images are available
    ensure_images_available "${all_images[@]}"
    
    # Load images into cluster with timeout and progress
    local total_images=${#all_images[@]}
    local current_image=0
    
    for image in "${all_images[@]}"; do
        current_image=$((current_image + 1))
        
        # Check if image is already loaded in cluster
        if image_loaded_in_minikube "$image"; then
            log_info "✓ Image already loaded in cluster ($current_image/$total_images): $image"
            continue
        fi
        
        log_info "Loading image into cluster ($current_image/$total_images): $image"
        
        if [ "$CLUSTER_TYPE" = "kind" ]; then
            if timeout 60 kind load docker-image "$image" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
                log_success "✓ Loaded into Kind cluster: $image"
            else
                log_warning "✗ Failed to load into Kind cluster (timeout or error): $image"
            fi
        elif [ "$CLUSTER_TYPE" = "minikube" ]; then
            if timeout 120 minikube image load "$image" >/dev/null 2>&1; then
                log_success "✓ Loaded into minikube: $image"
            else
                log_warning "✗ Failed to load into minikube (timeout or error): $image"
            fi
        fi
    done
    
    log_success "All images preloading completed"
}

# Always preload metrics-server and monitoring stack images to avoid pull timeouts
preload_essential_images() {
    log_info "Preloading essential images (metrics-server + monitoring stack)..."
    
    # Define essential images (always needed for monitoring)
    local essential_images=(
        "registry.k8s.io/metrics-server/metrics-server:v0.8.0"
        "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.3"
        "quay.io/kiwigrid/k8s-sidecar:1.30.10"
        "quay.io/prometheus/node-exporter:v1.9.1"
        "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.17.0"
        "quay.io/prometheus-operator/prometheus-operator:v0.86.1"
        "docker.io/grafana/grafana:12.2.0"
        "quay.io/prometheus-operator/prometheus-config-reloader:v0.86.1"
        "quay.io/prometheus/prometheus:v3.7.1"
        "quay.io/prometheus/alertmanager:v0.28.1"
        "registry.k8s.io/prometheus-adapter/prometheus-adapter:v0.12.0"
    )
    
    # Ensure all essential images are available
    ensure_images_available "${essential_images[@]}"
    
    # Load images into cluster with timeout and progress
    local total_images=${#essential_images[@]}
    local current_image=0
    
    for image in "${essential_images[@]}"; do
        current_image=$((current_image + 1))
        
        # Check if image is already loaded in cluster
        if image_loaded_in_minikube "$image"; then
            log_info "✓ Image already loaded in cluster ($current_image/$total_images): $image"
            continue
        fi
        
        log_info "Loading image into cluster ($current_image/$total_images): $image"
        
        if [ "$CLUSTER_TYPE" = "kind" ]; then
            if timeout 60 kind load docker-image "$image" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
                log_success "✓ Loaded into Kind cluster: $image"
            else
                log_warning "✗ Failed to load into Kind cluster (timeout or error): $image"
            fi
        elif [ "$CLUSTER_TYPE" = "minikube" ]; then
            if timeout 120 minikube image load "$image" >/dev/null 2>&1; then
                log_success "✓ Loaded into minikube: $image"
            else
                log_warning "✗ Failed to load into minikube (timeout or error): $image"
            fi
        fi
    done
    
    log_success "Essential images preload completed"
}

# Function to fix Prometheus ServiceMonitor discovery
fix_prometheus_target_discovery() {
    log_info "Fixing Prometheus ServiceMonitor discovery..."
    
    # Restart Prometheus to reload ServiceMonitor configurations
    if kubectl get statefulset -n monitoring -l app.kubernetes.io/name=prometheus >/dev/null 2>&1; then
        local prom_statefulset=$(kubectl get statefulset -n monitoring -l app.kubernetes.io/name=prometheus --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
        
        if [ -n "$prom_statefulset" ]; then
            log_info "Restarting Prometheus statefulset to discover ServiceMonitors..."
            kubectl rollout restart statefulset "$prom_statefulset" -n monitoring
            
            # Wait for Prometheus to be ready after restart
            log_info "Waiting for Prometheus to be ready after restart..."
            kubectl rollout status statefulset "$prom_statefulset" -n monitoring --timeout=300s
            
            log_success "Prometheus restarted successfully"
            
            # Verify targets are discovered (wait a bit for configuration reload)
            log_info "Waiting for Prometheus to discover targets..."
            sleep 30
            
            # Check targets
            log_info "Checking Prometheus targets..."
            local targets=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
            if [ -n "$targets" ]; then
                log_info "Prometheus targets should now include kubelet and kube-state-metrics"
            fi
        else
            log_warning "Prometheus statefulset not found"
        fi
    else
        log_warning "No Prometheus statefulset found"
    fi
    
    log_success "Prometheus ServiceMonitor discovery fix completed"
}

# Function to install metrics server
install_metrics_server() {
    log_info "Installing metrics server..."
    
    # Clean up any existing metrics server first
    kubectl delete deployment metrics-server -n kube-system --ignore-not-found=true
    kubectl delete service metrics-server -n kube-system --ignore-not-found=true
    
    # Apply metrics server with permissive TLS for lab/test clusters
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --server-side --force-conflicts
    
    # Wait for deployment to be created
    sleep 5
    
    # Patch metrics server for insecure TLS and correct secure port
    kubectl -n kube-system patch deployment metrics-server \
      --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--cert-dir=/tmp","--secure-port=10250","--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"]}]'
    
    # Wait a bit for the patch to take effect
    sleep 10
    
    # Wait for metrics server pods with retry logic and stuck pod handling
    log_info "Waiting for metrics server to be ready (this may take a few minutes)..."
    
    local retry_count=0
    local max_retries=5
    
    while [ $retry_count -lt $max_retries ]; do
        kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s && break
        
        retry_count=$((retry_count + 1))
        log_warning "Metrics server attempt $retry_count failed, checking for stuck pods..."
        
        # Check for stuck metrics server pods and restart them
        local stuck_metrics_pods=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers -o custom-columns=":metadata.name" | while read pod; do
            local status=$(kubectl get pod "$pod" -n kube-system -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [ "$status" != "Running" ]; then
                echo "$pod"
            fi
        done)
        
        if [ -n "$stuck_metrics_pods" ]; then
            log_warning "Restarting stuck metrics server pods..."
            echo "$stuck_metrics_pods" | while read pod; do
                if [ -n "$pod" ]; then
                    kubectl delete pod "$pod" -n kube-system --grace-period=0 --force 2>/dev/null || true
                fi
            done
            sleep 15
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            log_info "Retrying metrics server in 30 seconds..."
            sleep 30
        fi
    done
    
    # Final status check
    kubectl get pods -n kube-system -l k8s-app=metrics-server
    log_success "Metrics server installation completed"
}

# Function to install monitoring stack
install_monitoring() {
    log_info "Installing monitoring stack..."
    
    # Preserve existing NodePorts if present, but default to 30900 for Grafana
    local grafana_nodeport="30900"
    local prom_nodeport=""
    if kubectl get svc kube-prometheus-stack-grafana -n monitoring >/dev/null 2>&1; then
        grafana_nodeport=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30900")
        log_info "Detected existing Grafana NodePort: ${grafana_nodeport}"
    fi
    if kubectl get svc kube-prometheus-stack-prometheus -n monitoring >/dev/null 2>&1; then
        prom_nodeport=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        log_info "Detected existing Prometheus NodePort (kube-prometheus-stack): ${prom_nodeport}"
    elif kubectl get svc prometheus-server -n monitoring >/dev/null 2>&1; then
        prom_nodeport=$(kubectl get svc prometheus-server -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        log_info "Detected existing Prometheus NodePort (prometheus chart): ${prom_nodeport}"
    fi

    # Add Prometheus community Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    # Build Helm args to enable Grafana and set NodePorts consistently
    local helm_args=(
      -n monitoring --create-namespace
      --set grafana.enabled=true
      --set grafana.service.type=NodePort
      --set grafana.service.nodePort="$grafana_nodeport"
      --set prometheus.service.type=NodePort
    )

    # Optional: allow no-login Grafana on protected servers by enabling anonymous Admin access
    if [ "${grafana_anonymous_admin:-false}" = true ]; then
        log_warning "Grafana anonymous Admin access enabled (no login required). Use only on protected networks/hosts."
        # Avoid tricky Helm escaping by using a small values file
        local grafana_anon_values="/tmp/grafana-anon-values.yaml"
        cat >"$grafana_anon_values" <<'YAML'
grafana:
  grafana.ini:
    auth.anonymous:
      enabled: true
      org_role: Admin
    auth:
      disable_login_form: true
YAML
        helm_args+=(-f "$grafana_anon_values")
    fi
    # Apply preserved prometheus nodePort if available
    if [ -n "$prom_nodeport" ]; then
        helm_args+=(--set prometheus.service.nodePort="$prom_nodeport")
    fi

    # If persist flag, set up PV/PVC and wire persistence + optional remote_write
    if [ "$persist_monitoring_data" = true ]; then
        # Ensure monitoring namespace exists before PVC
        kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
        # Create hostPath PVs in the cluster (require kind extraMounts)
        cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv
  labels:
    pv: prometheus
spec:
  capacity:
    storage: 20Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/monitoring/prometheus
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-pv
  labels:
    pv: grafana
spec:
  capacity:
    storage: 5Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/monitoring/grafana
EOF
        # PVC for Grafana (Prometheus manages its own PVCs via StatefulSet volumeClaimTemplate)
        cat <<'EOF' | kubectl apply -n monitoring -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
  storageClassName: ""
  selector:
    matchLabels:
      pv: grafana
EOF

        helm_args+=(
          --set grafana.persistence.enabled=true
          --set grafana.persistence.existingClaim=grafana-pvc
          --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=""
          --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi
          --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.metadata.name=prometheus-db
          --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.selector.matchLabels.pv=prometheus
        )
    fi
    if [ -n "${remote_write_url:-}" ]; then
        helm_args+=(--set prometheus.prometheusSpec.remoteWrite[0].url="${remote_write_url}")
    fi

    # Install kube-prometheus-stack (Prometheus + default Kubernetes scrape targets + Grafana)
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack "${helm_args[@]}"

    # Install kube-state-metrics
    helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
      -n monitoring --create-namespace
    
    # Wait for monitoring pods to be ready
    wait_for_pods "monitoring" 600

    # If Grafana uses persistence, admin credentials in the DB may drift from the Secret.
    # Syncing prevents 401s from sidecar reloaders and any scripted API calls.
    sync_grafana_admin_password_to_secret || true
    
    # Fix Grafana image pull issues by preloading the image
    fix_grafana_image_pull_issues
    
    # Fix Grafana external access for remote connectivity
    fix_grafana_external_access
    
    # Import Davide dashboard
    import_davide_dashboard
    
    # Fix Prometheus ServiceMonitor discovery issue
    # fix_prometheus_target_discovery
    
    log_success "Monitoring stack installed successfully"

    # Start port-forwarding in background
    start_port_forward_background

    # Output current NodePorts
    local current_grafana_np=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || kubectl get svc grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    local current_prom_np=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    if [ -n "$current_grafana_np" ]; then
        local mk_ip=$(minikube ip 2>/dev/null || echo "localhost")
        log_info "Grafana NodePort: ${current_grafana_np}"
        # Local (from server) access
        log_info "Grafana (on server): http://${mk_ip}:${current_grafana_np}"
        log_info "Dashboard (on server): http://${mk_ip}:${current_grafana_np}/d/91f6cb1c-9c6a-438b-af3b-5603e7b2db5c/davide-hpa-dashboard"
        # Remote (from your laptop) access via server public IP
        if [ -n "$PUBLIC_SERVER_IP" ]; then
            log_info "Grafana (from your laptop): http://${PUBLIC_SERVER_IP}:${current_grafana_np}"
            log_info "Dashboard (from your laptop): http://${PUBLIC_SERVER_IP}:${current_grafana_np}/d/91f6cb1c-9c6a-438b-af3b-5603e7b2db5c/davide-hpa-dashboard"
        fi
    fi
    if [ -n "$current_prom_np" ]; then
        log_info "Prometheus NodePort: ${current_prom_np}"
    fi
}

# Function to fix Grafana image pull issues
fix_grafana_image_pull_issues() {
    log_info "Fixing Grafana image pull issues..."
    
    # Check if Grafana pod is having image pull issues
    local grafana_pod=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    
    if [ -n "$grafana_pod" ]; then
        local pod_status=$(kubectl get pod "$grafana_pod" -n monitoring -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        if [ "$pod_status" != "Running" ]; then
            log_info "Grafana pod is not running, attempting to fix image pull issues..."
            
            # Preload Grafana image to avoid pull issues
            log_info "Preloading Grafana image..."
            if [ "$CLUSTER_TYPE" = "minikube" ]; then
                minikube image load docker.io/grafana/grafana:12.2.0 >/dev/null 2>&1 || log_warning "Failed to preload Grafana image"
            elif [ "$CLUSTER_TYPE" = "kind" ]; then
                kind load docker-image docker.io/grafana/grafana:12.2.0 --name "$CLUSTER_NAME" >/dev/null 2>&1 || log_warning "Failed to preload Grafana image"
            fi
            
            # Restart Grafana pod to use preloaded image
            log_info "Restarting Grafana pod to use preloaded image..."
            kubectl delete pod "$grafana_pod" -n monitoring --grace-period=0 --force 2>/dev/null || true
            
            # Wait for pod to be recreated and ready
            sleep 30
            wait_for_pods "monitoring" 300 "app.kubernetes.io/name=grafana"
        else
            log_info "Grafana pod is already running"
        fi
    else
        log_warning "Grafana pod not found"
    fi
    
    log_success "Grafana image pull issues fixed"
}

# Function to fix Grafana external access for remote connectivity
fix_grafana_external_access() {
    log_info "Fixing Grafana external access for remote connectivity..."
    
    # Get the server's external IP (PUBLIC_SERVER_IP from configuration)
    local external_ip="$PUBLIC_SERVER_IP"
    
    if [ -z "$external_ip" ]; then
        log_warning "PUBLIC_SERVER_IP not configured, skipping external access fix"
        return 0
    fi
    
    # Check if Grafana service exists
    if ! kubectl get svc kube-prometheus-stack-grafana -n monitoring >/dev/null 2>&1; then
        log_warning "Grafana service not found, skipping external access fix"
        return 0
    fi
    
    # For Kind clusters: patch the services to bind to external IP
    if [ "$CLUSTER_TYPE" = "kind" ]; then
        log_info "Configuring monitoring services for Kind cluster external access..."
        
        # Patch Grafana service to add external IP
        kubectl patch svc kube-prometheus-stack-grafana -n monitoring \
          -p "{\"spec\":{\"externalIPs\":[\"$external_ip\"]}}" \
          --server-side --force-conflicts 2>/dev/null && \
          log_success "Grafana service patched with external IP: $external_ip" || \
          log_warning "Failed to patch Grafana service with external IP"
        
        # Patch Prometheus service to add external IP if it exists
        if kubectl get svc kube-prometheus-stack-prometheus -n monitoring >/dev/null 2>&1; then
            kubectl patch svc kube-prometheus-stack-prometheus -n monitoring \
              -p "{\"spec\":{\"externalIPs\":[\"$external_ip\"]}}" \
              --server-side --force-conflicts 2>/dev/null && \
              log_success "Prometheus service patched with external IP: $external_ip" || \
              log_warning "Failed to patch Prometheus service with external IP"
        fi
    
    # For Minikube clusters: the services should already be accessible via minikube ip
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        log_info "Minikube cluster detected - monitoring services should be accessible via minikube IP"
        
        # Get minikube IP
        local minikube_ip=$(minikube ip 2>/dev/null || echo "")
        if [ -n "$minikube_ip" ]; then
            log_info "Minikube IP: $minikube_ip"
            
            # Get Grafana port
            local grafana_port=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
            if [ -n "$grafana_port" ]; then
                log_info "Grafana should be accessible at: http://$minikube_ip:$grafana_port"
            fi
            
            # Get Prometheus port
            local prometheus_port=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
            if [ -n "$prometheus_port" ]; then
                log_info "Prometheus should be accessible at: http://$minikube_ip:$prometheus_port"
            fi
        else
            log_warning "Could not get minikube IP"
        fi
    fi
    
    # Test connectivity if we have an external IP
    if [ -n "$external_ip" ]; then
        # Test Grafana connectivity
        local grafana_port=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
        if [ -n "$grafana_port" ]; then
            log_info "Testing Grafana connectivity at http://$external_ip:$grafana_port..."
            if curl -s -I "http://$external_ip:$grafana_port" >/dev/null 2>&1; then
                log_success "Grafana is accessible externally at http://$external_ip:$grafana_port"
            else
                log_warning "Grafana external access test failed - you may need to use SSH port forwarding"
                log_info "SSH port forwarding command: ssh -L $grafana_port:localhost:$grafana_port $USER@$external_ip"
            fi
        fi
        
        # Test Prometheus connectivity
        local prometheus_port=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
        if [ -n "$prometheus_port" ]; then
            log_info "Testing Prometheus connectivity at http://$external_ip:$prometheus_port..."
            if curl -s -I "http://$external_ip:$prometheus_port" >/dev/null 2>&1; then
                log_success "Prometheus is accessible externally at http://$external_ip:$prometheus_port"
            else
                log_warning "Prometheus external access test failed - you may need to use SSH port forwarding"
                log_info "SSH port forwarding command: ssh -L $prometheus_port:localhost:$prometheus_port $USER@$external_ip"
            fi
        fi
    fi
    
    log_success "Grafana external access configuration completed"
}


# Function to configure Prometheus datasource in Grafana
configure_prometheus_datasource() {
    log_info "Configuring Prometheus datasource in Grafana..."

    # If anonymous admin is enabled, don't rely on credentials at all.
    local admin_password=""
    local curl_auth=()
    if [ "${grafana_anonymous_admin:-false}" != true ]; then
        # Get Grafana admin credentials
        admin_password=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        
        if [ -z "$admin_password" ]; then
            log_warning "Could not get Grafana admin password from secret"
            
            # Try getting password directly from pod environment as fallback
            local pod_name=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$pod_name" ]; then
                log_info "Attempting to get password from Grafana pod environment..."
                admin_password=$(kubectl exec -n monitoring "$pod_name" -c grafana -- env 2>/dev/null | grep "^GF_SECURITY_ADMIN_PASSWORD=" | cut -d'=' -f2- || echo "")
            fi
            
            if [ -z "$admin_password" ]; then
                log_warning "Could not get Grafana admin password, datasource might already be configured"
                log_warning "Using default datasource UID 'prometheus' for dashboard"
                export PROMETHEUS_DATASOURCE_UID="prometheus"
                return 0
            fi
        fi
        curl_auth=(-u "admin:$admin_password")
    else
        log_info "Grafana anonymous Admin is enabled; configuring datasource without credentials"
    fi
    
    # Get Grafana service details (prefer NodePort if reachable, otherwise fall back to local port-forward)
    local grafana_port=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    local grafana_ip="localhost"
    local grafana_pf_pid=""
    local grafana_pf_port="31000"  # fallback local port for port-forward
    
    if [ "$CLUSTER_TYPE" = "kind" ] && [ -n "$PUBLIC_SERVER_IP" ]; then
        grafana_ip="$PUBLIC_SERVER_IP"
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        grafana_ip=$(minikube ip 2>/dev/null || echo "localhost")
    fi
    
    # Get Prometheus service details
    local prometheus_url="http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    
    # Wait for Grafana to be ready, with fallback to port-forward if NodePort is not reachable (e.g., kind)
    log_info "Waiting for Grafana to be ready..."
    local retry_count=0
    local max_retries=30
    
    while [ $retry_count -lt $max_retries ]; do
        if curl -s "${curl_auth[@]}" "http://$grafana_ip:$grafana_port/api/health" >/dev/null 2>&1; then
            log_success "Grafana is ready"
            break
        fi
        
        retry_count=$((retry_count + 1))
        
        # After a few attempts, fall back to local port-forward to ensure reachability
        if [ -z "$grafana_pf_pid" ] && [ $retry_count -eq 3 ]; then
            log_warning "Grafana not reachable via NodePort yet; starting temporary port-forward on localhost:$grafana_pf_port..."
            kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana ${grafana_pf_port}:80 >/tmp/grafana_port_forward.log 2>&1 &
            grafana_pf_pid=$!
            sleep 3
            grafana_ip="127.0.0.1"
            grafana_port="$grafana_pf_port"
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            log_info "Waiting for Grafana... (attempt $retry_count/$max_retries)"
            sleep 10
        fi
    done
    
    if [ $retry_count -eq $max_retries ]; then
        log_warning "Grafana not ready after $max_retries attempts, skipping datasource configuration"
        # Clean up port-forward if it was started
        if [ -n "$grafana_pf_pid" ]; then
            kill "$grafana_pf_pid" >/dev/null 2>&1 || true
        fi
        return 1
    fi
    
    # Check if Prometheus datasource already exists
    local existing_datasource=$(curl -s "${curl_auth[@]}" "http://$grafana_ip:$grafana_port/api/datasources" 2>/dev/null | jq -r '.[] | select(.type=="prometheus") | .uid' 2>/dev/null || echo "")
    
    local datasource_uid=""
    
    if [ -n "$existing_datasource" ]; then
        log_info "Prometheus datasource already exists with UID: $existing_datasource"
        datasource_uid="$existing_datasource"
    else
        # Create Prometheus datasource
        log_info "Creating Prometheus datasource in Grafana..."
        
        local datasource_config=$(cat <<EOF
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
        
        # Get HTTP status code along with response
        local create_response=$(curl -s -w "\n%{http_code}" -X POST "${curl_auth[@]}" \
            -H "Content-Type: application/json" \
            -d "$datasource_config" \
            "http://$grafana_ip:$grafana_port/api/datasources" 2>/dev/null)
        
        local http_code=$(echo "$create_response" | tail -n1)
        local create_body=$(echo "$create_response" | sed '$d')
        
        log_info "Grafana API response code: $http_code"
        
        # Handle different response codes and formats
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            # Try multiple extraction methods for different Grafana versions
            datasource_uid=$(echo "$create_body" | jq -r '.datasource.uid // .uid // empty' 2>/dev/null || echo "")
            
            if [ -n "$datasource_uid" ] && [ "$datasource_uid" != "null" ]; then
                log_success "Prometheus datasource created with UID: $datasource_uid"
            else
                log_warning "Could not extract UID from create response, will query existing datasources"
                datasource_uid=""
            fi
        elif [ "$http_code" = "409" ]; then
            # Datasource already exists (409 Conflict)
            log_info "Prometheus datasource already exists (HTTP 409)"
            datasource_uid=""
        else
            log_warning "Failed to create Prometheus datasource (HTTP $http_code): $create_body"
            datasource_uid=""
        fi
        
        # If we didn't get the UID from the create response, query for it
        if [ -z "$datasource_uid" ] || [ "$datasource_uid" = "null" ]; then
            log_info "Querying Grafana for existing Prometheus datasource..."
            local existing_datasources=$(curl -s "${curl_auth[@]}" "http://$grafana_ip:$grafana_port/api/datasources" 2>/dev/null)
            datasource_uid=$(echo "$existing_datasources" | jq -r '.[] | select(.type=="prometheus") | .uid' 2>/dev/null || echo "")
            
            if [ -n "$datasource_uid" ] && [ "$datasource_uid" != "null" ]; then
                log_success "Found existing Prometheus datasource UID: $datasource_uid"
            else
                log_error "Could not determine Prometheus datasource UID"
                log_info "Try manually configuring the datasource in Grafana UI"
                # Don't fail completely, just skip UID export
                datasource_uid=""
            fi
        fi
    fi
    
    # Export datasource UID for dashboard update
    export PROMETHEUS_DATASOURCE_UID="$datasource_uid"
    log_info "Prometheus datasource UID: $datasource_uid"
    
    log_success "Prometheus datasource configuration completed"
    
    # Clean up port-forward if it was started
    if [ -n "$grafana_pf_pid" ]; then
        kill "$grafana_pf_pid" >/dev/null 2>&1 || true
    fi
    return 0
}

# Function to update dashboard with correct datasource UID
update_dashboard_datasource() {
    log_info "Updating dashboard with correct Prometheus datasource UID..."
    
    # Create temporary dashboard file with updated datasource UID
    local dashboard_file="$PROJECT_ROOT/deathstar-bench/monitoring/davide-dashboard.json"
    local temp_dashboard="/tmp/davide-dashboard-updated.json"
    
    if [ ! -f "$dashboard_file" ]; then
        log_warning "Dashboard file not found: $dashboard_file"
        return 1
    fi
    
    # Use the exported UID if available, otherwise use default "prometheus"
    local dashboard_uid="${PROMETHEUS_DATASOURCE_UID:-prometheus}"
    
    if [ -z "$PROMETHEUS_DATASOURCE_UID" ]; then
        log_warning "Prometheus datasource UID not available, using default 'prometheus'"
    fi
    
    # Replace the hardcoded datasource UID with the correct one
    sed "s/prometheus/$dashboard_uid/g" "$dashboard_file" > "$temp_dashboard"
    
    # Update the ConfigMap with the corrected dashboard
    kubectl create configmap davide-dashboard \
      --from-file=davide-dashboard.json="$temp_dashboard" \
      -n monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Label ConfigMap for Grafana sidecar to pick it up
    kubectl label configmap davide-dashboard grafana_dashboard=1 -n monitoring --overwrite
    
    # Clean up temporary file
    rm -f "$temp_dashboard"
    
    log_success "Dashboard updated with datasource UID: $dashboard_uid"
}

# Function to import Davide dashboard
import_davide_dashboard() {
    log_info "Importing Davide HPA Dashboard..."
    
    # First, configure the Prometheus datasource (non-fatal)
    if ! configure_prometheus_datasource; then
        log_warning "Skipping Prometheus datasource configuration (will continue install)"
    fi
    
    # Then update the dashboard with the correct datasource UID (non-fatal)
    if ! update_dashboard_datasource; then
        log_warning "Skipping dashboard UID update (will continue install)"
    fi
    
    # Wait for dashboard to be imported
    log_info "Waiting for dashboard to be imported by Grafana..."
    sleep 15
    
    # Verify dashboard was imported
    local grafana_ip="localhost"
    if [ "$CLUSTER_TYPE" = "kind" ] && [ -n "$PUBLIC_SERVER_IP" ]; then
        grafana_ip="$PUBLIC_SERVER_IP"
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        grafana_ip=$(minikube ip 2>/dev/null || echo "localhost")
    fi
    
    local grafana_port=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30900")
    
    # Check if dashboard exists via API (best-effort; avoid credentials when anonymous Admin is enabled)
    local curl_auth=()
    if [ "${grafana_anonymous_admin:-false}" != true ]; then
        local admin_password=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ -n "${admin_password:-}" ]; then
            curl_auth=(-u "admin:${admin_password}")
        fi
    fi

    local dashboard_check=$(curl -s "${curl_auth[@]}" "http://$grafana_ip:$grafana_port/api/search?type=dash-db" 2>/dev/null | grep -q "91f6cb1c-9c6a-438b-af3b-5603e7b2db5c" && echo "true" || echo "false")
    if [ "$dashboard_check" = "true" ]; then
        log_success "Davide dashboard imported successfully with UID: 91f6cb1c-9c6a-438b-af3b-5603e7b2db5c"
        log_info "Dashboard URL: http://$grafana_ip:$grafana_port/d/91f6cb1c-9c6a-438b-af3b-5603e7b2db5c/davide-hpa-dashboard"
        log_info "Prometheus datasource UID: $PROMETHEUS_DATASOURCE_UID"
    else
        log_warning "Dashboard import verification failed, but ConfigMap was created"
    fi
    
    log_success "Davide dashboard import completed"
    
    # Also import DB monitoring dashboard
    import_db_monitoring_dashboard
}

# Function to import DB monitoring dashboard
import_db_monitoring_dashboard() {
    log_info "Importing DB Monitoring Dashboard..."
    
    if [ -z "$PROMETHEUS_DATASOURCE_UID" ]; then
        log_warning "Prometheus datasource UID not available, using dashboard with default UID"
    fi
    
    # Determine Grafana URL for logging
    local grafana_ip="localhost"
    if [ "$CLUSTER_TYPE" = "kind" ] && [ -n "$PUBLIC_SERVER_IP" ]; then
        grafana_ip="$PUBLIC_SERVER_IP"
    elif [ "$CLUSTER_TYPE" = "minikube" ]; then
        grafana_ip=$(minikube ip 2>/dev/null || echo "localhost")
    fi
    local grafana_port=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30900")
    
    # Create temporary dashboard file with updated datasource UID
    local dashboard_file="$PROJECT_ROOT/deathstar-bench/monitoring/db-monitoring-dashboard.json"
    local temp_dashboard="/tmp/db-monitoring-dashboard-updated.json"
    
    if [ ! -f "$dashboard_file" ]; then
        # This dashboard is optional – log and continue without failing the whole reset
        log_warning "DB monitoring dashboard file not found: $dashboard_file (skipping DB dashboard import)"
        return 0
    fi
    
    # Use the exported UID if available, otherwise use default "prometheus"
    local dashboard_uid="${PROMETHEUS_DATASOURCE_UID:-prometheus}"
    
    # Replace the hardcoded datasource UID with the correct one
    sed "s/prometheus/$dashboard_uid/g" "$dashboard_file" > "$temp_dashboard"
    
    # Update the ConfigMap with the corrected dashboard
    kubectl create configmap db-monitoring-dashboard \
      --from-file=db-monitoring-dashboard.json="$temp_dashboard" \
      -n monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Label ConfigMap for Grafana sidecar to pick it up
    kubectl label configmap db-monitoring-dashboard grafana_dashboard=1 -n monitoring --overwrite
    
    # Clean up temporary file
    rm -f "$temp_dashboard"
    
    log_success "DB monitoring dashboard imported successfully"
    log_info "DB Dashboard URL: http://$grafana_ip:$grafana_port/d/db-monitoring-dashboard/db-monitoring-dashboard"
}

# Function to install Prometheus Adapter
install_prometheus_adapter() {
    log_info "Installing Prometheus Adapter..."
    
    if [ "$no_dns_resolution" = true ]; then
        log_info "Using normal hostname resolution (--no-dns-resolution flag set)"
        # Install Prometheus Adapter with custom configuration using normal hostname
        helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
          -n monitoring --create-namespace \
          -f "$PROJECT_ROOT/prom/prometheus-adapter-values.yaml"
    else
        # Get Prometheus service IP to avoid DNS issues
        local prom_ip=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        
        if [ -n "$prom_ip" ]; then
            log_info "Using Prometheus IP: $prom_ip (avoiding DNS issues)"
            # Install Prometheus Adapter with custom configuration and IP-based URL
            helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
              -n monitoring --create-namespace \
              --set prometheus.url=http://$prom_ip \
              --set prometheus.port=9090 \
              -f "$PROJECT_ROOT/prom/prometheus-adapter-values.yaml"
        else
            log_warning "Could not get Prometheus IP, using default hostname"
            # Install Prometheus Adapter with custom configuration
            helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
              -n monitoring --create-namespace \
              -f "$PROJECT_ROOT/prom/prometheus-adapter-values.yaml"
        fi
    fi
    
    wait_for_pods "monitoring" 300 "app.kubernetes.io/name=prometheus-adapter"
    log_success "Prometheus Adapter installed successfully"
}

# Function to deploy Social Network application
deploy_social_network() {
    log_info "Deploying Social Network application..."
    
    # Create socialnetwork namespace first
    log_info "Creating socialnetwork namespace..."
    kubectl create namespace socialnetwork --dry-run=client -o yaml | kubectl apply -f -
    
    cd "$PROJECT_ROOT/deathstar-bench/deploy"
    
    # Make deployment script executable and run it
    chmod +x deploy_socialnetowrk.sh
    ./deploy_socialnetowrk.sh
    
    # Wait for social network pods to be ready with better error handling
    log_info "Waiting for social network pods to be ready..."
    wait_for_pods "socialnetwork" 900 "" "jaeger"
    
    log_success "Social Network application deployed successfully"
}

# Function to fix GitHub URLs in running deployments
fix_github_urls_in_deployments() {
    log_info "Fixing GitHub URLs in running deployments..."
    
    # Fix nginx-thrift deployment
    if kubectl get deployment nginx-thrift -n socialnetwork >/dev/null 2>&1; then
        log_info "Fixing nginx-thrift deployment GitHub URL..."
        kubectl patch deployment nginx-thrift -n socialnetwork --type='json' \
          -p='[{"op": "replace", "path": "/spec/template/spec/initContainers/0/args/1", 
               "value": "git clone https://github.com/delimitrou/DeathStarBench.git /DeathStarBench && cp -r /DeathStarBench/socialNetwork/gen-lua/* /gen-lua/ && cp -r /DeathStarBench/socialNetwork/docker/openresty-thrift/lua-thrift/* /lua-thrift/ && cp -r /DeathStarBench/socialNetwork/nginx-web-server/lua-scripts/* /lua-scripts/ && cp -r /DeathStarBench/socialNetwork/nginx-web-server/pages/* /pages/ && cp /DeathStarBench/socialNetwork/keys/* /keys/"}]' \
          2>/dev/null && log_success "Fixed nginx-thrift GitHub URL" || log_warning "Failed to fix nginx-thrift GitHub URL"
    fi
    
    # Fix media-frontend deployment
    if kubectl get deployment media-frontend -n socialnetwork >/dev/null 2>&1; then
        log_info "Fixing media-frontend deployment GitHub URL..."
        kubectl patch deployment media-frontend -n socialnetwork --type='json' \
          -p='[{"op": "replace", "path": "/spec/template/spec/initContainers/0/args/1", 
               "value": "git clone https://github.com/delimitrou/DeathStarBench.git /DeathStarBench && cp -r /DeathStarBench/socialNetwork/media-frontend/lua-scripts/* /lua-scripts/"}]' \
          2>/dev/null && log_success "Fixed media-frontend GitHub URL" || log_warning "Failed to fix media-frontend GitHub URL"
    fi
}

# Function to fix GitHub URLs in Helm chart values files
fix_github_urls_in_helm_charts() {
    log_info "Fixing GitHub URLs in Helm chart values files..."
    
    # Check if DeathStarBench directory exists (deployment script clones it to $HOME/DeathStarBench)
    local DEATHSTARBENCH_PATH="$HOME/DeathStarBench"
    if [ ! -d "$DEATHSTARBENCH_PATH" ]; then
        log_warning "DeathStarBench directory not found at $DEATHSTARBENCH_PATH"
        log_info "This is normal if the deployment script hasn't cloned the repository yet"
        return 0
    fi
    
    # Fix nginx-thrift values.yaml
    if [ -f "$DEATHSTARBENCH_PATH/socialNetwork/helm-chart/socialnetwork/charts/nginx-thrift/values.yaml" ]; then
        sed -i 's/dimoibiehg/delimitrou/g' "$DEATHSTARBENCH_PATH/socialNetwork/helm-chart/socialnetwork/charts/nginx-thrift/values.yaml"
        log_success "Fixed nginx-thrift GitHub URL in Helm chart"
    else
        log_info "nginx-thrift values.yaml not found, skipping"
    fi
    
    # Fix media-frontend values.yaml
    if [ -f "$DEATHSTARBENCH_PATH/socialNetwork/helm-chart/socialnetwork/charts/media-frontend/values.yaml" ]; then
        sed -i 's/dimoibiehg/delimitrou/g' "$DEATHSTARBENCH_PATH/socialNetwork/helm-chart/socialnetwork/charts/media-frontend/values.yaml"
        log_success "Fixed media-frontend GitHub URL in Helm chart"
    else
        log_info "media-frontend values.yaml not found, skipping"
    fi
    
    # Also check for any other files that might contain the incorrect URL
    if [ -d "$DEATHSTARBENCH_PATH" ]; then
        find "$DEATHSTARBENCH_PATH" -name "*.yaml" -o -name "*.yml" 2>/dev/null | xargs grep -l "dimoibiehg" 2>/dev/null | while read file; do
            log_info "Fixing GitHub URL in: $file"
            sed -i 's/dimoibiehg/delimitrou/g' "$file"
        done
    fi
}

# Function to restart pods that had image pull issues
restart_pods_with_pull_issues() {
    log_info "Restarting pods that had image pull issues now that DNS is fixed..."
    
    # Get pods with image pull issues
    local pull_issue_pods=$(kubectl get pods -n socialnetwork --no-headers | grep -E "(ImagePullBackOff|ErrImagePull|Init:ImagePullBackOff|Init:ErrImagePull)" | awk '{print $1}')
    
    if [ -n "$pull_issue_pods" ]; then
        log_info "Found pods with image pull issues, restarting them..."
        echo "$pull_issue_pods" | while read pod; do
            if [ -n "$pod" ]; then
                log_info "Restarting pod with image pull issues: $pod"
                kubectl delete pod "$pod" -n socialnetwork --grace-period=0 --force 2>/dev/null || true
            fi
        done
        
        # Wait for pods to be recreated and ready
        log_info "Waiting for restarted pods to be ready..."
        sleep 30
        wait_for_pods "socialnetwork" 600 "" "jaeger"
    else
        log_info "No pods with image pull issues found"
    fi
}

# Function to fix init container issues that require DNS/GitHub access
fix_init_container_issues() {
    log_info "Fixing init container issues that require DNS/GitHub access..."
    
    # Check if nginx-thrift and media-frontend deployments exist and have init containers
    if kubectl get deployment nginx-thrift -n socialnetwork >/dev/null 2>&1; then
        local has_init_containers=$(kubectl get deployment nginx-thrift -n socialnetwork -o jsonpath='{.spec.template.spec.initContainers}' 2>/dev/null | wc -c)
        if [ "$has_init_containers" -gt 2 ]; then
            log_info "Removing problematic init containers from nginx-thrift deployment..."
            kubectl patch deployment nginx-thrift -n socialnetwork --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]' || log_warning "Failed to remove init containers from nginx-thrift"
        fi
    fi
    
    if kubectl get deployment media-frontend -n socialnetwork >/dev/null 2>&1; then
        local has_init_containers=$(kubectl get deployment media-frontend -n socialnetwork -o jsonpath='{.spec.template.spec.initContainers}' 2>/dev/null | wc -c)
        if [ "$has_init_containers" -gt 2 ]; then
            log_info "Removing problematic init containers from media-frontend deployment..."
            kubectl patch deployment media-frontend -n socialnetwork --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]' || log_warning "Failed to remove init containers from media-frontend"
        fi
    fi
    
    log_success "Init container issues fixed"
}

# Function to fix DNS policy issues in deployments
fix_dns_policy_issues() {
    log_info "Fixing DNS policy issues in deployments..."
    
    # Fix nginx-thrift deployment DNS policy
    if kubectl get deployment nginx-thrift -n socialnetwork >/dev/null 2>&1; then
        log_info "Fixing DNS policy for nginx-thrift deployment..."
        kubectl patch deployment nginx-thrift -n socialnetwork --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/dnsPolicy"}, {"op": "remove", "path": "/spec/template/spec/dnsConfig"}]' || log_warning "Failed to fix nginx-thrift DNS policy"
    fi
    
    # Fix media-frontend deployment DNS policy
    if kubectl get deployment media-frontend -n socialnetwork >/dev/null 2>&1; then
        log_info "Fixing DNS policy for media-frontend deployment..."
        kubectl patch deployment media-frontend -n socialnetwork --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/dnsPolicy"}, {"op": "remove", "path": "/spec/template/spec/dnsConfig"}]' || log_warning "Failed to fix media-frontend DNS policy"
    fi
    
    log_success "DNS policy issues fixed"
}

# Function to fix nginx configuration issues
fix_nginx_configuration_issues() {
    log_info "Fixing nginx configuration issues..."
    
    # Fix nginx-thrift configuration
    if kubectl get configmap nginx-thrift -n socialnetwork >/dev/null 2>&1; then
        log_info "Applying simplified nginx configuration for nginx-thrift..."
        kubectl patch configmap nginx-thrift -n socialnetwork --type='json' -p='[{"op": "replace", "path": "/data/nginx.conf", "value": "worker_processes  auto;\n\nevents {\n  use epoll;\n  worker_connections  1024;\n}\n\nhttp {\n  include       mime.types;\n  default_type  application/octet-stream;\n\n  sendfile        on;\n  tcp_nopush      on;\n  tcp_nodelay     on;\n\n  keepalive_timeout  120s;\n  keepalive_requests 100000;\n\n  server {\n    listen       8080;\n    server_name  localhost;\n\n    location / {\n      return 200 \"nginx-thrift is running\";\n      add_header Content-Type text/plain;\n    }\n  }\n}\n"}]' || log_warning "Failed to fix nginx-thrift configuration"
        
        # Disable jaeger tracing
        log_info "Disabling jaeger tracing for nginx-thrift..."
        kubectl patch configmap nginx-thrift -n socialnetwork --type='json' -p='[{"op": "replace", "path": "/data/jaeger-config.json", "value": "{\n  \"service_name\": \"nginx-web-server\",\n  \"disabled\": true,\n  \"reporter\": {\n    \"logSpans\": false,\n    \"localAgentHostPort\": \"jaeger:6831\",\n    \"queueSize\": 1000000,\n    \"bufferFlushInterval\": 10\n  },\n  \"sampler\": {\n    \"type\": \"probabilistic\",\n    \"param\": 0.1\n  }\n}\n"}]' || log_warning "Failed to disable jaeger tracing"
    fi
    
    # Fix media-frontend configuration
    if kubectl get configmap media-frontend -n socialnetwork >/dev/null 2>&1; then
        log_info "Fixing resolver configuration for media-frontend..."
        kubectl get configmap media-frontend -n socialnetwork -o yaml | sed 's/resolver kube-dns.kube-system.svc.cluster.local valid=10s ipv6=off;/resolver 127.0.0.11 valid=10s ipv6=off;/' | kubectl apply -f - || log_warning "Failed to fix media-frontend resolver"
    fi
    
    log_success "Nginx configuration issues fixed"
}

# Function to apply HPA configurations
apply_hpa_configs() {
    log_info "Applying HPA configurations..."
    
    # Apply service CPU requests (required for external metrics)
    # Use server-side apply to handle Helm-managed deployments properly
    log_info "Applying CPU resource requests for deployments..."
    kubectl apply -f "$PROJECT_ROOT/deathstar-bench/hpa/service_values.yaml" -n socialnetwork --server-side --force-conflicts
    
    log_info "Applying DB resource limits (MongoDB memory/CPU)..."
    kubectl apply -f "$PROJECT_ROOT/deathstar-bench/hpa/db_resource_values.yaml" -n socialnetwork --server-side --force-conflicts
    
    # Apply default HPA configuration
    kubectl apply -f "$PROJECT_ROOT/deathstar-bench/hpa/default_hpa.yaml" -n socialnetwork
    
    log_success "HPA configurations applied successfully"
}

# Function to verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check cluster nodes
    log_info "Cluster nodes:"
    kubectl get nodes
    
    # Check namespaces
    log_info "Namespaces:"
    kubectl get namespaces
    
    # Check monitoring pods
    log_info "Monitoring pods:"
    kubectl get pods -n monitoring
    
    # Check social network pods
    log_info "Social network pods:"
    kubectl get pods -n socialnetwork
    
    # Check HPA status
    log_info "HPA status:"
    kubectl get hpa -n socialnetwork
    
    # Check external metrics API
    log_info "External metrics API:"
    kubectl get apiservice | grep external.metrics || log_warning "External metrics API not available yet"
    
    # Test DNS resolution
    test_dns_resolution
    
    # Get service ports
    log_info "Service ports:"
    cd "$PROJECT_ROOT/deathstar-bench/deploy"
    chmod +x fetch_ports.sh
    ./fetch_ports.sh
    
    log_success "Installation verification completed"
}

# Function to display usage
usage() {
    echo "Usage: $0 --cluster-type <kind|minikube> [OPTIONS]"
    echo ""
    echo "Complete testbed reset and reinstall script"
    echo ""
    echo "REQUIRED OPTIONS:"
    echo "  --cluster-type       Cluster type to use: 'kind' or 'minikube'"
    echo ""
    echo "OPTIONAL OPTIONS:"
    echo "  --skip-monitoring    Preserve monitoring stack, only reset socialnetwork namespace (faster)"
    echo "  --skip-social        Skip social network application deployment"
    echo "  --skip-hpa           Skip HPA configuration"
    echo "  --clean-only         Only cleanup, don't reinstall"
    echo "  --preload-images     Preload ALL Docker images (essential + social network) to avoid pull issues"
    echo "  --no-dns-resolution  Skip DNS workarounds and use normal hostname resolution (for environments without DNS issues)"
    echo "  --persist-monitoring-data  Persist Prometheus/Grafana data across resets (Kind only)"
    echo "  --remote-write-url   Optional Prometheus remote_write URL (e.g., http://vm:8428/api/v1/write)"
    echo "  --print-grafana-password  Print Grafana admin password to the reset log (use with care)"
    echo "  --grafana-require-login   Disable anonymous access (require login)"
    echo "  --help               Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  CLUSTER_NAME         Cluster name (default: socialnetwork)"
    echo "  PROJECT_ROOT         Override repo root (default: derived from script location)"
    echo ""
    echo "Image Caching:"
    echo "  Images are cached in ./docker_images/ directory to avoid repeated downloads."
    echo "  Script checks Docker's local registry first, then cache directory, then downloads."
    echo "  By default, NO images are preloaded - use --preload-images to preload all images."
    echo ""
    echo "Examples:"
    echo "  $0 --cluster-type kind --preload-images"
    echo "  $0 --cluster-type minikube --skip-monitoring    # Fast reset: preserve monitoring, only reset socialnetwork"
    echo "  $0 --cluster-type minikube --skip-social         # Only reset monitoring, skip social network"
    echo "  $0 --cluster-type minikube --no-dns-resolution  # Skip DNS workarounds for environments without DNS issues"
    echo ""
}

# Main function
main() {
    local skip_monitoring=false
    local skip_social=false
    local skip_hpa=false
    local clean_only=false
    local preload_images=false
    local no_dns_resolution=false
    local persist_monitoring_data=false
    local remote_write_url=""
    local print_grafana_password=false
    # Default: no-login Grafana (anonymous Admin). Use --grafana-require-login to disable.
    local grafana_anonymous_admin=true
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-type)
                CLUSTER_TYPE="$2"
                shift 2
                ;;
            --skip-monitoring)
                skip_monitoring=true
                shift
                ;;
            --skip-social)
                skip_social=true
                shift
                ;;
            --skip-hpa)
                skip_hpa=true
                shift
                ;;
            --clean-only)
                clean_only=true
                shift
                ;;
            --preload-images)
                preload_images=true
                shift
                ;;
            --no-dns-resolution)
                no_dns_resolution=true
                shift
                ;;
            --persist-monitoring-data)
                persist_monitoring_data=true
                shift
                ;;
            --remote-write-url)
                remote_write_url="$2"
                shift 2
                ;;
            --print-grafana-password)
                print_grafana_password=true
                shift
                ;;
            --grafana-anonymous-admin)
                # Backwards-compatible alias (now default)
                grafana_anonymous_admin=true
                shift
                ;;
            --grafana-require-login)
                grafana_anonymous_admin=false
                shift
                ;;
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
    
    # Validate required parameters
    if [ -z "$CLUSTER_TYPE" ]; then
        log_error "Cluster type is required. Use --cluster-type <kind|minikube>"
        usage
        exit 1
    fi
    
    if [ "$CLUSTER_TYPE" != "kind" ] && [ "$CLUSTER_TYPE" != "minikube" ]; then
        log_error "Invalid cluster type: $CLUSTER_TYPE. Must be 'kind' or 'minikube'"
        usage
        exit 1
    fi
    
    log_info "Starting testbed reset..."
    log_info "Cluster type: $CLUSTER_TYPE"
    log_info "Cluster name: $CLUSTER_NAME"
    log_info "Project root: $PROJECT_ROOT"
    if [ "$no_dns_resolution" = true ]; then
        log_info "DNS resolution: Normal (no workarounds)"
    else
        log_info "DNS resolution: With workarounds for DNS issues"
    fi
    
    # Change to project directory
    cd "$PROJECT_ROOT"
    
    # Install prerequisites
    install_prerequisites
    
    # Cleanup existing cluster
    cleanup_cluster
    
    if [ "$clean_only" = true ]; then
        log_success "Cleanup completed. Exiting."
        exit 0
    fi
    
    # Skip cluster recreation if monitoring is preserved
    if [ "$skip_monitoring" = true ]; then
        log_info "Skipping cluster recreation (monitoring preserved)"
        log_info "Proceeding directly to social network deployment..."
    else
        # Create new cluster (only in full reset mode)
        create_cluster
        
        # Preload images based on flags
        if [ "$preload_images" = true ]; then
            log_info "Preloading all images to avoid DNS/pull issues..."
            preload_all_images
        else
            log_info "Skipping image preloading (use --preload-images if you encounter pull issues)"
            log_info "Images will be pulled normally during deployment"
        fi
    fi
    
    # Install monitoring components (needed for observing HPA behavior)
    if [ "$skip_monitoring" = false ]; then
        # Install metrics server (required for monitoring stack)
        install_metrics_server
        install_monitoring
        install_prometheus_adapter
    else
        log_info "Preserving existing monitoring stack (--skip-monitoring flag set)"
        log_info "Monitoring stack should already be running from previous installation"
        # Ensure port-forwarding is running in background even when preserving monitoring
        start_port_forward_background
    fi

    # Print Grafana credentials to logs (best-effort). Password is only printed if explicitly requested.
    if kubectl get ns monitoring >/dev/null 2>&1; then
        print_grafana_credentials "$print_grafana_password" || true
    fi
    
    # Deploy social network application (if not skipped)
    if [ "$skip_social" = false ]; then
        deploy_social_network
    else
        log_info "Skipping social network application deployment"
    fi
    
    # Apply HPA configurations (if not skipped)
    if [ "$skip_hpa" = false ]; then
        if [ "$skip_monitoring" = false ]; then
            log_info "Applying HPA configurations (both default and context-aware available)"
        else
            log_info "Applying HPA configurations (monitoring preserved from previous installation)"
        fi
        apply_hpa_configs
    else
        log_info "Skipping HPA configuration"
    fi
    
    # Verify installation
    verify_installation
    
    log_success "Testbed reset completed successfully!"
    log_info "You can now run your tests using the hpa_comparison_test.sh script"
}

# Run main function with all arguments
main "$@"






