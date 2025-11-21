#!/usr/bin/env python3

import csv
import datetime as dt
import json
import urllib.parse
import urllib.request
import pandas as pd

def prom_query_range(prom_url, query, start, end, step=10):
    """Execute a Prometheus range query"""
    params = {
        "query": query,
        "start": str(start),
        "end": str(end),
        "step": str(step),
    }
    url = f"{prom_url.rstrip('/')}/api/v1/query_range?{urllib.parse.urlencode(params)}"
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

def debug_time_alignment():
    """Debug the time alignment issue in enhanced reports"""
    print("🔍 Debugging Time Alignment Issue")
    print("=" * 50)
    
    # Read the enhanced reports to get time ranges
    try:
        df1 = pd.read_csv('reports/enhanced/enhanced_test_final_hpa1_enhanced.csv')
        print(f"✅ Loaded HPA1 report: {len(df1)} rows")
        
        if len(df1) > 0:
            start_time = int(df1['time_unix'].min())
            end_time = int(df1['time_unix'].max())
            
            start_dt = dt.datetime.utcfromtimestamp(start_time)
            end_dt = dt.datetime.utcfromtimestamp(end_time)
            
            print(f"📅 Time range: {start_dt.isoformat()}Z to {end_dt.isoformat()}Z")
            print(f"📊 Unix timestamps: {start_time} to {end_time}")
            
            # Test Prometheus queries for this exact time range
            prom_url = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
            
            # Test replica query
            replica_query = 'kube_deployment_status_replicas{namespace="socialnetwork",deployment="nginx-thrift"}'
            print(f"\n🔍 Testing replica query for exact time range:")
            print(f"Query: {replica_query}")
            
            result = prom_query_range(prom_url, replica_query, start_time, end_time, step=30)
            if result:
                print(f"✅ Got {len(result)} result series")
                for series in result:
                    values = series.get("values", [])
                    print(f"  Series with {len(values)} data points:")
                    for ts, val in values:
                        dt_obj = dt.datetime.utcfromtimestamp(int(float(ts)))
                        print(f"    {dt_obj.isoformat()}Z = {val} replicas")
            else:
                print("❌ No replica data found")
            
            # Test CPU query
            cpu_query = 'container_cpu_usage_seconds_total{namespace="socialnetwork",pod=~"nginx-thrift-.*",container!=""}'
            print(f"\n💻 Testing CPU query for exact time range:")
            print(f"Query: {cpu_query}")
            
            result = prom_query_range(prom_url, cpu_query, start_time, end_time, step=30)
            if result:
                print(f"✅ Got {len(result)} result series")
                for series in result:
                    values = series.get("values", [])
                    print(f"  Series with {len(values)} data points:")
                    for ts, val in values:
                        dt_obj = dt.datetime.utcfromtimestamp(int(float(ts)))
                        cpu_mcores = float(val) * 1000
                        print(f"    {dt_obj.isoformat()}Z = {val}s = {cpu_mcores:.1f} mcores")
            else:
                print("❌ No CPU data found")
                
            # Test with a wider time range
            print(f"\n🕐 Testing with wider time range (±5 minutes):")
            wider_start = start_time - 300  # 5 minutes before
            wider_end = end_time + 300      # 5 minutes after
            
            result = prom_query_range(prom_url, replica_query, wider_start, wider_end, step=30)
            if result:
                print(f"✅ Got {len(result)} result series with wider range")
                for series in result:
                    values = series.get("values", [])
                    print(f"  Series with {len(values)} data points:")
                    for ts, val in values[:3]:  # Show first 3
                        dt_obj = dt.datetime.utcfromtimestamp(int(float(ts)))
                        print(f"    {dt_obj.isoformat()}Z = {val} replicas")
            else:
                print("❌ No replica data found even with wider range")
        
    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == "__main__":
    debug_time_alignment()
