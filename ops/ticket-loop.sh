#!/usr/bin/env bash
# GitHub ticket loop with a label-based workflow:
#
#   backlog      filed, NOT picked up by the loop
#   read         triaged — the loop picks these up
#   in progress  loop is working on it
#   review       completed & verified by the loop, awaiting human review
#   done         human reviewed and closed it
#
# The loop only ever picks tickets labeled "read". On pickup the label moves
# to "in progress". Once the agent verifies its work it moves to "review" and
# STAYS OPEN — the human moves it to done by closing. Ambiguous tickets get a
# clarification comment and stay "in progress" so they aren't re-dispatched.
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

gh() {
  local method="$1" path="$2" payload="${3:-}"
  if [ -n "$payload" ]; then
    curl -sf -X "$method" -H "Authorization: Bearer $GH_TOKEN" \
      "https://api.github.com/repos/$REPO$path" -d "$payload"
  else
    curl -sf -X "$method" -H "Authorization: Bearer $GH_TOKEN" \
      "https://api.github.com/repos/$REPO$path"
  fi
}

# swap_labels NUM TO — drop every other workflow label and set TO,
# preserving non-workflow labels (bug, enhancement, ...)
swap_labels() {
  local num="$1" to="$2" cur new
  cur="$(gh GET "/issues/$num" | python3 -c 'import json,sys; print(json.dumps([l["name"] for l in json.load(sys.stdin)["labels"]]))')" || return 0
  new="$(printf '%s' "$cur" | WORKFLOW_TARGET="$to" python3 -c '
import json, os, sys
workflow = {"backlog", "read", "in progress", "review", "done"}
labels = json.load(sys.stdin)
labels = [l for l in labels if l not in workflow]
to = os.environ["WORKFLOW_TARGET"]
if to not in labels:
    labels.append(to)
print(json.dumps(labels))')"
  gh PUT "/issues/$num/labels" "$new" >/dev/null
}

# Only tickets labeled "read" are picked up. backlog / in progress / review
# tickets (and anything else) are left alone.
issues="$(gh GET "/issues?state=open&per_page=30" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in data:
    if "pull_request" in i:  # skip PRs
        continue
    labels = [l["name"] for l in i["labels"]]
    print(i["number"], "\t", i["title"], "\t", " ".join(labels))
')"

while IFS=$'\t' read -r num title labels; do
  [ -z "${num:-}" ] && continue
  num="$(echo "$num" | xargs)"

  # Triage via the GitHub Project board: a human (non-bot) project status
  # change on a backlog ticket counts as triage -> flip the label to "read"
  # so the loop picks it up. Board drags don't touch labels, so without this
  # a ticket can sit in the Ready column forever.
  if [[ "$labels" == *"backlog"* ]]; then
    human_triage="$(gh GET "/issues/$num/events?per_page=20" | python3 -c '
import json, sys
try:
    events = json.load(sys.stdin)
except Exception:
    events = []
for e in events:
    if e["event"] == "project_v2_item_status_changed" and (e.get("actor") or {}).get("login") != "github-project-automation[bot]":
        print("yes"); break
')"
    if [ "$human_triage" = "yes" ]; then
      echo "$LOG_TAG issue #$num: human triaged via project board, backlog -> read"
      swap_labels "$num" "read"
      labels="read"
    fi
  fi

  # Only "read" tickets are dispatched; backlog / in progress / review stay.
  if [[ "$labels" != *"read"* ]]; then
    continue
  fi

  attempts_file="$STATE_DIR/issue-$num.attempts"
  attempts="$(cat "$attempts_file" 2>/dev/null || echo 0)"
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    echo "$LOG_TAG issue #$num: $MAX_ATTEMPTS attempts exhausted, leaving for a human"
    continue
  fi

  echo "$LOG_TAG dispatching pi for issue #$num: $title (attempt $((attempts+1)))"
  echo $((attempts + 1)) > "$attempts_file"

  # read -> in progress
  swap_labels "$num" "in progress"

  body="$(gh GET "/issues/$num" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body") or "")')"

  "$PI_BIN" -p --no-session --mode text -- \
    "You are autonomously completing a GitHub ticket in the repo $REPO (working copy: /root/Adsplosion).
ISSUE #$num: $title

BODY:
$body

Rules:
- Implement the request. Site pages under /var/www/vibe/ are deployed directly (not in the repo); changes to the Adsplosion app itself go in /root/Adsplosion — commit and push with the existing git SSH key.
- If the ticket is ambiguous or you cannot confidently implement it, do NOT guess: post a comment on issue #$num asking for clarification (use GH_TOKEN with the GitHub API) and stop. Leave the labels untouched in that case.
- Otherwise: make the change, verify it (curl the live site or run the app), post a comment on issue #$num summarizing what changed and how it was verified.
- DO NOT close the issue. When verification succeeds, replace the \"in progress\" label with \"review\" (PUT /issues/$num/labels with the full desired label list). A human reviews and closes it.
- Never add, change, or remove labels other than in progress <-> review.
- Only move to review after verification succeeds.
- Keep unrelated systems untouched. The GH_TOKEN env var is already set for API calls." \
    > "$STATE_DIR/issue-$num.log" 2>&1
  rc=$?
  echo "$LOG_TAG pi exited rc=$rc for #$num, log: $STATE_DIR/issue-$num.log"

  # Success = the agent moved the ticket to review
  labels="$(gh GET "/issues/$num" | python3 -c '
import json,sys
try: print(" ".join(l["name"] for l in json.load(sys.stdin)["labels"]))
except Exception: print("")' 2>/dev/null)"
  excerpt="$(tail -n 12 "$STATE_DIR/issue-$num.log" | head -c 2500)"
  if [[ "$labels" == *"review"* ]]; then
    rm -f "$attempts_file"
    echo "$LOG_TAG issue #$num moved to review successfully"
    notify "✅ Ticket #$num completed, moved to review: $title

$excerpt"
  else
    notify "⚠️ Ticket #$num ($title): pi exited rc=$rc, still in progress (attempt $attempts).

$excerpt"
  fi
done <<< "$issues"

echo "$LOG_TAG poll complete"

# pump logs to the live status page (best-effort, never breaks the loop)
python3 /root/logs-page.py >> /root/logs-page.err 2>&1 || true
