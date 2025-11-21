#!/usr/bin/env python3

import csv
import datetime as dt
import json
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
import pandas as pd
import numpy as np

def prom_query(prom_url, query):
    """Execute a single Prometheus query"""
    params = {"query": query}
    url = f"{prom_url.rstrip('/')}/api/v1/query?{urllib.parse.urlencode(params)}"
    print(f"[DEBUG] Querying: {url}")
    
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        
        if payload.get("status") != "success":
            print(f"❌ Prometheus query failed: {payload}")
            return None
            
        return payload["data"]["result"]
    except Exception as e:
        print(f"❌ Error querying Prometheus: {e}")
        return None

def check_prometheus_metrics(prom_url, namespace, services):
    """Check what Prometheus metrics are available"""
    print("🔍 Checking Prometheus metrics availability...")
    
    # Check basic Prometheus connectivity
    result = prom_query(prom_url, "up")
    if result is None:
        print("❌ Cannot connect to Prometheus")
        return False
    
    print(f"✅ Prometheus is accessible, found {len(result)} metrics")
    
    # Check for kube-state-metrics
    ksm_result = prom_query(prom_url, 'kube_deployment_status_replicas')
    if ksm_result:
        print(f"✅ kube-state-metrics found: {len(ksm_result)} deployments")
        for metric in ksm_result[:3]:  # Show first 3
            labels = metric.get("metric", {})
            print(f"  Deployment: {labels.get('deployment')} in namespace {labels.get('namespace')}")
    else:
        print("❌ kube-state-metrics not found")
    
    # Check for cAdvisor metrics
    cadvisor_result = prom_query(prom_url, 'container_cpu_usage_seconds_total')
    if cadvisor_result:
        print(f"✅ cAdvisor metrics found: {len(cadvisor_result)} containers")
        for metric in cadvisor_result[:3]:  # Show first 3
            labels = metric.get("metric", {})
            print(f"  Container: {labels.get('container')} in pod {labels.get('pod')}")
    else:
        print("❌ cAdvisor metrics not found")
    
    # Check for specific services
    for service in services:
        print(f"\n📊 Checking metrics for {service}:")
        
        # Check deployment replicas
        replica_query = f'kube_deployment_status_replicas{{namespace="{namespace}",deployment="{service}"}}'
        replica_result = prom_query(prom_url, replica_query)
        if replica_result:
            print(f"  ✅ Replica metrics: {len(replica_result)} found")
            for metric in replica_result:
                value = float(metric.get("value", [0, "0"])[1])
                print(f"    Current replicas: {value}")
        else:
            print(f"  ❌ No replica metrics found for {service}")
        
        # Check CPU usage
        cpu_query = f'container_cpu_usage_seconds_total{{namespace="{namespace}",pod=~"{service}-.*",container!=""}}'
        cpu_result = prom_query(prom_url, cpu_query)
        if cpu_result:
            print(f"  ✅ CPU metrics: {len(cpu_result)} containers found")
            total_cpu = sum(float(metric.get("value", [0, "0"])[1]) for metric in cpu_result)
            print(f"    Total CPU usage: {total_cpu:.4f} seconds")
        else:
            print(f"  ❌ No CPU metrics found for {service}")
    
    return True

def analyze_enhanced_reports(hpa1_file, hpa2_file, services):
    """Analyze the enhanced CSV reports"""
    print("\n📊 Analyzing Enhanced Reports...")
    
    try:
        df1 = pd.read_csv(hpa1_file)
        df2 = pd.read_csv(hpa2_file)
        
        print(f"✅ HPA1 report: {len(df1)} rows, {len(df1.columns)} columns")
        print(f"✅ HPA2 report: {len(df2)} rows, {len(df2.columns)} columns")
        
        print(f"\n📋 Available columns:")
        for col in df1.columns:
            print(f"  - {col}")
        
        print(f"\n📈 k6 Metrics Summary:")
        print(f"  HPA1: {df1['reqs'].sum()} requests, {df1['fail_pct'].mean():.1f}% avg failure rate")
        print(f"  HPA2: {df2['reqs'].sum()} requests, {df2['fail_pct'].mean():.1f}% avg failure rate")
        
        print(f"\n🔄 HPA Scaling Analysis:")
        for service in services:
            replica_col = f'{service}_replicas'
            cpu_col = f'{service}_cpu_mcores'
            
            print(f"\n📊 {service.upper()}:")
            
            # Replica analysis
            if replica_col in df1.columns and replica_col in df2.columns:
                df1_replicas = df1[replica_col].dropna()
                df2_replicas = df2[replica_col].dropna()
                
                print(f"  Replica data points: HPA1={len(df1_replicas)}, HPA2={len(df2_replicas)}")
                
                if len(df1_replicas) > 0 and len(df2_replicas) > 0:
                    max_replicas_1 = df1_replicas.max()
                    max_replicas_2 = df2_replicas.max()
                    avg_replicas_1 = df1_replicas.mean()
                    avg_replicas_2 = df2_replicas.mean()
                    
                    print(f"  Max Replicas: HPA1 = {max_replicas_1:.1f}, HPA2 = {max_replicas_2:.1f}")
                    print(f"  Avg Replicas: HPA1 = {avg_replicas_1:.1f}, HPA2 = {avg_replicas_2:.1f}")
                    
                    replica_diff = abs(max_replicas_1 - max_replicas_2)
                    if replica_diff > 0.5:
                        print(f"  ⚠️  SIGNIFICANT SCALING DIFFERENCE: {replica_diff:.1f} replicas")
                    else:
                        print(f"  ✅ Similar scaling: {replica_diff:.1f} replica difference")
                else:
                    print(f"  ❌ No replica data (all null values)")
                    # Show sample values for debugging
                    print(f"    Sample HPA1 values: {df1[replica_col].head().tolist()}")
                    print(f"    Sample HPA2 values: {df2[replica_col].head().tolist()}")
            else:
                print(f"  ❌ Replica column '{replica_col}' not found")
            
            # CPU analysis
            if cpu_col in df1.columns and cpu_col in df2.columns:
                df1_cpu = df1[cpu_col].dropna()
                df2_cpu = df2[cpu_col].dropna()
                
                print(f"  CPU data points: HPA1={len(df1_cpu)}, HPA2={len(df2_cpu)}")
                
                if len(df1_cpu) > 0 and len(df2_cpu) > 0:
                    max_cpu_1 = df1_cpu.max()
                    max_cpu_2 = df2_cpu.max()
                    avg_cpu_1 = df1_cpu.mean()
                    avg_cpu_2 = df2_cpu.mean()
                    
                    print(f"  Max CPU (mcores): HPA1 = {max_cpu_1:.1f}, HPA2 = {max_cpu_2:.1f}")
                    print(f"  Avg CPU (mcores): HPA1 = {avg_cpu_1:.1f}, HPA2 = {avg_cpu_2:.1f}")
                    
                    cpu_diff = abs(max_cpu_1 - max_cpu_2)
                    if cpu_diff > 100:
                        print(f"  ⚠️  SIGNIFICANT CPU DIFFERENCE: {cpu_diff:.1f} mcores")
                    else:
                        print(f"  ✅ Similar CPU usage: {cpu_diff:.1f} mcore difference")
                else:
                    print(f"  ❌ No CPU data (all null values)")
                    # Show sample values for debugging
                    print(f"    Sample HPA1 values: {df1[cpu_col].head().tolist()}")
                    print(f"    Sample HPA2 values: {df2[cpu_col].head().tolist()}")
            else:
                print(f"  ❌ CPU column '{cpu_col}' not found")
        
        # Time range analysis
        if 'time_unix' in df1.columns and 'time_unix' in df2.columns:
            print(f"\n⏰ Time Range Analysis:")
            print(f"  HPA1: {df1['time_unix'].min()} to {df1['time_unix'].max()}")
            print(f"  HPA2: {df2['time_unix'].min()} to {df2['time_unix'].max()}")
            
            # Convert to readable times
            start1 = dt.datetime.utcfromtimestamp(df1['time_unix'].min())
            end1 = dt.datetime.utcfromtimestamp(df1['time_unix'].max())
            start2 = dt.datetime.utcfromtimestamp(df2['time_unix'].min())
            end2 = dt.datetime.utcfromtimestamp(df2['time_unix'].max())
            
            print(f"  HPA1: {start1.isoformat()}Z to {end1.isoformat()}Z")
            print(f"  HPA2: {start2.isoformat()}Z to {end2.isoformat()}Z")
        
        return True
        
    except Exception as e:
        print(f"❌ Error analyzing reports: {e}")
        return False

def main():
    prom_url = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    namespace = "socialnetwork"
    services = ["nginx-thrift", "compose-post-service", "text-service", "user-mention-service"]
    
    print("🚀 HPA Metrics Analyzer (Inside Cluster)")
    print("=" * 50)
    
    # Check Prometheus metrics availability
    if not check_prometheus_metrics(prom_url, namespace, services):
        print("❌ Prometheus metrics check failed")
        return
    
    print("\n✅ Prometheus metrics check completed successfully!")
    print("\n💡 Next steps:")
    print("1. Run a longer test with higher load to trigger HPA scaling")
    print("2. Check that kube-state-metrics and cAdvisor are properly configured")
    print("3. Verify HPA is configured with appropriate CPU targets")

if __name__ == "__main__":
    main()
