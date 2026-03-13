# Context-Aware HPA: Design, Bugs, and Fixes

## Overview

This document explains the design evolution of the **context-aware HPA** (Horizontal Pod Autoscaler) for the DeathStarBench social network microservice chain. It covers two bugs discovered during testing — the **dilution bug** and the **runaway scaling bug** — along with their mathematical proofs and the final working configuration.

### Service Chain

```
nginx-thrift (entry point)
    → compose-post-service
        → text-service
            → user-mention-service
```

Each service in the chain depends on its upstream parent. The goal of context-aware scaling is: **when a parent service is under heavy load, proactively scale up the child service before the child itself becomes a bottleneck.**

---

## Approach 1: Combined Pooled Metric (Dilution Bug)

### Design

The first approach created a single "combined" Prometheus metric that pools the CPU usage of both the parent and child service into one utilization percentage. The HPA for the child uses this single metric with `type: Value`.

**Prometheus Adapter metric** (`text_service_with_parent_cpu_utilization_pct`):

```promql
(
  sum(rate(container_cpu_usage_seconds_total{container="text-service"}[2m]))
  +
  sum(rate(container_cpu_usage_seconds_total{container="compose-post-service"}[2m]))
)
/
(
  sum(kube_pod_container_resource_requests{resource="cpu", container="text-service"})
  +
  sum(kube_pod_container_resource_requests{resource="cpu", container="compose-post-service"})
) * 100
```

**HPA spec:**

```yaml
metrics:
  - type: External
    external:
      metric:
        name: text_service_with_parent_cpu_utilization_pct
      target:
        type: Value
        value: 39000m   # threshold = 39%
```

### The Dilution Problem

The `sum()` in both numerator and denominator aggregates across **all pods** of each service. Since every pod has the same CPU request \( R \), the denominator grows linearly with replica count. This makes the combined metric a **replica-weighted average**:

\[
M_{\text{combined}} = \frac{U_{\text{child}} \cdot N_{\text{child}} + U_{\text{parent}} \cdot N_{\text{parent}}}{N_{\text{child}} + N_{\text{parent}}}
\]

where:
- \( U_{\text{child}} \) = child's average per-pod CPU utilization (%)
- \( U_{\text{parent}} \) = parent's average per-pod CPU utilization (%)
- \( N_{\text{child}} \), \( N_{\text{parent}} \) = replica counts

**When the parent scales up, its weight in the denominator increases, diluting the child's CPU signal.**

### Worked Example from Real Data

At `T+5min` during an HPA1 test run (`13:10:23 UTC, 2026-02-18`):

| Service | Replicas | Per-Pod CPU | Weight |
|---|---|---|---|
| text-service (parent) | 4 | 23.1% | 4/5 = 80% |
| user-mention (child) | 1 | 57.4% | 1/5 = 20% |

\[
M = \frac{57.4 \times 1 + 23.1 \times 4}{1 + 4} = \frac{57.4 + 92.3}{5} = 29.9\%
\]

The HPA threshold was 32%. Since \( 29.9 < 32 \), **the HPA decided no scaling was needed** — even though user-mention was at 57.4% CPU and overloaded.

This was verified across multiple timestamps:

| Time | user-mention CPU | text replicas | text CPU | Combined | Threshold | HPA Decision |
|---|---|---|---|---|---|---|
| 13:09:23 | 45.4% | 4 | 19.9% | 25.0% | 32% | No scale |
| 13:10:23 | 57.4% | 4 | 23.1% | 29.9% | 32% | No scale |
| 13:11:08 | 70.0% | 4 | 29.3% | 37.4% | 32% | Scale to 2 |
| 13:11:38 | **84.4%** | 4 | 32.6% | 42.9% | 32% | Scale to 2 |
| 13:11:53 | 31.3% | 5 | 27.6% | 29.0% | 32% | Scaled to 3 |

User-mention was stuck at **1 replica** with 57–84% CPU for nearly 2 minutes because the diluted combined metric read below the threshold.

### Impact on Latency

Under the default HPA (scaling on own CPU at 50%), user-mention scaled to 2 replicas at `T+3.5min`. Under the context-aware HPA with the combined metric, it didn't scale until `T+6min`. This 2.5-minute delay kept latency elevated at p50 = 700–900ms, dragging down the overall average and making context-aware HPA appear **worse** than the default.

### Root Cause

The more the parent scales → the more pods in the denominator → the lower the combined metric reads → the harder it is for the child to trigger scaling. **Parent scaling actively suppresses child scaling** — the exact opposite of the intended behavior.

---

## Approach 2: Dual-Metric with `type: Value` (Runaway Scaling Bug)

### Design

To fix the dilution bug, the combined metric was replaced with **two independent metrics** per service:

1. **Own CPU** (`type: Resource`, `averageUtilization: 50`)
2. **Parent's CPU** (`type: External`, using a parent-only metric)

The HPA evaluates both and picks the **maximum** desired replica count. This way, neither metric can suppress the other.

**HPA spec (first attempt):**

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: External
    external:
      metric:
        name: text_service_parent_cpu_utilization_pct   # = compose-post CPU (parent of text-service)
      target:
        type: Value
        value: "50"
```

### The Runaway Scaling Problem

For external metrics with `type: Value`, the Kubernetes HPA computes:

\[
\text{desiredReplicas} = \left\lceil \text{currentReplicas} \times \frac{\text{currentMetricValue}}{\text{targetValue}} \right\rceil
\]

The implicit assumption is that **scaling the target deployment will reduce the metric**. For a service's own CPU, this is true — more replicas means less load per pod. But for a **parent metric**, scaling the child has **zero effect** on the parent's CPU. The metric value stays the same while `currentReplicas` keeps growing.

### Proof of Runaway

Let \( V \) = parent's CPU utilization (constant from the child's perspective), \( T \) = target value, and \( R_n \) = replica count at iteration \( n \):

\[
R_{n+1} = \left\lceil R_n \times \frac{V}{T} \right\rceil
\]

For any \( V > T \) (parent over threshold), this is a geometric progression:

\[
R_n \geq \left(\frac{V}{T}\right)^n
\]

Since \( V/T > 1 \), this grows without bound until hitting `maxReplicas`.

### Worked Example

With compose-post CPU at 80% and target = 50:

| Iteration | Current Replicas | Desired | Result |
|---|---|---|---|
| 0 | 1 | ⌈1 × 80/50⌉ = 2 | Scale to 2 |
| 1 | 2 | ⌈2 × 80/50⌉ = 4 | Scale to 4 |
| 2 | 4 | ⌈4 × 80/50⌉ = 7 | Scale to 7 |
| 3 | 7 | ⌈7 × 80/50⌉ = 12 | Capped at 10 |

**In 4 HPA evaluation cycles (~60 seconds), text-service hits maxReplicas regardless of its own CPU usage.**

### Observed in Production

During the test run at `19:18 UTC, 2026-02-18`:

```
text-service-hpa   Deployment/text-service   25%/50%, 35485m/50   1   10   10
```

Text-service had **10 replicas** (maximum) with only **25% own CPU utilization**. The external metric (compose-post CPU) was 35.5%, which is below the 50 target — yet text-service was already maxed out from the runaway during earlier peaks.

---

## Approach 3: Dual-Metric with `type: AverageValue` (Working Solution)

### Design

The fix is to use `type: AverageValue` for the parent metric. The key difference in how the HPA computes desired replicas:

| Target Type | Formula | Depends on currentReplicas? |
|---|---|---|
| `Value` | \( \lceil \text{currentReplicas} \times \frac{V}{T} \rceil \) | **Yes** — causes runaway |
| `AverageValue` | \( \lceil \frac{V}{T} \rceil \) | **No** — stable |

With `AverageValue`, the desired replica count is derived directly from the metric value divided by the target, with no feedback loop.

**HPA spec (final):**

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: External
    external:
      metric:
        name: text_service_parent_cpu_utilization_pct
      target:
        type: AverageValue
        averageValue: "25"
```

### Stability Proof

Let \( V \) = parent CPU utilization and \( A \) = averageValue target:

\[
\text{desiredReplicas} = \left\lceil \frac{V}{A} \right\rceil
\]

This is a pure function of the parent's CPU. It does not depend on the child's current replica count, so there is no feedback loop. The result is bounded:

\[
1 \leq \text{desiredReplicas} \leq \left\lceil \frac{100}{A} \right\rceil
\]

With \( A = 25 \), the maximum from the parent signal alone is \( \lceil 100/25 \rceil = 4 \) replicas.

### Why `averageValue: "25"`?

The `averageValue` parameter controls how aggressively the child scales in response to the parent's load. It can be read as: *"for every `averageValue` percent of parent CPU, allocate one child replica."*

| Parent CPU | `averageValue: "50"` | `averageValue: "25"` | `averageValue: "15"` |
|---|---|---|---|
| 25% | 1 | 1 | 2 |
| 50% | 1 | 2 | 4 |
| 75% | 2 | 3 | 5 |
| 100% | 2 | 4 | 7 |

- **`"50"`** is very conservative — the parent signal rarely adds more than 1 replica, making the context-aware aspect negligible.
- **`"25"`** provides a proportional boost: when the parent is at its own scaling threshold (50%), the child gets 2 replicas from this signal. The child's own CPU metric can independently push higher if needed.
- **`"15"`** or lower is aggressive — useful if the child is a known bottleneck that needs heavy proactive scaling.

The value `"25"` was chosen as a balanced starting point for testing.

### How the HPA Combines Both Metrics

When multiple metrics are specified, the Kubernetes HPA:

1. Computes `desiredReplicas` for **each** metric independently
2. Takes the **maximum** across all metrics

This means:
- If the child's own CPU demands 5 replicas but the parent signal says 2, the HPA scales to 5 (self-preservation wins)
- If the parent is very hot and demands 4 replicas but the child's CPU is idle, the HPA scales to 4 (proactive scaling wins)
- Neither metric can suppress the other

---

## Configuration Files

| File | Description |
|---|---|
| `deathstar-bench/hpa/default_hpa.yaml` | Baseline: all services scale on own CPU at 50% |
| `deathstar-bench/hpa/context_aware_hpa_parent_child_combo.yaml` | **Broken**: combined pooled metric (dilution bug) |
| `deathstar-bench/hpa/context_aware_hpa_dual_metric.yaml` | **Working**: dual-metric with `AverageValue` |
| `prom/prometheus-adapter-values-parent-child.yaml` | Prometheus adapter config defining all external metrics |

## Summary of Bugs

| Bug | Approach | Root Cause | Effect |
|---|---|---|---|
| Dilution | Combined metric | Pooled `sum()/sum()` across services creates replica-weighted average | Parent scaling suppresses child scaling |
| Runaway | Dual-metric with `Value` | `desired = ceil(replicas × metric/target)` feeds back when metric is external | Child scales to maxReplicas regardless of own CPU |

Both bugs share a common theme: **the HPA formulas assume the target deployment controls the metric it's being scaled on.** When this assumption is violated (as with parent-aware external metrics), the standard behavior breaks down. The fix — `AverageValue` — uses a formula that doesn't depend on the current replica count, breaking the feedback loop.

---

## Operational Issues Discovered in March 2026 Testing

### Bug 4: `<unknown>` External Metrics After Prometheus Adapter Restart

#### Symptom

After `helm upgrade --install prometheus-adapter` (run at the start of `hpa_comparison_test.sh`), the HPA reported `<unknown>` for all external metrics for ~40–90 seconds:

```
text-service-hpa   Deployment/text-service   1%/50%, <unknown>/25 (avg)   1   10   1
```

When a metric is `<unknown>`, the HPA ignores it entirely and scales only on the remaining metrics. This meant the context-aware parent signal was silently disabled at the start of every test without any visible error.

This was identified by comparing a good run (2026-03-09) against recent broken runs (2026-03-11). The good run's `run_details.txt` showed `11068m/25 (avg)` while broken runs showed `<unknown>/25 (avg)` during the critical early scaling window.

#### Root Cause

The prometheus-adapter pod restarts when `helm upgrade` is called, even if the values haven't changed. The HPA controller polls metrics every 15s. With no readiness wait after the upgrade, the first 2–4 HPA evaluation cycles completed against a pod that wasn't serving yet, returning `<unknown>`. Since the early load phase is when the parent signal matters most, losing these first 2 minutes of proactive scaling was significant.

#### Fix

Added `kubectl rollout status` wait after every prometheus-adapter helm upgrade:

```bash
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
    -n monitoring ... -f prom/prometheus-adapter-values-parent-child.yaml

kubectl rollout status deployment/prometheus-adapter -n monitoring --timeout=120s
```

Added HPA metric verification function in `hpa_comparison_test.sh` that checks for `<unknown>` before each k6 test:

```bash
verify_hpa_metrics() {
    # prints kubectl get hpa output
    # if <unknown> found: prints loud WARNING banner + adapter pod status
    # if clean: prints "[SUCCESS] All HPA metrics are resolving"
}
```

---

### Bug 5: Hard Reset Wiping Prometheus Adapter Config Before HPA2

#### Symptom

The inter-test hard reset (`reset_testbed.sh --persist-monitoring-data`) reinstalls the prometheus-adapter via helm with **default values**, overwriting the custom `prometheus-adapter-values-parent-child.yaml` rules. The HPA2 (context-aware) test then ran without the external metrics definitions, behaving identically to the default HPA.

This silently invalidated all HPA2 results until caught — the k6 data looked normal (no 100% failures), but the context-aware signals were absent.

#### Root Cause

`reset_testbed.sh` reinstalls monitoring components including prometheus-adapter during the hard reset phase. The custom values file is not referenced by the reset script; it only applies the default chart values.

#### Fix

Added a Step 5 in `hpa_comparison_test.sh` that re-applies the prometheus-adapter with the custom values file immediately before the HPA2 test, after the hard reset:

```bash
# Step 5: Re-apply Prometheus Adapter config (hard reset wiped it) then test HPA2
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
    -n monitoring \
    --set prometheus.url=http://$prom_ip \
    --set prometheus.port=9090 \
    -f prom/prometheus-adapter-values-parent-child.yaml

kubectl rollout status deployment/prometheus-adapter -n monitoring --timeout=120s
verify_hpa_metrics "HPA2" "$HPA2_FILE"
```

---

### Bug 6: User-Mention Parent Signal Suppressed by Context-Aware Text-Service Scaling

#### Symptom

Under the context-aware HPA, `text-service` scaled significantly earlier than the default HPA (as intended). However, `user-mention-service` scaled at roughly the same time under both HPAs — as if it were purely reactive to its own CPU.

#### Root Cause

The call graph for DeathStarBench social network is a **linear chain**:

```
nginx-thrift → compose-post-service → text-service → user-mention-service
```

`text-service` is the direct parent of `user-mention-service`. The `user_mention_parent_cpu_utilization_pct` metric was therefore correctly reading from text-service, but was defined using a `sum()` denominator:

```promql
sum(rate(container_cpu_usage_seconds_total{container="text-service"}[2m]))
/
sum(kube_pod_container_resource_requests{resource="cpu", container="text-service"}) * 100
```

When text-service scales from 1 → 4 replicas under the context-aware HPA, the denominator increases 4×. Even though total CPU usage is high, the **per-replica utilization** drops sharply — e.g., from 80% to 20%. User-mention-service sees this already-suppressed value as its parent signal. With a target of `averageValue: "25"`:

```
desiredReplicas = ceil(20 / 25) = 1
```

The signal that was supposed to trigger proactive scaling was instead **already corrected away** by text-service's own proactive scaling. The more aggressively text-service scaled, the weaker the parent signal became for user-mention.

#### Fix

Replace the `sum()` denominator with `min()` — using the smallest per-pod CPU request (a constant) rather than the total across all replicas:

```promql
sum(rate(container_cpu_usage_seconds_total{namespace="socialnetwork", container="text-service"}[2m]))
/
min(kube_pod_container_resource_requests{resource="cpu", namespace="socialnetwork", container="text-service"}) * 100
```

With `min()`, the denominator is always the CPU request of a single pod (a constant). As text-service scales from 1 → N replicas, the numerator (total CPU usage across all pods) grows with load, and the metric now reflects **total load relative to one pod's capacity** rather than average per-pod utilization.

The `averageValue` target must also be recalibrated. With the `sum()` metric the value ranged 0–100 (average utilization %). With the `min()` metric the value can exceed 100 (e.g. text-service at 4 replicas × 50% utilization = 200). The target is set to `"50"` so that one user-mention replica is provisioned per 50% of one-pod-capacity of text-service total load:

- text-service total load at 1× capacity (100) → ceil(100/50) = 2 user-mention replicas
- text-service total load at 2× capacity (200) → ceil(200/50) = 4 user-mention replicas

This means user-mention tracks text-service 1:1 at normal load and scales proportionally when text-service is overloaded, with no dilution as text-service scales.

The fix is applied in `prom/prometheus-adapter-values-parent-child.yaml` for the `user_mention_parent_cpu_utilization_pct` rule, and `averageValue` is set to `"50"` in `deathstar-bench/hpa/context_aware_hpa_dual_metric.yaml`.


---

## Experimental Methodology: Open-Loop Load Generation (RPS Mode)

### Problem with Virtual User (VU) Mode

Early experiments used k6's default **VU (virtual user) model**, a *closed-loop* load generator: each VU sends a request, waits for the response, then immediately sends the next. Throughput is therefore:

```
actual RPS = num_VUs / mean_response_time
```

This creates a critical confound when comparing two HPA configurations with different scaling speeds:

1. During ramp-up, the slower configuration (e.g. compose-post still at 1 replica) has **higher response times**.
2. Higher response times → **fewer requests/second** dispatched to that configuration.
3. Fewer requests → **less CPU pressure** on upstream services.
4. Less CPU pressure → **upstream HPA delays scaling further**.
5. Delayed scaling → **even higher response times**.

The result is a self-reinforcing feedback loop: the configuration that scales more slowly receives a lighter workload precisely because it is slow, masking its true performance deficit and making the comparison unfair. In concrete terms, context-aware HPA's proactive scaling of `text-service` and `user-mention-service` made those services respond faster, which *reduced backpressure on* `compose-post`, which *suppressed* compose-post's CPU signal, causing compose-post to scale with 1–2 fewer replicas than the default HPA — despite both configurations using an identical CPU-only HPA for compose-post. Over 5 runs, context-aware HPA consistently showed **+39% worse P50 latency** than default HPA under VU mode, which was the opposite of the expected result.

### Fix: Constant Arrival Rate (RPS Mode)

The experiment was switched to k6's **`ramping-arrival-rate` executor**, an *open-loop* load generator. k6 dispatches requests at a **fixed rate** regardless of response time. Slow responses accumulate as latency or failures, not as reduced throughput. Both HPA configurations receive an identical request stream, making the comparison fair.

**Staged profile (45 RPS target, 11-minute sustained phase):**

| Stage | Duration | Rate |
|---|---|---|
| Warmup | 30 s | 0 → 27 RPS (60%) |
| Ramp | 30 s | 27 → 45 RPS |
| Sustained | 11 min | 45 RPS (constant) |
| Cooldown | 30 s | 45 → 0 RPS |

Pre-allocated VUs: 200 (max 400) — sized to handle 45 RPS × 5 s worst-case timeout without dropping arrivals.

**Why open-loop is more realistic:** in production, client request rates are driven by external users, not by the system's own response time. A slow backend does not cause clients to stop sending requests — it causes latency to rise and queues to build. The constant arrival rate model reflects this correctly.

**Configuration:** set via `K6_LOAD_MODE=rps K6_RPS=45` in `reset_then_test.sh`. The k6 script (`k6/k6_loader.js`) supports both modes; `vu` mode remains available for backwards compatibility.
