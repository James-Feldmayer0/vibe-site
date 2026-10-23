#!/usr/bin/env bash
# GitHub ticket loop: poll open issues on Adsplosion and dispatch each to a
# headless pi run that implements, verifies, comments, and closes the ticket.
# Ambiguous tickets get a "needs human" comment instead of a blind guess.
set -u

REPO="James-Feldmayer0/Adsplosion"
STATE_DIR="/root/ticket-loop"
MAX_ATTEMPTS=2
LOG_TAG="[ticket-loop $(date '+%F %T')]"

mkdir -p "$STATE_DIR"
exec 9>"/root/ticket-loop.lock"
flock -n 9 || { echo "$LOG_TAG previous run still active, skipping"; exit 0; }

export GH_TOKEN="$(cat /root/.github-token)"
export PATH="/root/.local/share/pi-node/node-v22.23.3-linux-arm64/bin:/root/.pi/agent/bin:$PATH"
PI_BIN="$(command -v pi || echo /root/.pi/agent/bin/pi)"

# Telegram notifications (best-effort, never breaks the loop)
TG_TOKEN="$(python3 -c 'import json;print(json.load(open("/root/.pi/agent/tg.json"))["bots"][0]["token"])' 2>/dev/null || true)"
TG_CHAT="6910696042"
notify() {
  [ -n "$TG_TOKEN" ] || return 0
  curl -sf -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT" -d text="$1" >/dev/null \
    || echo "$LOG_TAG telegram notify failed"
}

issues="$(curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/issues?state=open&per_page=20" \
  | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in data:
    if "pull_request" in i:  # skip PRs
        continue
    print(i["number"], "\t", i["title"])
')"

while IFS=$'\t' read -r num title; do
  [ -z "${num:-}" ] && continue
  num="$(echo "$num" | xargs)"

  attempts_file="$STATE_DIR/issue-$num.attempts"
  attempts="$(cat "$attempts_file" 2>/dev/null || echo 0)"
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    echo "$LOG_TAG issue #$num: $MAX_ATTEMPTS attempts exhausted, leaving for a human"
    continue
  fi

  echo "$LOG_TAG dispatching pi for issue #$num: $title (attempt $((attempts+1)))"
  echo $((attempts + 1)) > "$attempts_file"

  body="$(curl -sf -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/issues/$num" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body") or "")')"

  "$PI_BIN" -p --no-session --mode text -- \
    "You are autonomously completing a GitHub ticket in the repo $REPO (working copy: /root/Adsplosion).
ISSUE #$num: $title

BODY:
$body

Rules:
- Implement the request. Site pages under /var/www/vibe/ are deployed directly (not in the repo); changes to the Adsplosion app itself go in /root/Adsplosion — commit and push with the existing git SSH key.
- If the ticket is ambiguous or you cannot confidently implement it, do NOT guess: post a comment on issue #$num asking for clarification (use GH_TOKEN with the GitHub API) and stop without closing.
- Otherwise: make the change, verify it (curl the live site or run the app), post a comment on issue #$num summarizing what changed and how it was verified, then close it (PATCH state=closed, state_reason=completed).
- Only close after verification succeeds.
- Keep unrelated systems untouched. The GH_TOKEN env var is already set for API calls." \
    > "$STATE_DIR/issue-$num.log" 2>&1
  rc=$?
  echo "$LOG_TAG pi exited rc=$rc for #$num, log: $STATE_DIR/issue-$num.log"

  # If the agent closed it, clear attempt tracking
  state="$(curl -sf -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/issues/$num" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null)"
  excerpt="$(tail -n 12 "$STATE_DIR/issue-$num.log" | head -c 2500)"
  if [ "$state" = "closed" ]; then
    rm -f "$attempts_file"
    echo "$LOG_TAG issue #$num closed successfully"
    notify "✅ Ticket #$num completed: $title

$excerpt"
  else
    notify "⚠️ Ticket #$num ($title): pi exited rc=$rc, issue still open (attempt $attempts).

$excerpt"
  fi
done <<< "$issues"

echo "$LOG_TAG poll complete"

# pump logs to the live status page (best-effort, never breaks the loop)
python3 /root/logs-page.py >> /root/logs-page.err 2>&1 || true