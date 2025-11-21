#!/usr/bin/env python3
import json

# Color mapping
COLOR_MAP = {
    "compose-post": "#2ca02c",  # green (original, less fluorescent)
    "compose-post-service": "#2ca02c",  # green (original, less fluorescent)
    "nginx-thrift": "#ffde21",  # fluorescent yellow
    "text-service": "#1f77b4",  # blue
    "user-mention-service": "#ff7f0e",  # orange (reverted to original)
    "text-service + compose-post": "#1f77b4",  # blue
    "user-mention + text-service": "#ff7f0e",  # orange (reverted to original)
    # HPA thresholds - match their services
    "HPA threshold (compose-post)": "#2ca02c",  # green (original, less fluorescent)
    "HPA threshold (nginx)": "#ffde21",  # fluorescent yellow
    "HPA threshold (text + compose)": "#1f77b4",  # blue
    "HPA threshold (mention + text)": "#ff7f0e",  # orange (reverted to original)
}

# Load dashboard
with open("deathstar-bench/monitoring/davide-dashboard.json", "r") as f:
    dashboard = json.load(f)

# Reorder panels: move "Replicas per Service" to position 1 (second panel)
replicas_panel = None
for i, panel in enumerate(dashboard["panels"]):
    if panel.get("title") == "Replicas per Service":
        replicas_panel = dashboard["panels"].pop(i)
        break

if replicas_panel:
    # Insert after first panel (CPU Consumption by Service)
    dashboard["panels"].insert(1, replicas_panel)
    print("Moved 'Replicas per Service' panel to position 2")

# Fix legend placement and add color overrides to each panel
for panel in dashboard["panels"]:
    # Move legend to bottom and set to list mode for horizontal display
    if "options" in panel and "legend" in panel["options"]:
        panel["options"]["legend"]["placement"] = "bottom"
        panel["options"]["legend"]["displayMode"] = "list"  # Horizontal layout
    
    if "fieldConfig" in panel and "overrides" in panel["fieldConfig"]:
        # Create color override for each service
        for label, color in COLOR_MAP.items():
            # Check if this label exists in targets
            has_label = False
            if "targets" in panel:
                for target in panel["targets"]:
                    if "legendFormat" in target and label in target["legendFormat"]:
                        has_label = True
                        break
            
            # Add override if label exists
            if has_label:
                override = {
                    "matcher": {
                        "id": "byName",
                        "options": label
                    },
                    "properties": [
                        {
                            "id": "color",
                            "value": {
                                "fixedColor": color,
                                "mode": "fixed"
                            }
                        }
                    ]
                }
                
                # Hide HPA thresholds from legend
                if "HPA threshold" in label:
                    override["properties"].append({
                        "id": "custom.hideFrom",
                        "value": {
                            "legend": True,
                            "tooltip": False,
                            "viz": False
                        }
                    })
                
                # Check if this override already exists
                exists = False
                for existing_override in panel["fieldConfig"]["overrides"]:
                    if existing_override.get("matcher", {}).get("options") == label:
                        # Update existing color
                        for prop in existing_override["properties"]:
                            if prop.get("id") == "color":
                                prop["value"]["fixedColor"] = color
                        
                        # Add hideFrom for HPA thresholds if not already present
                        if "HPA threshold" in label:
                            has_hide_from = any(p.get("id") == "custom.hideFrom" 
                                                for p in existing_override.get("properties", []))
                            if not has_hide_from:
                                existing_override["properties"].append({
                                    "id": "custom.hideFrom",
                                    "value": {
                                        "legend": True,
                                        "tooltip": False,
                                        "viz": False
                                    }
                                })
                        
                        exists = True
                        break
                
                if not exists:
                    panel["fieldConfig"]["overrides"].append(override)

# Save dashboard
with open("deathstar-bench/monitoring/davide-dashboard.json", "w") as f:
    json.dump(dashboard, f, indent=2)

print("Dashboard colors updated!")
