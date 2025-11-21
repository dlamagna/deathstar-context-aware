#!/usr/bin/env python3
import argparse
import json
import os
import re
from datetime import datetime
from typing import List, Dict, Any, Tuple

import requests
import pandas as pd
import matplotlib.pyplot as plt


def sanitize_filename(name: str) -> str:
    name = name.strip().replace(' ', '_')
    name = re.sub(r'[^A-Za-z0-9_\-\.]+', '', name)
    return name[:200] if len(name) > 200 else name


def format_utc_compact(ts: int) -> str:
    return datetime.utcfromtimestamp(ts).strftime('%Y%m%dT%H%M%SZ')


def load_dashboard(path: str) -> Dict[str, Any]:
    with open(path, 'r') as f:
        return json.load(f)


def collect_panels(dashboard: Dict[str, Any]) -> List[Dict[str, Any]]:
    panels: List[Dict[str, Any]] = []

    def visit(panel_obj: Dict[str, Any]) -> None:
        # Recurse into nested rows/panels if present (Grafana often nests panels inside rows)
        if isinstance(panel_obj, dict) and 'panels' in panel_obj and isinstance(panel_obj['panels'], list):
            for child in panel_obj['panels']:
                visit(child)
            return

        if not isinstance(panel_obj, dict):
            return

        title = panel_obj.get('title') or 'panel'
        targets = []
        for target in panel_obj.get('targets', []):
            if target.get('hide') is True:
                continue
            expr = target.get('expr')
            legend = target.get('legendFormat') or target.get('refId') or 'metric'
            if not expr:
                continue
            targets.append({'legend': legend, 'expr': expr})
        if targets:
            panels.append({'title': title, 'targets': targets})

    for panel in dashboard.get('panels', []):
        visit(panel)

    return panels


def prom_query_range(prom_url: str, query: str, start: int, end: int, step: int = 15) -> pd.DataFrame:
    params = {
        'query': query,
        'start': start,
        'end': end,
        'step': f'{step}s',
    }
    resp = requests.get(f'{prom_url}/api/v1/query_range', params=params, timeout=60)
    resp.raise_for_status()
    data = resp.json()
    if data.get('status') != 'success':
        raise RuntimeError(f'Prometheus error: {data}')
    series = data.get('data', {}).get('result', [])
    frames = []
    for s in series:
        values = s.get('values', [])
        if not values:
            continue
        ts = [int(v[0]) for v in values]
        vals = [float(v[1]) if v[1] not in (None, 'NaN', 'Inf', '-Inf') else float('nan') for v in values]
        frames.append(pd.DataFrame({'ts': ts, 'value': vals}))
    if not frames:
        return pd.DataFrame({'ts': [], 'value': []})
    df = frames[0]
    for other in frames[1:]:
        df = df.merge(other, on='ts', how='outer', suffixes=('', '_other'))
        value_cols = [c for c in df.columns if c.startswith('value')]
        df['value'] = df[value_cols].sum(axis=1, skipna=True)
        df = df[['ts', 'value']]
    df.sort_values('ts', inplace=True)
    return df


def build_master_index(start: int, end: int, step: int) -> List[int]:
    return list(range(start, end + 1, step))


def save_master_csv(ts: List[int], col_to_values: Dict[str, List[float]], out_path: str) -> None:
    df = pd.DataFrame({'ts': ts})
    df['time_iso'] = df['ts'].apply(lambda x: datetime.utcfromtimestamp(x).isoformat() + 'Z')
    for col, values in col_to_values.items():
        df[col] = values
    cols = ['ts', 'time_iso'] + [k for k in col_to_values.keys()]
    df[cols].to_csv(out_path, index=False)


def save_panel_plot(ts: List[int], legend_to_values: Dict[str, List[float]], title: str, out_path: str) -> None:
    plt.figure(figsize=(11, 4))
    x = [datetime.utcfromtimestamp(t) for t in ts]
    for legend, values in legend_to_values.items():
        plt.plot(x, values, label=legend, linewidth=1.6)
    plt.title(title)
    plt.xlabel('Time (UTC)')
    plt.ylabel('Value')
    plt.grid(True, alpha=0.3)
    plt.legend(loc='best', ncol=4)
    plt.tight_layout()
    plt.savefig(out_path)
    plt.close()


def overlay_panel(prom_url: str, panel: Dict[str, Any], start: int, end: int, step: int, ts_master: List[int], var_map: Dict[str, str]) -> Tuple[Dict[str, List[float]], Dict[str, List[float]]]:
    # Returns: (legend_to_values_for_panel, global_col_values)
    filtered = [t for t in panel['targets'] if 'nginx' not in t['legend'].lower()]
    legend_to_series: Dict[str, pd.DataFrame] = {}
    for t in filtered:
        expr = substitute_grafana_vars(t['expr'], var_map, step)
        df = prom_query_range(prom_url, expr, start, end, step)
        if df.empty:
            continue
        legend_to_series[t['legend']] = df
    legend_to_values: Dict[str, List[float]] = {}
    global_cols: Dict[str, List[float]] = {}
    for legend, df in legend_to_series.items():
        aligned = pd.DataFrame({'ts': ts_master}).merge(df, on='ts', how='left')
        vals = aligned['value'].tolist()
        legend_to_values[legend] = vals
    return legend_to_values, global_cols  # global_cols unused in current design


def build_variable_map(dashboard: Dict[str, Any]) -> Dict[str, str]:
    var_map: Dict[str, str] = {}
    templ = dashboard.get('templating', {}).get('list', [])
    for item in templ:
        name = item.get('name') or item.get('label')
        if not name:
            continue
        current = item.get('current', {})
        value = current.get('value') if isinstance(current, dict) else None
        # If multi-select, current value can be a list
        if isinstance(value, list):
            # Join with | for regex matchers, or comma for set. Keep as comma-separated by default
            value = ','.join([str(v) for v in value if v is not None])
        if not value:
            # Fall back to first selected option or first option
            options = item.get('options', [])
            selected = next((opt for opt in options if opt.get('selected')), None)
            if selected is not None:
                value = selected.get('value') or selected.get('text')
            elif options:
                value = options[0].get('value') or options[0].get('text')
        # Allow environment overrides for common vars
        env_override = os.environ.get(name.upper()) or os.environ.get(name)
        if env_override:
            value = env_override
        if value is None:
            continue
        var_map[name] = str(value)
    return var_map


def substitute_grafana_vars(expr: str, var_map: Dict[str, str], step: int) -> str:
    # Handle Grafana built-ins
    interval_s = f"{step}s"
    expr = expr.replace('$__interval_ms', str(step * 1000))
    expr = expr.replace('$__interval', interval_s)
    expr = expr.replace('$__rate_interval', interval_s)

    # Replace ${var} and $var using the map
    def replace_var(match: re.Match) -> str:
        var = match.group(1) or match.group(2)
        if not var:
            return match.group(0)
        return var_map.get(var, match.group(0))

    # ${var} or $var patterns
    pattern = re.compile(r'\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}|\$([a-zA-Z_][a-zA-Z0-9_]*)')
    return pattern.sub(replace_var, expr)


def main():
    parser = argparse.ArgumentParser(description='Scrape Prometheus using Grafana dashboard queries and export master CSV + per-panel plots')
    parser.add_argument('--dashboard-json', required=True)
    parser.add_argument('--prom', required=True, help='Prometheus base URL, e.g. http://kube-prometheus-stack-prometheus.monitoring.svc:9090')
    parser.add_argument('--start', required=True, type=int, help='Start epoch seconds (k6 start - 60s)')
    parser.add_argument('--end', required=True, type=int, help='End epoch seconds (k6 end + 60s)')
    parser.add_argument('--ref-name', required=True, help='Reference name (TEST_NAME or descriptor)')
    parser.add_argument('--out-data-dir', required=True)
    parser.add_argument('--out-plots-dir', required=True)
    parser.add_argument('--step', type=int, default=15, help='Step seconds for range queries')
    args = parser.parse_args()

    os.makedirs(args.out_data_dir, exist_ok=True)
    os.makedirs(args.out_plots_dir, exist_ok=True)

    dashboard = load_dashboard(args.dashboard_json)
    panels = collect_panels(dashboard)
    var_map = build_variable_map(dashboard)

    start_utc = format_utc_compact(args.start)

    # Build master time index
    ts_master = build_master_index(args.start, args.end, args.step)

    # Collect all data into a single column map: "<Panel>__<Legend>" -> values
    master_cols: Dict[str, List[float]] = {}

    for panel in panels:
        title = panel['title']
        try:
            legend_to_values, _ = overlay_panel(args.prom, panel, args.start, args.end, args.step, ts_master, var_map)
        except Exception as e:
            # note error marker column (and include a minimal hint in logs)
            # We don't print here to keep script quiet for callers, but preserve a column to flag the failure
            master_cols[f"{sanitize_filename(title)}__ERROR"] = [float('nan')] * len(ts_master)
            continue
        # Save per-panel plot (from in-memory)
        if legend_to_values:
            plot_path = os.path.join(args.out_plots_dir, f"{sanitize_filename(title)}_{sanitize_filename(args.ref_name)}_{start_utc}.png")
            save_panel_plot(ts_master, legend_to_values, title, plot_path)
        # Add to master columns
        for legend, values in legend_to_values.items():
            col_name = f"{sanitize_filename(title)}__{sanitize_filename(legend)}"
            master_cols[col_name] = values

    # Save one master CSV
    master_csv = os.path.join(args.out_data_dir, f"grafana_master_{sanitize_filename(args.ref_name)}_{start_utc}.csv")
    save_master_csv(ts_master, master_cols, master_csv)


if __name__ == '__main__':
    main()
