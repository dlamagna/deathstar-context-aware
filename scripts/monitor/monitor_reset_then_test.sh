#!/bin/bash
# monitor_reset_then_test.sh
# Called by cron every 5 minutes to monitor and restart reset_then_test.sh if needed.
# Usage: monitor_reset_then_test.sh <pid> <project_root>

PID="${1:-}"
PROJECT_ROOT="${2:-/home/dlamagna/projects/autoscaling-kubernetes}"
MONITOR_LOG="$PROJECT_ROOT/logs/monitor_reset_then_test.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$MONITOR_LOG"
}

mkdir -p "$PROJECT_ROOT/logs"
log "--- Monitor check ---"

# Step 1: Check if process is still running
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  log "PID $PID is still running. Nothing to do."
  exit 0
fi

log "PID $PID is not running. Checking logs..."

# Step 2: Find most recent log file
latest_log=$(ls -t "$PROJECT_ROOT"/logs/reset_then_test_*.log 2>/dev/null | head -1)
if [ -z "$latest_log" ]; then
  log "ERROR: No reset_then_test_*.log files found. Cannot restart."
  exit 1
fi
log "Most recent log: $latest_log"

# Step 3: Check if completed successfully
if grep -q 'Grand Summary' "$latest_log"; then
  log "SUCCESS: 'Grand Summary' found in $latest_log. All iterations completed."
  log "Removing this cron job from crontab."
  # Remove the cron entry for this monitor script
  crontab -l 2>/dev/null | grep -v "monitor_reset_then_test.sh" | crontab -
  log "Cron job removed. Monitoring complete."
  exit 0
fi

# Step 4: Not completed — find last completed iteration and restart
last_completed=$(grep -oP 'Completed iteration \K\d+' "$latest_log" | tail -1 || true)
log "Last completed iteration: ${last_completed:-none}"

log "Restarting reset_then_test.sh with --continue-from $latest_log ..."
cd "$PROJECT_ROOT" || exit 1
nohup "$PROJECT_ROOT/scripts/experiment/reset_then_test.sh" --loop 15 --average --continue-from "$latest_log" \
  > /tmp/reset_then_test_launcher.log 2>&1 &
NEW_PID=$!
log "Restarted with PID $NEW_PID"

# Update crontab to track the new PID
new_log=$(ls -t "$PROJECT_ROOT"/logs/reset_then_test_*.log 2>/dev/null | head -1)
log "New log file will be: ${new_log:-<not yet created>}"

# Replace old PID in crontab with new PID
crontab -l 2>/dev/null \
  | sed "s|monitor_reset_then_test.sh [0-9]* |monitor_reset_then_test.sh $NEW_PID |" \
  | crontab -
log "Crontab updated with new PID $NEW_PID"
