import pandas as pd
import matplotlib.pyplot as plt
import os
from collections import defaultdict

# Create plots directory if it doesn't exist
os.makedirs('plots', exist_ok=True)

# Read the CSV files
csv_file_1 = 'reports/all_50_hpa_vu_100.csv'

data_1 = pd.read_csv(csv_file_1, low_memory=False)

# Extract various metrics from the CSV
def extract_metric_data(data, metric_name):
    """Extract timestamp and value pairs for a specific metric"""
    metric_data = data[data.iloc[:, 0] == metric_name].iloc[:, [1, 2]].apply(tuple, axis=1).tolist()
    if metric_data:
        timestamps, values = zip(*metric_data)
        # Normalize timestamps so that the initial timestamp is 0
        original_timestamps = [float(ts) for ts in timestamps]
        normalized_timestamps = [float(ts) - float(timestamps[0]) for ts in timestamps]
        values = [float(val) for val in values]
        # Keep only timestamps smaller than 1100 seconds
        filtered_data = [(ts, val) for ts, val in zip(normalized_timestamps, values) if ts < 1100]
        if filtered_data:
            return zip(*filtered_data)
    return [], []

# Extract different metrics
timestamps_1, latencies_1 = extract_metric_data(data_1, 'http_req_duration')
_, http_reqs_1 = extract_metric_data(data_1, 'http_reqs')
_, http_failed_1 = extract_metric_data(data_1, 'http_req_failed')
_, checks_1 = extract_metric_data(data_1, 'checks')
_, data_sent_1 = extract_metric_data(data_1, 'data_sent')
_, data_received_1 = extract_metric_data(data_1, 'data_received')
_, iterations_1 = extract_metric_data(data_1, 'iterations')
_, iteration_duration_1 = extract_metric_data(data_1, 'iteration_duration')

### METRICS CALCULATION FUNCTIONS ###

def calculate_comprehensive_metrics(timestamps, latencies, http_reqs, http_failed, checks, data_sent, data_received, iterations, iteration_duration):
    """Calculate comprehensive performance metrics"""
    metrics = {}
    
    # Basic latency metrics
    if latencies:
        metrics['avg_latency'] = sum(latencies) / len(latencies)
        metrics['min_latency'] = min(latencies)
        metrics['max_latency'] = max(latencies)
        sorted_latencies = sorted(latencies)
        metrics['p50_latency'] = sorted_latencies[int(0.5 * len(sorted_latencies))]
        metrics['p95_latency'] = sorted_latencies[int(0.95 * len(sorted_latencies))]
        metrics['p99_latency'] = sorted_latencies[int(0.99 * len(sorted_latencies))]
    
    # Success rate calculation
    if http_reqs and http_failed:
        total_requests = sum(http_reqs)
        total_failed = sum(http_failed)
        metrics['success_rate'] = ((total_requests - total_failed) / total_requests * 100) if total_requests > 0 else 0
        metrics['failure_rate'] = (total_failed / total_requests * 100) if total_requests > 0 else 0
        metrics['total_requests'] = total_requests
        metrics['total_failed'] = total_failed
    
    # Check success rate
    if checks:
        total_checks = sum(checks)
        metrics['check_success_rate'] = (total_checks / len(checks) * 100) if len(checks) > 0 else 0
        metrics['total_checks'] = total_checks
    
    # Throughput metrics
    if timestamps and http_reqs:
        test_duration = max(timestamps) - min(timestamps) if timestamps else 0
        total_requests = sum(http_reqs)
        metrics['requests_per_second'] = total_requests / test_duration if test_duration > 0 else 0
        metrics['test_duration'] = test_duration
    
    # Data transfer metrics
    if data_sent:
        metrics['total_data_sent'] = sum(data_sent)
        metrics['avg_data_sent_per_request'] = sum(data_sent) / len(data_sent) if data_sent else 0
    if data_received:
        metrics['total_data_received'] = sum(data_received)
        metrics['avg_data_received_per_request'] = sum(data_received) / len(data_received) if data_received else 0
    
    # Iteration metrics
    if iterations:
        metrics['total_iterations'] = sum(iterations)
    if iteration_duration:
        metrics['avg_iteration_duration'] = sum(iteration_duration) / len(iteration_duration)
        metrics['min_iteration_duration'] = min(iteration_duration)
        metrics['max_iteration_duration'] = max(iteration_duration)
    
    return metrics

def print_metrics(metrics, label):
    """Print formatted metrics"""
    print(f"\n=== {label} Performance Metrics ===")
    
    if 'avg_latency' in metrics:
        print(f"Latency Metrics:")
        print(f"  Average: {metrics['avg_latency']:.2f} ms")
        print(f"  Min: {metrics['min_latency']:.2f} ms")
        print(f"  Max: {metrics['max_latency']:.2f} ms")
        print(f"  P50: {metrics['p50_latency']:.2f} ms")
        print(f"  P95: {metrics['p95_latency']:.2f} ms")
        print(f"  P99: {metrics['p99_latency']:.2f} ms")
    
    if 'success_rate' in metrics:
        print(f"Success Metrics:")
        print(f"  Success Rate: {metrics['success_rate']:.2f}%")
        print(f"  Failure Rate: {metrics['failure_rate']:.2f}%")
        print(f"  Total Requests: {metrics['total_requests']}")
        print(f"  Failed Requests: {metrics['total_failed']}")
    
    if 'check_success_rate' in metrics:
        print(f"Check Success Rate: {metrics['check_success_rate']:.2f}%")
    
    if 'requests_per_second' in metrics:
        print(f"Throughput: {metrics['requests_per_second']:.2f} requests/second")
        print(f"Test Duration: {metrics['test_duration']:.2f} seconds")
    
    if 'total_data_sent' in metrics:
        print(f"Data Transfer:")
        print(f"  Total Sent: {metrics['total_data_sent']:.2f} bytes")
        print(f"  Avg per Request: {metrics['avg_data_sent_per_request']:.2f} bytes")
    
    if 'total_data_received' in metrics:
        print(f"  Total Received: {metrics['total_data_received']:.2f} bytes")
        print(f"  Avg per Request: {metrics['avg_data_received_per_request']:.2f} bytes")
    
    if 'total_iterations' in metrics:
        print(f"Total Iterations: {metrics['total_iterations']}")
    
    if 'avg_iteration_duration' in metrics:
        print(f"Iteration Duration:")
        print(f"  Average: {metrics['avg_iteration_duration']:.2f} ms")
        print(f"  Min: {metrics['min_iteration_duration']:.2f} ms")
        print(f"  Max: {metrics['max_iteration_duration']:.2f} ms")

# Calculate comprehensive metrics
metrics_1 = calculate_comprehensive_metrics(timestamps_1, latencies_1, http_reqs_1, http_failed_1, 
                                          checks_1, data_sent_1, data_received_1, iterations_1, iteration_duration_1)

# Print all metrics
print_metrics(metrics_1, "Optimal")

### AVERAGE LATENCY PLOTTING ###

# Create a function to process buckets and compute averages
def process_buckets(timestamps, latencies, bin_width):
    buckets = defaultdict(list)
    for ts, lat in zip(timestamps, latencies):
        buckets[int(ts // bin_width)].append(lat)
    averaged_latencies = [sum(bucket) / len(bucket) for bucket in buckets.values()]
    time_bins = [bin_index * bin_width for bin_index in sorted(buckets.keys())]
    return buckets, averaged_latencies, time_bins

# Bin width in seconds
bin_width = 3

# Process each dataset
buckets_1, averaged_latencies_1, time_bins_1 = process_buckets(timestamps_1, latencies_1, bin_width)

# Plot average latency over time
plt.figure(figsize=(12, 6))
plt.plot(time_bins_1, averaged_latencies_1, linestyle='-', label='Optimal', linewidth=2)
plt.xlabel('Time (seconds)')
plt.ylabel('Average Latency (ms)')
plt.title(f'Average Latency Over Time (binned every {bin_width}s)')
plt.legend()
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig('plots/average_latency_over_time.png', dpi=300, bbox_inches='tight')
plt.close()

# Print the average latency for each dataset    
def calculate_overall_avg_latency(buckets):
    total_latency = sum(sum(bucket) for bucket in buckets.values())
    total_count = sum(len(bucket) for bucket in buckets.values())
    return total_latency / total_count if total_count > 0 else 0

overall_avg_latency_1 = calculate_overall_avg_latency(buckets_1)

print(f'Average Latency for Optimal: {overall_avg_latency_1:.2f} ms')


### TAIL LATENCY PLOTTING ###

# Plot the tail latency (95th percentile) for each of the datasets
tail_latency_1 = [sorted(bucket)[int(0.95 * len(bucket))] for bucket in buckets_1.values() if len(bucket) > 0]

plt.figure(figsize=(12, 6))
plt.plot(time_bins_1[:len(tail_latency_1)], tail_latency_1, linestyle='--', label='Optimal (95th Percentile)', linewidth=2)
plt.xlabel('Time (seconds)')
plt.ylabel('Tail Latency (ms)')
plt.title(f'Tail Latency (95th Percentile) Over Time (binned every {bin_width}s)')
plt.legend()
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig('plots/tail_latency_over_time.png', dpi=300, bbox_inches='tight')
plt.close()

# Print the overall tail latency for each dataset
def calculate_overall_tail_latency(buckets):
    all_latencies = [lat for bucket in buckets.values() for lat in bucket]
    return sorted(all_latencies)[int(0.95 * len(all_latencies))]

overall_tail_latency_1 = calculate_overall_tail_latency(buckets_1)

print(f'Tail Latency (95th Percentile) for Optimal: {overall_tail_latency_1:.2f} ms')

### ADDITIONAL PLOTS ###

# Throughput over time plot
if http_reqs_1 and timestamps_1:
    # Process throughput data
    throughput_buckets = defaultdict(list)
    for ts, reqs in zip(timestamps_1, http_reqs_1):
        throughput_buckets[int(ts // bin_width)].append(reqs)
    
    throughput_time_bins = [bin_index * bin_width for bin_index in sorted(throughput_buckets.keys())]
    throughput_values = [sum(bucket) / bin_width for bucket in throughput_buckets.values()]  # requests per second
    
    plt.figure(figsize=(12, 6))
    plt.plot(throughput_time_bins, throughput_values, linestyle='-', label='Optimal', linewidth=2, color='green')
    plt.xlabel('Time (seconds)')
    plt.ylabel('Throughput (requests/second)')
    plt.title(f'Throughput Over Time (binned every {bin_width}s)')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig('plots/throughput_over_time.png', dpi=300, bbox_inches='tight')
    plt.close()

# Success rate over time plot
if http_reqs_1 and http_failed_1 and timestamps_1:
    # Process success rate data
    success_buckets = defaultdict(lambda: {'total': 0, 'failed': 0})
    for ts, reqs, failed in zip(timestamps_1, http_reqs_1, http_failed_1):
        bucket_idx = int(ts // bin_width)
        success_buckets[bucket_idx]['total'] += reqs
        success_buckets[bucket_idx]['failed'] += failed
    
    success_time_bins = [bin_index * bin_width for bin_index in sorted(success_buckets.keys())]
    success_rates = [((bucket['total'] - bucket['failed']) / bucket['total'] * 100) 
                    if bucket['total'] > 0 else 0 for bucket in success_buckets.values()]
    
    plt.figure(figsize=(12, 6))
    plt.plot(success_time_bins, success_rates, linestyle='-', label='Optimal', linewidth=2, color='blue')
    plt.xlabel('Time (seconds)')
    plt.ylabel('Success Rate (%)')
    plt.title(f'Success Rate Over Time (binned every {bin_width}s)')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.ylim(0, 105)
    plt.tight_layout()
    plt.savefig('plots/success_rate_over_time.png', dpi=300, bbox_inches='tight')
    plt.close()

# Latency distribution histogram
if latencies_1:
    plt.figure(figsize=(12, 6))
    plt.hist(latencies_1, bins=50, alpha=0.7, edgecolor='black')
    plt.xlabel('Latency (ms)')
    plt.ylabel('Frequency')
    plt.title('Latency Distribution')
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig('plots/latency_distribution.png', dpi=300, bbox_inches='tight')
    plt.close()

print(f"\nAll plots have been saved to the 'plots/' directory:")
print("- average_latency_over_time.png")
print("- tail_latency_over_time.png")
print("- throughput_over_time.png")
print("- success_rate_over_time.png")
print("- latency_distribution.png")