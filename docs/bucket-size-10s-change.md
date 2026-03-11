# Bucket Size Change: 15s → 10s

## What Was Changed and Why

The system collects time-series data from two sources:

- **Prometheus/Grafana** — scrapes metrics from the cluster (replicas, CPU, memory, network) at a fixed interval
- **k6** — writes one row per HTTP request to a raw CSV; these are then aggregated into fixed-width time buckets for plotting and comparison

Previously both were aligned at **15 seconds**. All of the following were changed to **10 seconds**.

---

## File-by-File Changes

### 1. `reset_testbed.sh` — Prometheus scrape and evaluation interval

```bash
# Added to helm_args before `helm upgrade --install kube-prometheus-stack`:
--set prometheus.prometheusSpec.scrapeInterval=10s
--set prometheus.prometheusSpec.evaluationInterval=10s
```

**What this controls:** How often Prometheus scrapes each target (every 10s instead of 15s) and how often it evaluates alerting/recording rules. This is the root data source — everything downstream depends on having data points at this frequency.

**Important:** This change only takes effect after the next full cluster reset (`reset_testbed.sh`). Existing stored data and any runs done before the reset were collected at 15s resolution. Re-running queries against old data with `--step 10` will cause Prometheus to interpolate between 15s samples, which can produce slightly different values for rate-based metrics.

---

### 2. `k6/scrape_grafana_dashboard.py` — Prometheus query step

```python
# Was:
parser.add_argument('--step', type=int, default=15, ...)
# Now:
parser.add_argument('--step', type=int, default=10, ...)
```

**What this controls:** The `step` parameter in Prometheus `query_range` API calls. This determines how many data points are returned per query, and how `$__interval` / `$__rate_interval` Grafana template variables are substituted into PromQL expressions (e.g. `rate(metric[$__rate_interval])` becomes `rate(metric[10s])`).

Reducing the step from 15s to 10s means:
- More data points per query (50% more rows in `grafana_master.csv`)
- Rate/increase calculations use a shorter window, which can legitimately change values (see "Why Results May Change" below)

---

### 3. `hpa_comparison_test.sh` — explicit arguments passed to scraper and merger

```bash
# scrape_grafana_dashboard.py call: added --step 10
--step 10

# merge_k6_grafana.py call:
# Was:   --bucket-sec 15
# Now:   --bucket-sec 10
```

**What this controls:** The `--step 10` ensures the Prometheus query step matches the new default. The `--bucket-sec 10` controls how raw k6 request rows are grouped: each 10-second window becomes one row in `unified_report.csv`.

---

### 4. `k6/merge_k6_grafana.py` — default bucket size

```python
# Was:
p.add_argument("--bucket-sec", type=int, default=15, ...)
# Now:
p.add_argument("--bucket-sec", type=int, default=10, ...)
```

**What this controls:** When `merge_k6_grafana.py` is run standalone (e.g. for reruns or sweep reprocessing), it now defaults to 10s buckets without needing an explicit argument.

---

### 5. `k6/aggregate_runs.py` — axis label only

```python
# Was:
ax.set_xlabel("Bucket (15s intervals)")
# Now:
ax.set_xlabel("Bucket (10s intervals)")
```

Cosmetic label change only. No effect on data.

---

### 6. `k6/overlay_plots.py` — axis labels only (8 occurrences)

All `"Bucket (15s)"` x-axis labels replaced with `"Bucket (10s)"`.

Cosmetic label changes only. No effect on data.

---

## Why Results May Legitimately Change

If you ran new experiments after the cluster was reset with the new scrape interval, the differences you see are expected and legitimate. Here is why each metric category may shift:

### Rate-based Prometheus metrics (CPU, network, k6 RPS)

Prometheus `rate()` and `increase()` functions compute an average rate over the look-back window specified in the query — which is now `10s` instead of `15s`. A shorter window:

- Is **more responsive** to sudden spikes and drops (less smoothing)
- Can produce **higher peak values** because short bursts are not diluted over a longer window
- Can produce **lower trough values** for the same reason

This is a legitimate improvement in temporal resolution, not an artefact.

### Gauge metrics (replicas, memory)

Gauges (e.g. replica count) are sampled directly — the value at each scrape timestamp is simply read. With 10s scrapes you get more snapshots, which means:

- Replica scaling events appear at a finer granularity (step changes look more accurate in time)
- Nothing changes about the underlying values themselves

### k6 latency buckets

The raw k6 CSV contains one row per request with a microsecond timestamp and duration. Bucketing into 10s windows instead of 15s windows means:

- Each bucket contains **fewer requests on average** (~33% fewer per bucket)
- Percentile estimates (p50, p95, p99) within each bucket are computed from a smaller sample, so they have **higher variance** — individual bucket values may look noisier
- The **overall distribution** across the full run is unchanged; aggregate statistics (mean, overall p95 etc.) will be the same

### The merge join tolerance

In `merge_k6_grafana.py`, the Grafana and k6 dataframes are joined with `tolerance=bucket_sec` (now 10s instead of 15s). This means a k6 bucket is only matched to a Grafana row if their timestamps are within 10s of each other. Rows that previously matched under the 15s tolerance may now be left unmatched, producing NaN values at the edges of the run. This is correct behaviour — it avoids joining samples that are too far apart in time.

---

## How to Verify the Change is Legitimate

1. **Check Prometheus scrape interval** — after the next cluster reset, confirm the new interval is active:
   ```bash
   kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.scrapeInterval}'
   # Should output: 10s
   ```

2. **Check grafana_master.csv row count** — a 5-minute run should now produce ~30 rows (one per 10s) instead of ~20 rows (one per 15s).

3. **Check that peak CPU values are higher** — a 10s rate window is less smoothed, so short CPU bursts that were averaged away at 15s will now appear. This is real signal, not noise.

4. **Check latency bucket variance** — individual 10s bucket percentiles will be noisier. But the latency distribution plot (histogram) and overall summary statistics should be nearly identical to 15s runs at the same load.

---

## Runs Affected

| Run type | Affected? |
|---|---|
| New runs after cluster reset | Yes — full end-to-end 10s resolution |
| New runs without cluster reset | Partially — k6 buckets are 10s but Prometheus data is still 15s resolution, queries use 10s step (interpolation) |
| Old `unified_report.csv` files reprocessed with new scripts | No — the CSV already has fixed-width rows; regenerating plots from it is unaffected |
| Old Grafana data re-scraped with `--step 10` | Partially — Prometheus interpolates between 15s samples |
