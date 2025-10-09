# DeathstarBench Deployment

This repository provides scripts to deploy the **Social Network** application from the [DeathStarBench](https://github.com/delimitrou/DeathStarBench) benchmark suite on a **Kubernetes cluster**, along with optional **monitoring** tools and our **Context-Aware HPA** (Horizontal Pod Autoscaler) configuration.

## Repository Structure

```
.
├── install_k8s.sh                    # Installs Kubernetes with containerd and Flannel
├── hpa_comparison_test.sh            # Automated HPA comparison testing script
├── README.md                         # This file
├── deathstar-bench/                  # DeathStarBench deployment files
│   ├── deploy/                       # Deployment scripts
│   │   ├── deploy_socialnetowrk.sh   # Deploys the Social Network app using Helm
│   │   ├── fetch_ports.sh            # Gets the exposed ports of services
│   │   └── reset_testbed.sh          # Resets all SocialNetwork pods
│   ├── hpa/                          # HPA configuration files
│   │   ├── default_hpa.yaml          # Default HPA configuration (resource metrics)
│   │   ├── context_aware_hpa_values.yaml # Context-aware HPA configuration (external metrics)
│   │   └── service_values.yaml       # Values for service deployment
│   └── monitoring/                   # Monitoring stack files
│       ├── deploy_monitoring.sh      # Deploys Prometheus & Grafana
│       └── grafana-dashboard.json    # Grafana dashboard configuration
├── k6/                               # Load testing files
│   ├── k6_csv_report_parser.py       # CSV report parser for k6 results
│   ├── k6_report_comparison.py       # Compare two k6 CSV reports
│   ├── k6_loader.js                  # k6 load testing script
│   ├── reports/                      # Directory for test reports
│   └── plots/                        # Directory for visualization plots
└── prom/                             # Prometheus configuration
    └── prometheus-adapter-values.yaml # Prometheus adapter values
```

## Quickstart

### 1. Install Kubernetes

#### Option 1: Bare-metal Kubernetes on Ubuntu 24.04

```bash
chmod +x install_k8s.sh
./install_k8s.sh
```

This will:
- Install `kubeadm`, `kubelet`, and `kubectl`
- Configure `containerd` as the container runtime
- Apply the Flannel CNI
- Initialize a single-node cluster

#### Option 2: Kind 

Requirements: Docker

```bash
brew install kind 
kind create cluster --name socialnetwork
kubectl cluster-info --context ocialnetwork
```

### 2. (Optional) Deploy Monitoring Stack

```bash
cd deathstar-bench/monitoring
chmod +x deploy_monitoring.sh
./deploy_monitoring.sh
```

Installs:
- Prometheus
- Grafana

### 3. Deploy the Social Network App

Requirements:
```bash
sudo apt install libssl-dev (previous requirement)
sudo apt install zlib1g-dev
sudo apt-get install luarocks
sudo luarocks install luasocket
```

Once ready:

```bash
cd deathstar-bench/deploy
chmod +x deploy_socialnetowrk.sh
./deploy_socialnetowrk.sh
```

This script:
- Clones DeathStarBench (with PR #352)
- Initializes submodules
- Installs the app via Helm 
- Compiles wrk loader

### 4. Fetch Service Ports

```bash
cd deathstar-bench/deploy
chmod +x fetch_ports.sh
./fetch_ports.sh
```

Lists exposed NodePorts for UI and services.

### 5. Reset all SocialNetwork pods

```bash
cd deathstar-bench/deploy
chmod +x reset_testbed.sh
./reset_testbed.sh
```

Deletes and redeploys all SocialNetwork pods, except monitoring.

### 6. HPA: Default vs Context-Aware

There are two ways to autoscale the Social Network services:

- Default HPA (Resource metrics): uses built-in CPU utilization from metrics-server.
  - File: `deathstar-bench/hpa/default_hpa.yaml`
  - Apply: `kubectl apply -f deathstar-bench/hpa/default_hpa.yaml -n socialnetwork`

- Context-Aware HPA (External metrics via Prometheus Adapter): uses custom, per-service CPU utilization exported by Prometheus Adapter, derived from cAdvisor usage divided by requested CPU.
  - Requires: kube-prometheus-stack (Prometheus Operator), kube-state-metrics, Prometheus Adapter.
  - Files:
    - Adapter rules and endpoint: `prom/prometheus-adapter-values.yaml`
    - Service CPU requests overrides: `deathstar-bench/hpa/service_values.yaml` (required for denominator)
    - HPAs referencing external metrics: `deathstar-bench/hpa/hpa_values.yaml`

Steps to deploy Context-Aware HPA:

1) Metrics server (with permissive kubelet TLS for lab/test clusters)
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --server-side --force-conflicts
kubectl -n kube-system patch deployment metrics-server \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--cert-dir=/tmp","--secure-port=4443","--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"]}]'
```

2) kube-prometheus-stack (Prometheus + default Kubernetes scrape targets) and kube-state-metrics
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.enabled=false

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  -n monitoring --create-namespace
```

3) Prometheus Adapter (publishes external metrics defined in values file)
```bash
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring --create-namespace \
  -f prom/prometheus-adapter-values.yaml
```

4) Ensure target Deployments have CPU requests (required by the adapter queries)
```bash
kubectl apply -f deathstar-bench/hpa/service_values.yaml -n socialnetwork
```

5) Apply HPAs that use the external metrics
```bash
kubectl apply -f deathstar-bench/hpa/hpa_values.yaml -n socialnetwork
```

Verification:
```bash
kubectl get apiservice | grep external.metrics
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1" | jq .
for m in nginx_thrift_cpu_utilization_pct compose_post_cpu_utilization_pct \
         text_service_cpu_utilization_pct user_mention_cpu_utilization_pct; do
  kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/socialnetwork/$m" | jq .
done
kubectl get hpa -n socialnetwork
kubectl describe hpa -n socialnetwork | sed -n '1,200p' | cat
```

Notes on units and metrics:
- The external metrics exposed by the adapter are returned in milli-units (e.g., `800m` equals 80%).
- The HPAs in `hpa_values.yaml` use milli-unit targets (e.g., `800m` for 80%).
- The adapter connects to Prometheus at `http://kube-prometheus-stack-prometheus.monitoring.svc:9090` (configured in `prometheus-adapter-values.yaml`).

Grafana adjustments (if you use Grafana):
- Prometheus datasource URL should be `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`.
- Some job names differ from the basic Prometheus chart. Prefer filters like `namespace="socialnetwork"`, `container!="POD"`, `image!=""` instead of hard-coding job names.
- Example CPU utilization % per pod:
  ```
  (sum by (namespace,pod) (rate(container_cpu_usage_seconds_total{namespace="socialnetwork",container!="POD",image!=""}[2m]))
   /
   sum by (namespace,pod) (kube_pod_container_resource_requests{namespace="socialnetwork",resource="cpu",unit="core"})) * 100
  ```


## Custom values for HPA and main services

You can customize HPA values via `hpa_values.yaml`.
You can customize service resources via `service_values.yaml`.

In order to add an external metric in HPA follow this example:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: <your-service-name>-hpa
  namespace: <your-namespace>
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <your-deployment-name>
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: External
      external:
        metric:
          name: <your-custom-metric-name-defined-in-prom-adapter>
        target:
          type: Value
          value: <your-target-value>
```

To apply the changes:
```bash
cd deathstar-bench/hpa
kubectl apply -f hpa_values.yaml -n socialnetwork
kubectl apply -f service_values.yaml -n socialnetwork
```


## Load Testing:

You can use the `k6` tool with the custom loader :

```bash
cd k6
xk6 build latest
```

To run the benchmark, make sure the proper nginx IP address is configured.

```bash
./k6 run k6_loader.js --out csv=reports/report-name.csv   
```

### Enhanced k6 + Prometheus report

Generate an “enhanced” time series that joins k6 request metrics with Prometheus infrastructure metrics (replicas and CPU) for key services. This complements the standard k6 CSV/JSON without changing them.

Script:
```
k6/enhanced_report.py
```

Prerequisites:
- Prometheus reachable at `http://kube-prometheus-stack-prometheus.monitoring.svc:9090` (default from `prom/prometheus-adapter-values.yaml`).
- kube-state-metrics and cAdvisor metrics available (installed by kube-prometheus-stack).

What it does:
- Buckets k6 CSV by time (default 10s) and computes: requests, fail_pct, p50/p90/p95/max latency.
- Queries Prometheus and joins per-bucket:
  - Replicas per Deployment (kube_deployment_status_replicas)
  - CPU mcores per service (1000 * sum(rate(container_cpu_usage_seconds_total{...}[1m])))

Usage example (10m, 50 VU dataset):
```bash
python3 k6/enhanced_report.py \
  --k6-csv k6/reports/context_hpa_vu_50_10m.csv \
  --prom http://kube-prometheus-stack-prometheus.monitoring.svc:9090 \
  --namespace socialnetwork \
  --services compose-post-service text-service user-mention-service \
  --bucket-sec 10 \
  --out k6/reports/enhanced/enhanced_vu50_10m.csv
```

Output (CSV columns):
- time_iso, time_unix, bucket_sec
- reqs, fail_pct, p50_ms, p90_ms, p95_ms, max_ms
- For each service: `<service>_replicas`, `<service>_cpu_mcores`

Notes:
- You can adjust `--services` to target any set of Deployments in `--namespace`.
- Use the enhanced CSV for correlation plots (e.g., error rate vs replicas/CPU). It’s additive; the original k6 CSV/JSON remain unchanged in `k6/reports/`.

## Appendix

- Context-aware chaining: after validating that each service scales on its own proportional CPU load via Prometheus Adapter metrics, update `prom/prometheus-adapter-values.yaml` so each downstream service scales based on the upstream hop (e.g., `compose-post` on `nginx-thrift`, `text-service` on `compose-post-service`, `user-mention-service` on `text-service`). Reinstall the adapter and verify external metric endpoints before tuning HPA targets.

### HPA Comparison Testing

#### Automated HPA Comparison Script

The `hpa_comparison_test.sh` script automates the entire process of comparing two different HPA configurations, including deployment, load testing, and analysis.

##### Features

- **Automated HPA Deployment**: Applies service CPU requests and HPA configurations
- **Intelligent Stabilization**: Waits for deployments to stabilize between tests
- **Configurable Load Testing**: Supports custom k6 parameters via environment variables
- **Comprehensive Analysis**: Generates comparison reports and visualizations
- **Robust Error Handling**: Includes retry mechanisms and detailed logging

##### Usage

```bash
./hpa_comparison_test.sh <HPA1_YAML> <HPA2_YAML> <TEST_NAME>
```

**Arguments:**
- `HPA1_YAML`: Path to first HPA configuration file
- `HPA2_YAML`: Path to second HPA configuration file  
- `TEST_NAME`: Name for the test run (used for output files)

**Example:**
```bash
# Compare default HPA vs context-aware HPA
./hpa_comparison_test.sh \
  deathstar-bench/hpa/default_hpa.yaml \
  deathstar-bench/hpa/context_aware_hpa_values.yaml \
  default_vs_context_aware_test

# Compare same HPA with different timeout settings
K6_TIMEOUT_HPA1=1s K6_TIMEOUT_HPA2=5s \
./hpa_comparison_test.sh \
  deathstar-bench/hpa/default_hpa.yaml \
  deathstar-bench/hpa/default_hpa.yaml \
  timeout_comparison_test
```

##### Environment Variables

The script supports various k6 configuration options via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `K6_DURATION` | `600s` | Total test duration |
| `K6_TARGET` | `50` | Target number of virtual users |
| `K6_TIMEOUT_HPA1` | `5s` | Request timeout for first test |
| `K6_TIMEOUT_HPA2` | `5s` | Request timeout for second test |
| `NGINX_HOST` | Auto-detected | Target endpoint for load testing |

##### Output Files

The script generates the following outputs in `k6/reports/`:

- `{TEST_NAME}_hpa1.csv`: k6 results from first HPA configuration
- `{TEST_NAME}_hpa2.csv`: k6 results from second HPA configuration  
- `{TEST_NAME}_comparison.json`: Detailed comparison analysis
- `k6/plots/`: Visualization plots (latency distribution, metrics summary)

##### Script Workflow

1. **Setup**: Applies service CPU requests and validates cluster state
2. **First Test**: 
   - Applies first HPA configuration
   - Waits for HPA to stabilize
   - Restarts deployments for clean state
   - Runs k6 load test
3. **Reset**: Waits for pods to scale down to baseline (1 replica each)
4. **Second Test**:
   - Applies second HPA configuration  
   - Waits for HPA to stabilize
   - Restarts deployments for clean state
   - Runs k6 load test
5. **Analysis**: Generates comparison report and visualizations

##### Help and Options

```bash
./hpa_comparison_test.sh --help
```

## Experiment: Default vs Adapter @ 50% Parity Test

Goal: show that the Prometheus Adapter HPA behaves similarly to the default (resource) HPA when both target 50% CPU, then produce two comparable k6 reports.

### Quick Automated Test

Use the automated comparison script for a streamlined test:

```bash
# Run automated comparison with default settings (10 minutes, 50 VUs)
./hpa_comparison_test.sh \
  deathstar-bench/hpa/default_hpa.yaml \
  deathstar-bench/hpa/context_aware_hpa_values.yaml \
  parity_test_50pct
```

### Manual Step-by-Step Process

For detailed control and understanding, follow this manual checklist:
1) Preconditions
   - Cluster up; `monitoring` stack installed (kube-prometheus-stack, kube-state-metrics, metrics-server)
   - Adapter configured to `http://kube-prometheus-stack-prometheus.monitoring.svc:9090` (see `prom/prometheus-adapter-values.yaml`)
   - Service CPU requests applied (denominator):
     ```bash
     kubectl apply -f deathstar-bench/hpa/service_values.yaml -n socialnetwork
     ```

2) Default HPA at 50% (resource CPU)
   - Apply baseline HPAs using built-in CPU utilization:
     ```bash
     kubectl apply -f deathstar-bench/hpa/default_hpa.yaml -n socialnetwork
     ```
   - Verify:
     ```bash
     kubectl get hpa -n socialnetwork
     kubectl describe hpa -n socialnetwork | sed -n '1,160p' | cat
     ```

3) Adapter HPA at 50% (external percent)
   - Prepare context-aware HPA manifest with targets at 50 (percent):
     - File to use: `deathstar-bench/hpa/context_aware_hpa_values.yaml`
     - Targets for all four services set to `value: 50` (not milli-units)
   - Apply:
     ```bash
     kubectl apply -f deathstar-bench/hpa/context_aware_hpa_values.yaml -n socialnetwork
     ```
   - Verify external metrics are present and in percent (milli-printed in CLI):
     ```bash
     kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1" | jq .
     for m in nginx_thrift_cpu_utilization_pct compose_post_cpu_utilization_pct \
              text_service_cpu_utilization_pct user_mention_cpu_utilization_pct; do
       kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/socialnetwork/$m" | jq .
     done
     ```

4) Normalize testing conditions
   - Ensure same min/max replicas across both sets (e.g., `minReplicas: 1`, `maxReplicas: 10`).
   - Reset recommendations and state:
     ```bash
     kubectl rollout restart deploy -n socialnetwork nginx-thrift compose-post-service text-service user-mention-service
     ```
   - Optional: pause ~3–5 minutes for metrics to stabilize at idle.

5) Run k6 test (Default HPA)
   - Discover target:
     ```bash
     NODE_PORT=$(kubectl get svc nginx-thrift -n socialnetwork -o jsonpath='{.spec.ports[0].nodePort}')
     NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
     export NGINX_HOST="$NODE_IP:$NODE_PORT"
     ```
   - Example 10-minute run at 50 VUs (env-driven):
     ```bash
     export K6_DURATION=600s
     export K6_TARGET=50
     k6 run k6/k6_loader.js --out csv=k6/reports/default_hpa_50vu.csv
     ```
   - Capture HPA snapshots during run:
     ```bash
     watch -n 15 'kubectl get hpa -n socialnetwork; echo; kubectl get deploy -n socialnetwork'
     ```

6) Switch to Adapter HPA
   - Apply adapter HPA (50% targets) again to ensure active:
     ```bash
     kubectl apply -f deathstar-bench/hpa/context_aware_hpa_values.yaml -n socialnetwork
     ```
   - Reset recommendations/state (optional but recommended for parity):
     ```bash
     kubectl rollout restart deploy -n socialnetwork nginx-thrift compose-post-service text-service user-mention-service
     ```

7) Run k6 test (Adapter HPA)
   - Same test window and VUs:
     ```bash
     export K6_DURATION=600s
     export K6_TARGET=50
     k6 run k6/k6_loader.js --out csv=k6/reports/adapter_hpa_50vu.csv
     ```
   - Capture HPA snapshots during run as above.

8) Compare reports
   - Use existing utilities to compare CSV/JSON:
     ```bash
     python3 k6/k6_report_comparison.py \
       --a k6/reports/default_hpa_50vu.csv \
       --b k6/reports/adapter_hpa_50vu.csv \
       --out k6/reports/compare_default_vs_adapter_50vu.json
     ```
   - Check: peak replicas, time-to-scale, throughput (req/s), error rates, p95 latency.

Notes:
- External metric units: CLI prints milli (e.g., 500m = 0.5%). Our adapter emits percent; set HPA targets as integer percents (e.g., 50) to match.
- If adapter metrics aren’t listed, confirm the adapter points to kube-prometheus-stack and that `kube-state-metrics` is installed.

