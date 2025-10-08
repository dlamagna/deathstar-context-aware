import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
from collections import defaultdict
import argparse
import os

def read_enhanced_csv(enhanced_csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(enhanced_csv_path)
    # Ensure expected columns exist
    required = {"time_unix", "reqs", "fail_pct"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"Enhanced CSV missing columns: {missing}")
    return df


def plot_from_enhanced(df: pd.DataFrame, services: list[str]) -> None:
    # Normalize time to start at zero seconds
    t0 = df["time_unix"].min()
    df = df.copy()
    df["t"] = df["time_unix"] - t0

    # Build per-service columns
    replica_cols = [f"{svc}_replicas" for svc in services if f"{svc}_replicas" in df.columns]
    cpu_cols = [f"{svc}_cpu_mcores" for svc in services if f"{svc}_cpu_mcores" in df.columns]

    # Compute success rate (%) if desired
    df["success_pct"] = 100.0 - df["fail_pct"].fillna(0.0)

    # Set global font properties
    plt.rcParams['font.family'] = 'Times New Roman'
    plt.rcParams['font.size'] = 11

    fig, axs = plt.subplots(4, 1, figsize=(6, 9))

    # 1) HTTP success rate
    axs[0].plot(df['t'], df['success_pct'], label='HTTP Success %')
    axs[0].set_xlabel('Time (s)')
    axs[0].set_ylabel('HTTP Success (%)')
    axs[0].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[0].spines['top'].set_visible(False)
    axs[0].spines['right'].set_visible(False)

    # 2) HTTP error rate
    axs[1].plot(df['t'], df['fail_pct'], label='HTTP Error %', color='#E57342')
    axs[1].set_xlabel('Time (s)')
    axs[1].set_ylabel('HTTP Error (%)')
    axs[1].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[1].spines['top'].set_visible(False)
    axs[1].spines['right'].set_visible(False)

    # 3) Replicas per service
    colors = ["#4F83CC", "#FFB300", "#E57342", "#7CB342", "#8E24AA"]
    for idx, col in enumerate(replica_cols):
        axs[2].plot(df['t'], df[col], label=col.replace('_replicas',''), color=colors[idx % len(colors)])
    axs[2].set_xlabel('Time (s)')
    axs[2].set_ylabel('Replicas')
    axs[2].yaxis.set_major_locator(plt.MaxNLocator(integer=True))
    axs[2].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[2].spines['top'].set_visible(False)
    axs[2].spines['right'].set_visible(False)

    # 4) CPU mcores per service
    for idx, col in enumerate(cpu_cols):
        axs[3].plot(df['t'], df[col], label=col.replace('_cpu_mcores',''), color=colors[idx % len(colors)])
    axs[3].set_xlabel('Time (s)')
    axs[3].set_ylabel('CPU (mcores)')
    axs[3].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[3].spines['top'].set_visible(False)
    axs[3].spines['right'].set_visible(False)

    # Global legend from bottom plot handles
    handles, labels = axs[3].get_legend_handles_labels()
    if handles:
        legend = fig.legend(handles, labels, loc='upper center', ncol=min(3, len(labels)), fontsize=10, frameon=True)
        legend.get_frame().set_edgecolor('gray')
        legend.get_frame().set_linewidth(0.8)

    plt.subplots_adjust(top=0.93, hspace=0.4)
    fig.patch.set_facecolor('white')
    plt.show()
# csv_cpu = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/base_chainer_results/CPU consumption by microservice-data-as-joinbyfield-2025-05-05 12_52_01.csv'
# csv_errors = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/base_chainer_results/HTTP Error Rate-data-as-joinbyfield-2025-05-05 12_51_04.csv'
# csv_oks = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/base_chainer_results/HTTP Request Success Rate-data-as-joinbyfield-2025-05-05 12_51_26.csv'
# csv_replicas = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/base_chainer_results/Replicas by microservice-data-as-joinbyfield-2025-05-05 12_51_42.csv'

csv_cpu = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/mod_perfect_experiment/CPU consumption by microservice-data-as-joinbyfield-2025-05-05 18_06_19.csv'
csv_errors = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/mod_perfect_experiment/HTTP Error Rate-data-as-joinbyfield-2025-05-05 18_06_55.csv'
csv_oks = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/mod_perfect_experiment/HTTP Request Success Rate-data-as-joinbyfield-2025-05-05 18_06_48.csv'
csv_replicas = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/mod_perfect_experiment/Replicas by microservice-data-as-joinbyfield-2025-05-05 18_06_37.csv'

# csv_cpu = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/optimal_chainer_results/CPU consumption by microservice-data-as-joinbyfield-2025-05-06 15_37_23.csv'
# csv_errors = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/optimal_chainer_results/HTTP Error Rate-data-as-joinbyfield-2025-05-06 15_37_43.csv'
# csv_oks = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/optimal_chainer_results/HTTP Request Success Rate-data-as-joinbyfield-2025-05-06 15_37_33.csv'
# csv_replicas = '/Users/Berta/Documents/Universitat/PhD/HPA_shared_info/k6/optimal_chainer_results/Replicas by microservice-data-as-joinbyfield-2025-05-06 15_37_11.csv'

parser = argparse.ArgumentParser(description="4x4 plots for k6 and (optionally) enhanced CSV")
parser.add_argument("--enhanced-csv", default=os.environ.get("ENHANCED_CSV", ""), help="Path to enhanced CSV produced by enhanced_report.py")
parser.add_argument("--services", nargs="+", default=["compose-post-service", "text-service", "user-mention-service"], help="Services to plot for replicas/CPU")
args, _ = parser.parse_known_args()

data_cpu = data_errors = data_oks = data_replicas = None
if not (args.enhanced_csv and os.path.exists(args.enhanced_csv)):
    data_cpu = pd.read_csv(csv_cpu, low_memory=False, skiprows=1)
    data_errors = pd.read_csv(csv_errors, low_memory=False, skiprows=1)
    data_oks = pd.read_csv(csv_oks, low_memory=False, skiprows=1)
    data_replicas = pd.read_csv(csv_replicas, low_memory=False, skiprows=1)

# Legacy debug prints removed to support enhanced-only mode

if data_cpu is not None:
    # Rename all columns to Time, chain-1, chain-2, chain-3
    data_cpu.columns = ['Time'] + [f'Service {i+1}' for i in range(len(data_cpu.columns) - 1)]
    data_errors.columns = ['Time'] + [f'Service {i+1}' for i in range(len(data_errors.columns) - 1)]
    data_oks.columns = ['Time'] + [f'Service {i+1}' for i in range(len(data_oks.columns) - 1)]
    data_replicas.columns = ['Time'] + [f'Service {i+1}' for i in range(len(data_replicas.columns) - 1)]

    # Normalize timestamps so it starts from 0 and convert to seconds
    data_cpu['Time'] = (data_cpu['Time'] - data_cpu['Time'].min()) / 1000
    data_errors['Time'] = (data_errors['Time'] - data_errors['Time'].min()) / 1000
    data_oks['Time'] = (data_oks['Time'] - data_oks['Time'].min()) / 1000
    data_replicas['Time'] = (data_replicas['Time'] - data_replicas['Time'].min()) / 1000

    # Cut the data to the first 1500 seconds
    data_cpu = data_cpu[data_cpu['Time'] <= 1500]
    data_errors = data_errors[data_errors['Time'] <= 1500]
    data_oks = data_oks[data_oks['Time'] <= 1500]
    data_replicas = data_replicas[data_replicas['Time'] <= 1500]

    # Transform errors and oks data to percentage
    data_errors.replace('undefined', np.nan, inplace=True)
    data_oks.replace('undefined', np.nan, inplace=True)

    max_value = 22
    data_errors.iloc[:, 1:] = data_errors.iloc[:, 1:].astype(float)
    data_oks.iloc[:, 1:] = data_oks.iloc[:, 1:].astype(float)
    data_errors.fillna(0, inplace=True)
    data_oks.fillna(0, inplace=True)
    data_errors.iloc[:, 1:] = (data_errors.iloc[:, 1:] / max_value) * 100
    data_oks.iloc[:, 1:] = (data_oks.iloc[:, 1:] / max_value) * 100

# Plot CPU consumption for each microservice in the same figure
def plot_cpu(data):
    fig, ax = plt.subplots(figsize=(8, 6))
    for column in data.columns[1:]:
        ax.plot(data['Time'], data[column], label=column)
    ax.set_title('CPU Consumption by Microservice')
    ax.set_xlabel('Time (s)')
    ax.set_ylabel('CPU Consumption (mcore)')
    ax.legend()
    plt.show()

# Plot HTTP error rate for each microservice in the same figure
def plot_errors(data):
    fig, ax = plt.subplots(figsize=(8, 6))
    for column in data.columns[1:]:
        ax.plot(data['Time'], data[column], label=column)
    ax.set_title('HTTP Error Rate by Microservice')
    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Error Rate (%)')
    ax.legend()
    plt.show()

# Plot HTTP request success rate for each microservice in the same figure
def plot_oks(data):
    fig, ax = plt.subplots(figsize=(8, 6))
    for column in data.columns[1:]:
        ax.plot(data['Time'], data[column], label=column)
    ax.set_title('HTTP Request Success Rate by Microservice')
    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Success Rate (%)')
    ax.legend()
    plt.show()

# Plot replicas for each microservice in the same figure
def plot_replicas(data):
    fig, ax = plt.subplots(figsize=(8, 6))
    for column in data.columns[1:]:
        ax.plot(data['Time'], data[column], label=column)
    ax.set_title('Replicas by Microservice')
    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Number of Replicas')
    ax.legend()
    plt.show()

# Plot all metrics in a 1x4 grid
def plot_all_metrics(data_cpu, data_errors, data_oks, data_replicas):
    # Set global font properties
    plt.rcParams['font.family'] = 'Times New Roman'
    plt.rcParams['font.size'] = 11

    fig, axs = plt.subplots(4, 1, figsize=(5, 8))
    
    colors = [
        "#4F83CC",  # Enhanced Intense Blue
        "#E57342",  # Enhanced Intense Peach
        "#FFB300"   # Enhanced Intense Yellow
    ]

    # === Plot HTTP request success rate ===
    for idx, column in enumerate(data_oks.columns[1:]):
        axs[0].plot(data_oks['Time'], data_oks[column], label=column, color=colors[idx % len(colors)])
    axs[0].set_xlabel('Time (s)')
    axs[0].set_ylabel('HTTP Success Rate (%)')
    axs[0].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[0].spines['top'].set_visible(False)
    axs[0].spines['right'].set_visible(False)

    # === Plot HTTP error rate ===
    axs[1].plot(data_errors['Time'], data_errors['Service 3'], label='', alpha=0.0)
    axs[1].plot(data_errors['Time'], data_errors['Service 1'], label='Service 2', color=colors[1])
    axs[1].plot(data_errors['Time'], data_errors['Service 2'], label='Service 3', color=colors[2])
    axs[1].set_ylim(0, 80)
    axs[1].set_xlabel('Time (s)')
    axs[1].set_ylabel('HTTP Error Rate (%)')
    axs[1].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[1].spines['top'].set_visible(False)
    axs[1].spines['right'].set_visible(False)

    # === Plot replicas ===
    for idx, column in enumerate(data_replicas.columns[1:]):
        axs[2].plot(data_replicas['Time'], data_replicas[column], label=column, color=colors[idx % len(colors)])
    axs[2].set_xlabel('Time (s)')
    axs[2].set_ylabel('Number of Replicas')
    axs[2].set_ylim(0.9, 3.1)
    axs[2].yaxis.set_major_locator(plt.MaxNLocator(integer=True))
    axs[2].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[2].spines['top'].set_visible(False)
    axs[2].spines['right'].set_visible(False)

    # === Plot CPU consumption ===
    for idx, column in enumerate(data_cpu.columns[1:]):
        axs[3].plot(data_cpu['Time'], data_cpu[column], label=column, color=colors[idx % len(colors)])
    axs[3].set_xlabel('Time (s)')
    axs[3].set_ylabel('CPU (mcore)')
    axs[3].grid(True, linestyle='--', linewidth=0.5, color='gray')
    axs[3].spines['top'].set_visible(False)
    axs[3].spines['right'].set_visible(False)

    # === Global Legend ===
    handles, labels = axs[0].get_legend_handles_labels()
    legend = fig.legend(handles, labels, loc='upper center', ncol=3, fontsize=10, frameon=True)
    legend.get_frame().set_edgecolor('gray')
    legend.get_frame().set_linewidth(0.8)

    # === Styling and Layout Adjustments ===
    plt.subplots_adjust(top=0.95, hspace=0.4)
    fig.patch.set_facecolor('white')
    
    # Show the plot
    plt.show()


if data_cpu is not None:
    # Only print legacy columns when legacy CSVs are present
    print(data_cpu.columns)
    print(data_errors.columns)
    print(data_oks.columns)
    print(data_replicas.columns)
    plot_all_metrics(data_cpu, data_errors, data_oks, data_replicas)

# Optional: plot from enhanced CSV (joined k6 + Prometheus)
if args.enhanced_csv and os.path.exists(args.enhanced_csv):
    try:
        df_enh = read_enhanced_csv(args.enhanced_csv)
        plot_from_enhanced(df_enh, args.services)
    except Exception as e:
        print(f"[WARN] Skipping enhanced plot: {e}")