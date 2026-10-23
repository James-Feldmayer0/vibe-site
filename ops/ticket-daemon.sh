#!/usr/bin/env bash
# Persistent wrapper: runs the ticket poller every POLL_INTERVAL seconds.
# The poller itself is flock-guarded, so a slow pi run never overlaps.
set -u
POLL_INTERVAL="${POLL_INTERVAL:-30}"
LOG="/root/ticket-loop.log"

trim_log() {
  # keep the log under ~5MB
  if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 5000000 ]; then
    tail -n 5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

while true; do
  trim_log
  /root/ticket-loop.sh >> "$LOG" 2>&1
  sleep "$POLL_INTERVAL"
done