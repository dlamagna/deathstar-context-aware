#!/usr/bin/env bash
# Regenerate plots for all existing grafana run directories.
#
# For each hpa1/hpa2 run dir that has unified_report.csv:
#   - Re-runs 4by4plots.py (overview_4panel.png)
#
# For each *_comparison_* dir:
#   - Finds the matching hpa1 + hpa2 unified_report.csv pair
#   - Re-runs overlay_plots.py
#
# Usage:
#   ./k6/regenerate_plots.sh [GRAFANA_ROOT]
#   # default GRAFANA_ROOT = k6/grafana

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GRAFANA_ROOT="${1:-${REPO_ROOT}/k6/grafana}"

if [ ! -d "$GRAFANA_ROOT" ]; then
    echo "[ERROR] Grafana root not found: $GRAFANA_ROOT"
    exit 1
fi

total_4panel=0
total_overlay=0
errors=0

# Iterate over date directories
for date_dir in "$GRAFANA_ROOT"/????-??-??; do
    [ -d "$date_dir" ] || continue
    date_name="$(basename "$date_dir")"

    # --- 1. Regenerate 4-panel plots for hpa1/hpa2 runs ---
    for run_dir in "$date_dir"/*_hpa[12]_*; do
        [ -d "$run_dir" ] || continue
        unified="${run_dir}/unified_report.csv"
        [ -f "$unified" ] || continue

        plots_dir="${run_dir}/plots"
        mkdir -p "$plots_dir"
        label="$(basename "$run_dir")"

        echo "[INFO] 4-panel: ${date_name}/$(basename "$run_dir")"
        if python3 "${REPO_ROOT}/k6/4by4plots.py" \
            --unified-csv "$unified" \
            --out-dir "$plots_dir" \
            --label "$label" 2>/dev/null; then
            total_4panel=$((total_4panel + 1))
        else
            echo "[WARN]  4-panel failed for $label"
            errors=$((errors + 1))
        fi
    done

    # --- 2. Regenerate overlay plots for comparison dirs ---
    for comp_dir in "$date_dir"/*_comparison_*; do
        [ -d "$comp_dir" ] || continue
        comp_name="$(basename "$comp_dir")"

        # Derive the config prefix: everything before _comparison_HHMMSSZ
        # e.g. grid_search_vu10_cpu0.6_comparison_190141Z -> grid_search_vu10_cpu0.6
        config_prefix="${comp_name%_comparison_*}"

        # Find matching hpa1 and hpa2 dirs
        hpa1_csv=""
        hpa2_csv=""
        for candidate in "$date_dir"/${config_prefix}_hpa1_*/unified_report.csv; do
            [ -f "$candidate" ] && hpa1_csv="$candidate"
        done
        for candidate in "$date_dir"/${config_prefix}_hpa2_*/unified_report.csv; do
            [ -f "$candidate" ] && hpa2_csv="$candidate"
        done

        if [ -z "$hpa1_csv" ] || [ -z "$hpa2_csv" ]; then
            echo "[WARN] Skipping overlay for ${comp_name} (missing hpa1/hpa2 unified_report.csv)"
            continue
        fi

        echo "[INFO] Overlay: ${date_name}/${comp_name}"
        if python3 "${REPO_ROOT}/k6/overlay_plots.py" \
            --csv-a "$hpa1_csv" \
            --csv-b "$hpa2_csv" \
            --out-dir "$comp_dir" \
            --label-a "Context-Aware HPA" \
            --label-b "Default HPA" 2>/dev/null; then
            total_overlay=$((total_overlay + 1))
        else
            echo "[WARN]  Overlay failed for $comp_name"
            errors=$((errors + 1))
        fi
    done
done

echo ""
echo "=== Regeneration complete ==="
echo "  4-panel plots regenerated: $total_4panel"
echo "  Overlay plots regenerated: $total_overlay"
echo "  Errors: $errors"
