#!/usr/bin/env bash
set -euo pipefail

# Deploy Context-Aware HPA backed by Prometheus Adapter external metrics
# Prereqs: kubectl, helm installed; cluster context configured

# Config
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"
MON_NS="monitoring"
SOCIAL_NS="socialnetwork"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROM_ADAPTER_VALUES="${ROOT_DIR}/prom/prometheus-adapter-values.yaml"
SERVICE_VALUES="${ROOT_DIR}/deathstar-bench/hpa/service_values.yaml"
CONTEXT_HPA_VALUES="${ROOT_DIR}/deathstar-bench/hpa/hpa_values.yaml"
DEFAULT_HPA_VALUES="${ROOT_DIR}/deathstar-bench/hpa/default_hpa.yaml"

export KUBECONFIG="$KUBECONFIG_PATH"

usage() {
  echo "Usage: $0 <command>"
  echo
  echo "Commands:"
  echo "  full-setup       Install/upgrade monitoring + adapter, then apply context-aware HPA"
  echo "  apply-context    Apply context-aware HPA only (and service values)"
  echo "  apply-default    Apply default CPU HPA only"
  echo "  help             Show this help"
}

cmd=${1:-full-setup}

case "$cmd" in
  help|-h|--help)
    usage
    exit 0
    ;;

  full-setup)
    echo "[1/8] Adding/Updating Helm repos..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1

    echo "[2/8] Installing metrics-server (server-side apply) ..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --server-side --force-conflicts

    echo "[3/8] Patching metrics-server args to allow insecure kubelet TLS ..."
    kubectl -n kube-system patch deployment metrics-server \
      --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--cert-dir=/tmp","--secure-port=4443","--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"]}]' || true

    echo "[4/8] Installing kube-state-metrics in namespace ${MON_NS} ..."
    helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
      -n "$MON_NS" --create-namespace

    echo "[5/8] Installing kube-prometheus-stack (Prometheus Operator stack) ..."
    # Disable Grafana here if you already have a separate Grafana
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      -n "$MON_NS" --create-namespace \
      --set grafana.enabled=false

    echo "[6/8] Installing/Upgrading Prometheus Adapter with external metric rules ..."
    if [[ ! -f "$PROM_ADAPTER_VALUES" ]]; then
      echo "Values file not found: $PROM_ADAPTER_VALUES" >&2
      exit 1
    fi
    helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
      -n "$MON_NS" --create-namespace \
      -f "$PROM_ADAPTER_VALUES"

    echo "[7/8] Applying service CPU request overrides (required for metric denominator) ..."
    kubectl apply -f "$SERVICE_VALUES" -n "$SOCIAL_NS"

    echo "[8/8] Applying HPAs that use external metrics ..."
    kubectl apply -f "$CONTEXT_HPA_VALUES" -n "$SOCIAL_NS"

    echo
    echo "Verification tips:"
    echo "- Check pods in monitoring: kubectl get pods -n ${MON_NS}"
    echo "- External metrics list: kubectl get --raw \"/apis/external.metrics.k8s.io/v1beta1\" | jq ."
    echo "- Query a metric (example): kubectl get --raw \"/apis/external.metrics.k8s.io/v1beta1/namespaces/${SOCIAL_NS}/nginx_thrift_cpu_utilization_pct\" | jq ."
    echo "- HPAs: kubectl get hpa -n ${SOCIAL_NS}; kubectl describe hpa -n ${SOCIAL_NS}"
    echo "Done."
    ;;

  apply-context)
    echo "Applying service values (requests) ..."
    kubectl apply -f "$SERVICE_VALUES" -n "$SOCIAL_NS"
    echo "Applying context-aware HPAs ..."
    kubectl apply -f "$CONTEXT_HPA_VALUES" -n "$SOCIAL_NS"
    echo "Done."
    ;;

  apply-default)
    echo "Applying default CPU-based HPAs ..."
    kubectl apply -f "$DEFAULT_HPA_VALUES" -n "$SOCIAL_NS"
    echo "Done."
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo >&2
    usage
    exit 2
    ;;
esac