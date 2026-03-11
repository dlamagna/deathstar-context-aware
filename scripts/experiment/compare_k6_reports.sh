#!/bin/bash

# Compare two existing k6 CSV reports, generate enhanced reports (Prometheus),
# and produce comparison outputs and plots (mirrors logic from hpa_comparison_test.sh).
#
# Usage:
#   ./compare_k6_reports.sh <REPORT_A.csv> <REPORT_B.csv> [--prom-url URL] [--namespace NAMESPACE] [--services "svc1 svc2 ..."] [--skip-enhanced] [--sample N]
#
# Examples:
#   ./compare_k6_reports.sh k6/reports/default.csv k6/reports/adapter.csv
#   ./compare_k6_reports.sh a.csv b.csv --prom-url http://10.96.0.1:9090
#   ./compare_k6_reports.sh a.csv b.csv --sample 10000

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

show_usage() {
    echo "Usage: $0 <REPORT_A.csv> <REPORT_B.csv> [--prom-url URL] [--namespace NAMESPACE] [--services \"svc1 svc2 ...\"] [--skip-enhanced] [--sample N]"
    exit 1
}

RUN_ENHANCED=true
PROM_URL=""
NAMESPACE="socialnetwork"
SERVICES="nginx-thrift compose-post-service text-service user-mention-service"
SAMPLE_SIZE=""

# Parse positional and flags
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prom-url)
            PROM_URL="$2"; shift; shift ;;
        --namespace)
            NAMESPACE="$2"; shift; shift ;;
        --services)
            SERVICES="$2"; shift; shift ;;
        --skip-enhanced)
            RUN_ENHANCED=false; shift ;;
        --sample)
            SAMPLE_SIZE="$2"; shift; shift ;;
        --help|-h)
            show_usage ;;
        *)
            POS+=("$1"); shift ;;
    esac
done

if [ ${#POS[@]} -ne 2 ]; then
    show_usage
fi

REPORT_A="${POS[0]}"
REPORT_B="${POS[1]}"

if [ ! -f "$REPORT_A" ]; then print_error "Report A not found: $REPORT_A"; exit 1; fi
if [ ! -f "$REPORT_B" ]; then print_error "Report B not found: $REPORT_B"; exit 1; fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Logging to file as well
LOG_FILE="$LOG_DIR/compare_k6_${TIMESTAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_status "Report A: $REPORT_A"
print_status "Report B: $REPORT_B"

run_with_logging() {
    local cmd="$1"
    local desc="$2"
    print_status "Running: $desc"
    print_status "Command: $cmd"
    eval "$cmd"
}

get_prometheus_url() {
    if [ -n "$PROM_URL" ]; then echo "$PROM_URL"; return; fi
    # port-forward.sh maps kube-prometheus-stack to localhost:9091
    for port in 9091 9090; do
        if curl -sS --max-time 3 "http://127.0.0.1:${port}/api/v1/query?query=up" >/dev/null 2>&1; then
            echo "http://127.0.0.1:${port}"
            return
        fi
    done
    # Try clusterIP (avoid DNS issues)
    local svc_ip=$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -n "$svc_ip" ]; then echo "http://$svc_ip:9090"; else echo "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"; fi
}

check_prometheus() {
    local url="$1"
    print_status "Checking Prometheus at $url ..."
    if curl -sS --max-time 3 "$url/api/v1/query?query=up" >/dev/null 2>&1; then
        print_success "Prometheus is accessible at $url"
        return 0
    fi
    # Fallback: verify in-cluster reachability
    if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running; then
        print_success "Prometheus pod is running"
        if kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- wget -qO- "$url/api/v1/query?query=up" >/dev/null 2>&1; then
            print_success "Prometheus API is accessible"
            return 0
        fi
    fi
    print_warning "Prometheus not accessible; enhanced reports may be skipped"
    return 1
}

install_python_dependencies() {
    print_status "Checking Python dependencies..."
    if ! command -v pip3 >/dev/null 2>&1; then
        print_error "pip3 not found. Install with: sudo apt install python3-pip"; exit 1
    fi
    if python3 -c "import pandas, numpy, matplotlib" 2>/dev/null; then
        print_success "Python deps already installed"; return 0
    fi
    if [ -f "$PROJECT_ROOT/k6/requirements.txt" ]; then
        run_with_logging "pip3 install -r \"$PROJECT_ROOT/k6/requirements.txt\" --quiet" "pip install from k6/requirements.txt"
    else
        run_with_logging "pip3 install pandas numpy matplotlib --quiet" "pip install basic deps"
    fi
}

main() {
    install_python_dependencies

    # Prepare working dirs
    mkdir -p "$PROJECT_ROOT/k6/reports" "$PROJECT_ROOT/k6/reports/enhanced" "$PROJECT_ROOT/k6/plots"

    # Derive names and absolute paths from original CSVs
    A_BASE="$(basename "$REPORT_A")"
    B_BASE="$(basename "$REPORT_B")"
    A_BASE_NOEXT="${A_BASE%.csv}"
    B_BASE_NOEXT="${B_BASE%.csv}"
    A_ABS="$(readlink -f "$REPORT_A")"
    B_ABS="$(readlink -f "$REPORT_B")"

    pushd "$PROJECT_ROOT/k6" >/dev/null

    local prom_url=$(get_prometheus_url)
    if [ "$RUN_ENHANCED" = true ]; then
        if check_prometheus "$prom_url"; then
            print_status "Generating enhanced reports..."
            local cmd1="python3 enhanced_report.py --k6-csv \"$A_ABS\" --prom \"$prom_url\" --namespace \"$NAMESPACE\" --services $SERVICES --bucket-sec 15 --out \"reports/enhanced/${A_BASE_NOEXT}_enhanced.csv\""
            local cmd2="python3 enhanced_report.py --k6-csv \"$B_ABS\" --prom \"$prom_url\" --namespace \"$NAMESPACE\" --services $SERVICES --bucket-sec 15 --out \"reports/enhanced/${B_BASE_NOEXT}_enhanced.csv\""
            run_with_logging "$cmd1" "Enhanced report A"
            run_with_logging "$cmd2" "Enhanced report B"
            print_success "Enhanced reports generated in k6/reports/enhanced"
        else
            print_warning "Skipping enhanced report generation (Prometheus not available)"
        fi
    else
        print_status "--skip-enhanced set: skipping enhanced reports"
    fi

    print_status "Running k6 CSV comparison and plotting..."
    # Use absolute paths for inputs; write comparison JSON under k6/reports with descriptive name
    local cmp_out="reports/${A_BASE_NOEXT}_vs_${B_BASE_NOEXT}_comparison_${TIMESTAMP}.json"
    local cmp_cmd="python3 k6_report_comparison.py --a \"$A_ABS\" --b \"$B_ABS\" --out \"$cmp_out\""
    if [ -n "$SAMPLE_SIZE" ]; then
        cmp_cmd+=" --sample $SAMPLE_SIZE"
    fi
    run_with_logging "$cmp_cmd" "k6 report comparison"

    # Run latency breakdown comparison
    print_status "Running latency breakdown comparison..."
    popd >/dev/null
    local latency_cmp_dir="k6/comparison_output"
    mkdir -p "$PROJECT_ROOT/$latency_cmp_dir"
    
    # Determine Prometheus URL for latency breakdown comparison
    local latency_prom_url=""
    if [ -n "$PROM_URL" ]; then
        latency_prom_url="$PROM_URL"
    else
        latency_prom_url=$(get_prometheus_url)
        if ! check_prometheus "$latency_prom_url" 2>/dev/null; then
            latency_prom_url=""
        fi
    fi
    
    local latency_cmp_cmd="python3 ${PROJECT_ROOT}/python/compare_latency_breakdown.py \
        --k6-csv1 \"$A_ABS\" \
        --k6-csv2 \"$B_ABS\" \
        --name1 \"${A_BASE_NOEXT}\" \
        --name2 \"${B_BASE_NOEXT}\" \
        --bucket-sec 30 \
        --out-dir \"${PROJECT_ROOT}/$latency_cmp_dir\""
    
    if [ -n "$latency_prom_url" ]; then
        latency_cmp_cmd+=" --prom \"$latency_prom_url\" --namespace \"$NAMESPACE\" --services $SERVICES"
    fi
    
    if run_with_logging "$latency_cmp_cmd" "Latency breakdown comparison"; then
        print_success "Latency breakdown comparison completed"
    else
        print_warning "Latency breakdown comparison failed (non-fatal)"
    fi

    print_success "Comparison complete"
    print_status "Outputs:"
    echo "  - A CSV: $REPORT_A"
    echo "  - B CSV: $REPORT_B"
    echo "  - Comparison JSON: $cmp_out"
    echo "  - Plots dir: k6/plots/"
    echo "  - Enhanced (if generated): k6/reports/enhanced/"
    echo "  - Latency breakdown comparison: $latency_cmp_dir/"
}

main "$@"


