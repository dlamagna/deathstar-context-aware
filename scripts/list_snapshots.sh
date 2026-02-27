#!/bin/bash

# list_snapshots.sh - List available Prometheus snapshots

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

SNAPSHOT_DIR="$PROJECT_ROOT/snapshots"

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "List available Prometheus snapshots"
    echo ""
    echo "OPTIONS:"
    echo "  --help               Show this help message"
    echo ""
    echo "Snapshots are stored in: $SNAPSHOT_DIR/"
    echo ""
}

# Function to list snapshots
list_snapshots() {
    log_info "Available Prometheus snapshots:"
    echo ""
    
    if [ ! -d "$SNAPSHOT_DIR" ]; then
        log_warning "Snapshot directory not found: $SNAPSHOT_DIR"
        log_info "No snapshots available. Create one with: --create-snapshot"
        return 0
    fi
    
    local snapshot_count=0
    
    for snapshot in "$SNAPSHOT_DIR"/*; do
        if [ -d "$snapshot" ]; then
            local snapshot_name=$(basename "$snapshot")
            local info_file="$snapshot/snapshot_info.json"
            
            echo "📊 Snapshot: $snapshot_name"
            
            if [ -f "$info_file" ]; then
                local created_at=$(jq -r '.created_at' "$info_file" 2>/dev/null || echo "unknown")
                local cluster_type=$(jq -r '.cluster_type' "$info_file" 2>/dev/null || echo "unknown")
                local cluster_name=$(jq -r '.cluster_name' "$info_file" 2>/dev/null || echo "unknown")
                
                echo "   Created: $created_at"
                echo "   Cluster: $cluster_type ($cluster_name)"
            else
                echo "   Created: unknown"
            fi
            
            if [ -f "$snapshot/restore.sh" ]; then
                echo "   Restore: cd $snapshot && ./restore.sh"
            fi
            
            echo ""
            snapshot_count=$((snapshot_count + 1))
        fi
    done
    
    if [ $snapshot_count -eq 0 ]; then
        log_warning "No snapshots found in $SNAPSHOT_DIR"
        log_info "Create a snapshot with: ./reset_testbed.sh --cluster-type kind --create-snapshot"
    else
        log_success "Found $snapshot_count snapshot(s)"
    fi
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
    
    list_snapshots
}

# Run main function
main "$@"



