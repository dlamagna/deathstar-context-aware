import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import os
import sys
import numpy as np
import argparse
from collections import defaultdict


class _Tee:
    """Duplicate writes to both the original stream and a file."""
    def __init__(self, stream, filepath):
        self._stream = stream
        self._file = open(filepath, "w")
    def write(self, data):
        self._stream.write(data)
        self._file.write(data)
    def flush(self):
        self._stream.flush()
        self._file.flush()
    def close(self):
        self._file.close()

# Parse command line arguments
parser = argparse.ArgumentParser(
    description='Compare two k6 CSV reports',
    epilog='''Ad-hoc usage examples:
  %(prog)s report_a.csv report_b.csv
  %(prog)s report_a.csv report_b.csv --plots-dir ./my_comparison
  %(prog)s --a report_a.csv --b report_b.csv --label-a "Context HPA" --label-b "Default HPA"
''',
    formatter_class=argparse.RawDescriptionHelpFormatter,
)
parser.add_argument('positional', nargs='*', metavar='CSV',
                    help='Two k6 CSV files to compare (shorthand for --a / --b)')
parser.add_argument('--a', '--base', dest='base_report', default=None,
                    help='Base report CSV file path')
parser.add_argument('--b', '--comparison', dest='comparison_report', default=None,
                    help='Comparison report CSV file path')
parser.add_argument('--label-a', dest='label_a', default=None,
                    help='Label for base report (default: filename)')
parser.add_argument('--label-b', dest='label_b', default=None,
                    help='Label for comparison report (default: filename)')
parser.add_argument('--out', dest='output_file', default=None,
                    help='Output JSON file (default: <plots-dir>/comparison_result.json)')
parser.add_argument('--plots-dir', dest='plots_dir', default=None,
                    help='Directory to save comparison plots (default: auto-created next to CSVs)')
parser.add_argument('--sample', dest='sample_size', type=int, default=None,
                    help='Sample N rows per metric for faster analysis (default: use all data)')

args = parser.parse_args()

# Resolve positional args: allow `script.py a.csv b.csv`
if args.positional and len(args.positional) >= 2:
    if not args.base_report:
        args.base_report = args.positional[0]
    if not args.comparison_report:
        args.comparison_report = args.positional[1]

if not args.base_report or not args.comparison_report:
    parser.error("Two CSV files required. Use positional args or --a / --b.")

BASE_REPORT = args.base_report
COMPARISON_REPORT = args.comparison_report

# Auto-generate friendly labels from filenames
def _label_from_path(path):
    name = os.path.splitext(os.path.basename(path))[0]
    for suffix in ('_hpa1', '_hpa2'):
        if suffix in name:
            return suffix[1:].upper()
    return name[-30:] if len(name) > 30 else name

LABEL_A = args.label_a or _label_from_path(BASE_REPORT)
LABEL_B = args.label_b or _label_from_path(COMPARISON_REPORT)

# Auto-generate plots dir if not specified
if args.plots_dir:
    PLOTS_DIR = args.plots_dir
else:
    from datetime import datetime
    tag = datetime.utcnow().strftime('%H%M%SZ')
    parent = os.path.dirname(os.path.abspath(BASE_REPORT))
    PLOTS_DIR = os.path.join(parent, f"comparison_{tag}")

OUTPUT_FILE = args.output_file or os.path.join(PLOTS_DIR, 'comparison_result.json')

SAMPLE_SIZE = args.sample_size  # None means use all data
TIME_LIMIT = 1100               # Maximum time in seconds to analyze

# Create plots directory if it doesn't exist
os.makedirs(PLOTS_DIR, exist_ok=True)

# Auto-save all stdout to a log file alongside the plots
_tee = _Tee(sys.stdout, os.path.join(PLOTS_DIR, "comparison.log"))
sys.stdout = _tee

def extract_metric_data_fast(data, metric_name, sample_size=SAMPLE_SIZE):
    """Extract timestamp and value pairs for a specific metric, optionally sampling."""
    metric_rows = data[data.iloc[:, 0] == metric_name]
    
    if len(metric_rows) == 0:
        return [], []
    
    if sample_size is not None and len(metric_rows) > sample_size:
        step = len(metric_rows) // sample_size
        metric_rows = metric_rows.iloc[::step].head(sample_size)
    
    # Extract timestamps and values
    timestamps = metric_rows.iloc[:, 1].astype(float).tolist()
    values = metric_rows.iloc[:, 2].astype(float).tolist()
    
    if not timestamps:
        return [], []
    
    # Normalize timestamps so that the initial timestamp is 0
    first_timestamp = timestamps[0]
    normalized_timestamps = [ts - first_timestamp for ts in timestamps]
    
    # Keep only timestamps smaller than TIME_LIMIT
    filtered_data = [(ts, val) for ts, val in zip(normalized_timestamps, values) if ts < TIME_LIMIT]
    
    if filtered_data:
        return zip(*filtered_data)
    return [], []

def calculate_high_level_metrics(timestamps, latencies, http_reqs, http_failed, checks, data_sent, data_received, iterations, iteration_duration):
    """Calculate high-level performance metrics efficiently"""
    metrics = {}
    
    # Basic latency metrics (using numpy for speed)
    if latencies:
        latencies_array = np.array(latencies)
        metrics['avg_latency'] = np.mean(latencies_array)
        metrics['min_latency'] = np.min(latencies_array)
        metrics['max_latency'] = np.max(latencies_array)
        metrics['p50_latency'] = np.percentile(latencies_array, 50)
        metrics['p95_latency'] = np.percentile(latencies_array, 95)
        metrics['p99_latency'] = np.percentile(latencies_array, 99)
        metrics['std_latency'] = np.std(latencies_array)
    
    # Success rate calculation
    if http_reqs and http_failed:
        total_requests = np.sum(http_reqs)
        total_failed = np.sum(http_failed)
        metrics['success_rate'] = ((total_requests - total_failed) / total_requests * 100) if total_requests > 0 else 0
        metrics['failure_rate'] = (total_failed / total_requests * 100) if total_requests > 0 else 0
        metrics['total_requests'] = total_requests
        metrics['total_failed'] = total_failed
    
    # Check success rate
    if checks:
        total_checks = np.sum(checks)
        metrics['check_success_rate'] = (total_checks / len(checks) * 100) if len(checks) > 0 else 0
        metrics['total_checks'] = total_checks
    
    # Throughput metrics
    if timestamps and http_reqs:
        test_duration = max(timestamps) - min(timestamps) if timestamps else 0
        total_requests = np.sum(http_reqs)
        metrics['requests_per_second'] = total_requests / test_duration if test_duration > 0 else 0
        metrics['test_duration'] = test_duration
    
    # Data transfer metrics
    if data_sent:
        metrics['total_data_sent'] = np.sum(data_sent)
        metrics['avg_data_sent_per_request'] = np.mean(data_sent)
    if data_received:
        metrics['total_data_received'] = np.sum(data_received)
        metrics['avg_data_received_per_request'] = np.mean(data_received)
    
    # Iteration metrics
    if iterations:
        metrics['total_iterations'] = np.sum(iterations)
    if iteration_duration:
        metrics['avg_iteration_duration'] = np.mean(iteration_duration)
        metrics['min_iteration_duration'] = np.min(iteration_duration)
        metrics['max_iteration_duration'] = np.max(iteration_duration)
    
    return metrics

# Removed old function - using calculate_high_level_metrics instead

def print_comparison_metrics(metrics_base, metrics_comp, base_label, comp_label):
    """Print formatted comparison metrics"""
    print(f"\n{'='*80}")
    print(f"COMPARISON: {base_label} vs {comp_label}")
    print(f"{'='*80}")
    
    # Latency comparison
    if 'avg_latency' in metrics_base and 'avg_latency' in metrics_comp:
        print(f"\n📊 LATENCY COMPARISON:")
        print(f"{'Metric':<20} {'Base':<15} {'Comparison':<15} {'Difference':<15} {'% Change':<15}")
        print(f"{'-'*80}")
        
        latency_metrics = ['avg_latency', 'min_latency', 'max_latency', 'p50_latency', 'p95_latency', 'p99_latency']
        for metric in latency_metrics:
            if metric in metrics_base and metric in metrics_comp:
                base_val = metrics_base[metric]
                comp_val = metrics_comp[metric]
                diff = comp_val - base_val
                pct_change = (diff / base_val * 100) if base_val != 0 else 0
                print(f"{metric.replace('_', ' ').title():<20} {base_val:<15.2f} {comp_val:<15.2f} {diff:<15.2f} {pct_change:<15.2f}%")
    
    # Success rate comparison
    if 'success_rate' in metrics_base and 'success_rate' in metrics_comp:
        print(f"\n✅ SUCCESS RATE COMPARISON:")
        print(f"{'Metric':<25} {'Base':<15} {'Comparison':<15} {'Difference':<15} {'% Change':<15}")
        print(f"{'-'*85}")
        
        base_success = metrics_base['success_rate']
        comp_success = metrics_comp['success_rate']
        diff = comp_success - base_success
        pct_change = (diff / base_success * 100) if base_success != 0 else 0
        print(f"{'Success Rate (%)':<25} {base_success:<15.2f} {comp_success:<15.2f} {diff:<15.2f} {pct_change:<15.2f}%")
        
        base_failure = metrics_base['failure_rate']
        comp_failure = metrics_comp['failure_rate']
        diff_fail = comp_failure - base_failure
        pct_change_fail = (diff_fail / base_failure * 100) if base_failure != 0 else 0
        print(f"{'Failure Rate (%)':<25} {base_failure:<15.2f} {comp_failure:<15.2f} {diff_fail:<15.2f} {pct_change_fail:<15.2f}%")
    
    # Throughput comparison
    if 'requests_per_second' in metrics_base and 'requests_per_second' in metrics_comp:
        print(f"\n🚀 THROUGHPUT COMPARISON:")
        print(f"{'Metric':<25} {'Base':<15} {'Comparison':<15} {'Difference':<15} {'% Change':<15}")
        print(f"{'-'*85}")
        
        base_rps = metrics_base['requests_per_second']
        comp_rps = metrics_comp['requests_per_second']
        diff = comp_rps - base_rps
        pct_change = (diff / base_rps * 100) if base_rps != 0 else 0
        print(f"{'Requests/Second':<25} {base_rps:<15.2f} {comp_rps:<15.2f} {diff:<15.2f} {pct_change:<15.2f}%")
    
    # Data transfer comparison
    if 'total_data_sent' in metrics_base and 'total_data_sent' in metrics_comp:
        print(f"\n📡 DATA TRANSFER COMPARISON:")
        print(f"{'Metric':<30} {'Base':<15} {'Comparison':<15} {'Difference':<15} {'% Change':<15}")
        print(f"{'-'*90}")
        
        base_sent = metrics_base['total_data_sent']
        comp_sent = metrics_comp['total_data_sent']
        diff = comp_sent - base_sent
        pct_change = (diff / base_sent * 100) if base_sent != 0 else 0
        print(f"{'Total Data Sent (bytes)':<30} {base_sent:<15.0f} {comp_sent:<15.0f} {diff:<15.0f} {pct_change:<15.2f}%")
        
        if 'total_data_received' in metrics_base and 'total_data_received' in metrics_comp:
            base_recv = metrics_base['total_data_received']
            comp_recv = metrics_comp['total_data_received']
            diff = comp_recv - base_recv
            pct_change = (diff / base_recv * 100) if base_recv != 0 else 0
            print(f"{'Total Data Received (bytes)':<30} {base_recv:<15.0f} {comp_recv:<15.0f} {diff:<15.0f} {pct_change:<15.2f}%")

def process_buckets(timestamps, latencies, bin_width):
    """Process data into time buckets for plotting"""
    buckets = defaultdict(list)
    for ts, lat in zip(timestamps, latencies):
        buckets[int(ts // bin_width)].append(lat)
    averaged_latencies = [sum(bucket) / len(bucket) for bucket in buckets.values()]
    time_bins = [bin_index * bin_width for bin_index in sorted(buckets.keys())]
    return buckets, averaged_latencies, time_bins

def create_simple_comparison_plots(latencies_base, latencies_comp, base_label, comp_label, plots_dir=PLOTS_DIR):
    """Create simplified comparison plots for fast analysis"""
    
    # 1. Latency Distribution Comparison
    plt.figure(figsize=(12, 6))
    plt.hist(latencies_base, bins=50, alpha=0.6, label=base_label, color='blue', edgecolor='black')
    plt.hist(latencies_comp, bins=50, alpha=0.6, label=comp_label, color='red', edgecolor='black')
    plt.xlabel('Latency (ms)')
    plt.ylabel('Frequency')
    plt.title(f'Latency Distribution Comparison: {base_label} vs {comp_label}')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(plots_dir, 'comparison_latency_distribution.png'), dpi=300, bbox_inches='tight')
    plt.close()
    
    # 2. Simple metrics summary plot
    fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(15, 10))
    
    # Average latency comparison
    avg_base = np.mean(latencies_base)
    avg_comp = np.mean(latencies_comp)
    ax1.bar([base_label, comp_label], [avg_base, avg_comp], color=['blue', 'red'], alpha=0.7)
    ax1.set_title('Average Latency Comparison')
    ax1.set_ylabel('Latency (ms)')
    ax1.grid(True, alpha=0.3)
    
    # P95 latency comparison
    p95_base = np.percentile(latencies_base, 95)
    p95_comp = np.percentile(latencies_comp, 95)
    ax2.bar([base_label, comp_label], [p95_base, p95_comp], color=['blue', 'red'], alpha=0.7)
    ax2.set_title('P95 Latency Comparison')
    ax2.set_ylabel('Latency (ms)')
    ax2.grid(True, alpha=0.3)
    
    # Min latency comparison
    min_base = np.min(latencies_base)
    min_comp = np.min(latencies_comp)
    ax3.bar([base_label, comp_label], [min_base, min_comp], color=['blue', 'red'], alpha=0.7)
    ax3.set_title('Min Latency Comparison')
    ax3.set_ylabel('Latency (ms)')
    ax3.grid(True, alpha=0.3)
    
    # Max latency comparison
    max_base = np.max(latencies_base)
    max_comp = np.max(latencies_comp)
    ax4.bar([base_label, comp_label], [max_base, max_comp], color=['blue', 'red'], alpha=0.7)
    ax4.set_title('Max Latency Comparison')
    ax4.set_ylabel('Latency (ms)')
    ax4.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(os.path.join(plots_dir, 'comparison_metrics_summary.png'), dpi=300, bbox_inches='tight')
    plt.close()

# Main execution
if __name__ == "__main__":
    print(f"🚀 K6 Report Comparison")
    print(f"  [{LABEL_A}] {BASE_REPORT}")
    print(f"  [{LABEL_B}] {COMPARISON_REPORT}")
    print(f"Output: {PLOTS_DIR}/")
    if SAMPLE_SIZE is not None:
        print(f"Sampling {SAMPLE_SIZE} rows per metric for speed...")
    else:
        print(f"Using all data (no sampling)")
    
    # Load CSV files
    try:
        print("📁 Loading reports...")
        data_base = pd.read_csv(BASE_REPORT, low_memory=False)
        data_comp = pd.read_csv(COMPARISON_REPORT, low_memory=False)
        print(f"✅ Base report loaded: {len(data_base)} rows")
        print(f"✅ Comparison report loaded: {len(data_comp)} rows")
    except FileNotFoundError as e:
        print(f"❌ Error: Could not find report file - {e}")
        exit(1)
    
    print("⚡ Extracting metrics...")
    timestamps_base, latencies_base = extract_metric_data_fast(data_base, 'http_req_duration')
    _, http_reqs_base = extract_metric_data_fast(data_base, 'http_reqs')
    _, http_failed_base = extract_metric_data_fast(data_base, 'http_req_failed')
    _, checks_base = extract_metric_data_fast(data_base, 'checks')
    _, data_sent_base = extract_metric_data_fast(data_base, 'data_sent')
    _, data_received_base = extract_metric_data_fast(data_base, 'data_received')
    _, iterations_base = extract_metric_data_fast(data_base, 'iterations')
    _, iteration_duration_base = extract_metric_data_fast(data_base, 'iteration_duration')
    
    timestamps_comp, latencies_comp = extract_metric_data_fast(data_comp, 'http_req_duration')
    _, http_reqs_comp = extract_metric_data_fast(data_comp, 'http_reqs')
    _, http_failed_comp = extract_metric_data_fast(data_comp, 'http_req_failed')
    _, checks_comp = extract_metric_data_fast(data_comp, 'checks')
    _, data_sent_comp = extract_metric_data_fast(data_comp, 'data_sent')
    _, data_received_comp = extract_metric_data_fast(data_comp, 'data_received')
    _, iterations_comp = extract_metric_data_fast(data_comp, 'iterations')
    _, iteration_duration_comp = extract_metric_data_fast(data_comp, 'iteration_duration')
    
    # Calculate high-level metrics for both reports
    print("📊 Calculating high-level metrics...")
    metrics_base = calculate_high_level_metrics(timestamps_base, latencies_base, http_reqs_base, http_failed_base,
                                              checks_base, data_sent_base, data_received_base, iterations_base, iteration_duration_base)
    
    metrics_comp = calculate_high_level_metrics(timestamps_comp, latencies_comp, http_reqs_comp, http_failed_comp,
                                              checks_comp, data_sent_comp, data_received_comp, iterations_comp, iteration_duration_comp)
    
    # Print comparison metrics
    base_label = LABEL_A
    comp_label = LABEL_B
    print_comparison_metrics(metrics_base, metrics_comp, base_label, comp_label)
    
    # Create simplified comparison plots (only if we have enough data)
    if latencies_base and latencies_comp:
        print("\n📈 Generating simplified comparison plots...")
        create_simple_comparison_plots(latencies_base, latencies_comp, base_label, comp_label, PLOTS_DIR)
        
        print(f"\n🎉 Fast comparison complete!")
        print(f"📊 Comparison plots saved to '{PLOTS_DIR}/':")
        print("- comparison_latency_distribution.png")
        print("- comparison_metrics_summary.png")
    else:
        print("\n⚠️  Insufficient data for plotting, but metrics comparison completed!")
