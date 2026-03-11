#!/bin/bash

# Port forwarding script for nginx-thrift, prometheus, and jaeger services
# All services run in parallel within the same session

echo "🚀 Starting port forwarding for all services..."

# Function to get Grafana credentials
get_grafana_credentials() {
    echo "🔐 Retrieving Grafana credentials..."
    
    # Try to get credentials from the secret
    GRAFANA_USER=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 --decode 2>/dev/null || echo "admin")
    GRAFANA_PASS=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 --decode 2>/dev/null || echo "admin")
    
    # Fallback to default credentials if secret retrieval fails
    if [ -z "$GRAFANA_USER" ] || [ -z "$GRAFANA_PASS" ]; then
        GRAFANA_USER="admin"
        GRAFANA_PASS="admin"
    fi
    
    echo "📋 Grafana Login Credentials:"
    echo "   👤 Username: $GRAFANA_USER"
    echo "   🔑 Password: $GRAFANA_PASS"
    echo ""
}

# Function to kill processes using specific ports
kill_port_processes() {
    local ports=("8080" "9091" "16686" "30900")
    echo "🧹 Cleaning up any existing processes on ports 8080, 9091, 16686, 30900..."
    
    for port in "${ports[@]}"; do
        # Find processes using the port and kill them
        local pids=$(lsof -ti:$port 2>/dev/null || true)
        if [ -n "$pids" ]; then
            echo "   Killing processes on port $port: $pids"
            echo "$pids" | xargs -r kill -9 2>/dev/null || true
        fi
    done
    
    # Wait a moment for ports to be released
    sleep 2
}

# Function to handle cleanup on script exit
cleanup() {
    echo "🛑 Stopping all port forwarding processes..."
    jobs -p | xargs -r kill
    exit 0
}

# Set up signal handlers for graceful shutdown
trap cleanup SIGINT SIGTERM

# Get Grafana credentials
get_grafana_credentials

# Clean up any existing processes on our target ports
kill_port_processes

# Start nginx-thrift port forwarding (port 8080)
echo "📡 Forwarding nginx-thrift (socialnetwork/nginx-thrift:8080 -> localhost:8080)"
kubectl port-forward -n socialnetwork svc/nginx-thrift 8080:8080 --address=0.0.0.0 &
NGINX_PID=$!

# Start prometheus port forwarding (port 9091 to avoid conflict)
echo "📊 Forwarding prometheus (monitoring/kube-prometheus-stack-prometheus:9090 -> localhost:9091)"
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9091:9090 --address=0.0.0.0 &
PROMETHEUS_PID=$!

# Start jaeger port forwarding (port 16686)
echo "🔍 Forwarding jaeger (socialnetwork/jaeger:16686 -> localhost:16686)"
kubectl port-forward -n socialnetwork svc/jaeger 16686:16686 --address=0.0.0.0 &
JAEGER_PID=$!

# Start grafana port forwarding (port 30900 - original working port)
echo "📈 Forwarding grafana (monitoring/kube-prometheus-stack-grafana:80 -> localhost:30900)"
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 30900:80 --address=0.0.0.0 &
GRAFANA_PID=$!

echo ""
echo "✅ All services are now accessible at:"
echo "   🌐 nginx-thrift:  http://147.83.130.68:8080"
echo "   📊 prometheus:    http://147.83.130.68:9091"
echo "   🔍 jaeger:       http://147.83.130.68:16686"
echo "   📈 grafana:      http://147.83.130.68:30900"
echo ""
echo "Press Ctrl+C to stop all port forwarding processes..."

# Wait for all background processes
wait