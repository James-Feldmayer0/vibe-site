#!/usr/bin/env python3
"""Pump ticket-loop logs into a live status page at /var/www/vibe/logs/index.html.

Run at the end of every ticket-loop poll cycle. All secrets are redacted,
all log content is HTML-escaped.
"""
import datetime
import glob
import html
import os
import re
import subprocess

LOG = "/root/ticket-loop.log"
STATE = "/root/ticket-loop"
OUT = "/var/www/vibe/logs/index.html"

FAILURE_RE = re.compile(
    r"exited rc=(?!0\b)|exhausted|command not found|Traceback|FAILED|failed to|error"
)
REDACTIONS = [
    (re.compile(r"github_pat_[A-Za-z0-9_]{10,}"), "github_pat_REDACTED"),
    (re.compile(r"ghp_[A-Za-z0-9]{10,}"), "ghp_REDACTED"),
    (re.compile(r"gho_[A-Za-z0-9]{10,}"), "gho_REDACTED"),
    (re.compile(r"(Bearer\s+)[A-Za-z0-9_\.\-]{10,}"), r"\1REDACTED"),
]


def redact(s: str) -> str:
    for pat, repl in REDACTIONS:
        s = pat.sub(repl, s)
    return s


def esc(s: str) -> str:
    return html.escape(redact(s), quote=False)


def tail(path: str, n: int) -> list[str]:
    try:
        with open(path, errors="replace") as f:
            return f.readlines()[-n:]
    except OSError:
        return []


def service_active() -> tuple[bool, str]:
    try:
        out = subprocess.run(
            ["systemctl", "is-active", "ticket-loop"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        return out == "active", out
    except Exception:
        return False, "unknown"


# ---- gather ----
main_lines = tail(LOG, 80)
# Status reflects the CURRENT poll cycle only: split the log on "poll complete"
# boundaries. Historic failures stay highlighted in red in the log body, but
# only a failure in the latest cycle trips the banner.
last_complete = max(
    (i for i, l in enumerate(main_lines) if "poll complete" in l),
    default=None,
)
current_cycle = (
    main_lines[: last_complete + 1]
    if last_complete is not None
    else main_lines
)
prev_complete = max(
    (i for i, l in enumerate(current_cycle) if "poll complete" in l),
    default=None,
)
current_cycle = current_cycle[prev_complete + 1 :] if prev_complete is not None else current_cycle
failures = [l for l in current_cycle if FAILURE_RE.search(l)]
all_recent_failures = [l for l in main_lines if FAILURE_RE.search(l)]
exhausted = sorted(glob.glob(os.path.join(STATE, "issue-*.attempts")))
active, svc_state = service_active()
status_ok = active and not failures and not exhausted
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

# ---- build log block html ----
def log_block(title: str, lines: list[str], bar: str = "bash — 80×24") -> str:
    body = "".join(
        f'<span class="{ "r" if FAILURE_RE.search(l) else "w" }">{esc(l.rstrip())}</span>\n'
        for l in lines
    ) or '<span class="c">(empty)</span>\n'
    return f'<div class="term"><div class="term-bar">{bar} — {title}</div><pre>{body}</pre></div>'


main_html = log_block("/root/ticket-loop.log", main_lines)
journal = subprocess.run(
    ["journalctl", "-u", "ticket-loop.service", "-n", "40", "--no-pager", "-o", "short"],
    capture_output=True, text=True,
).stdout.splitlines()
journal_html = log_block("journalctl -u ticket-loop", journal) if journal else ""

agent_sections = ""
for p in sorted(glob.glob(os.path.join(STATE, "issue-*.log"))):
    name = os.path.basename(p)
    agent_sections += log_block(name, tail(p, 150))

exhausted_html = ""
if exhausted:
    items = "".join(f"<li><code>{esc(os.path.basename(p).replace('.attempts',''))}</code> — 2 attempts exhausted, waiting for a human</li>" for p in exhausted)
    exhausted_html = f'<div class="card warn"><h3>Shelved tickets</h3><ul>{items}</ul></div>'

banner = (
    '<div class="banner ok">✓ ALL SYSTEMS OPERATIONAL</div>'
    if status_ok
    else '<div class="banner fail">✕ FAILURES DETECTED — see highlighted lines below</div>'
)
if not active:
    banner = f'<div class="banner fail">✕ TICKET-LOOP SERVICE IS NOT RUNNING (state: {esc(svc_state)})</div>'
elif status_ok and all_recent_failures:
    banner += '<div class="banner note">ℹ recent failures exist in history (highlighted below) — latest cycle is clean</div>'

page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="refresh" content="30">
<title>System Logs | jamesfeldmayer.com</title>
<meta name="robots" content="noindex">
<style>
  :root {{
    --bg:#0a0e14; --fg:#d6e2f0; --dim:#6b7a8d; --accent:#5eead4;
    --accent2:#a78bfa; --card:#111823; --border:#1e293b; --red:#f87171;
  }}
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ background:var(--bg); color:var(--fg); min-height:100vh;
    font-family:"SF Mono","Cascadia Code","JetBrains Mono",Menlo,Consolas,monospace;
    line-height:1.6; padding:3rem 1.5rem 4rem;
    background-image:radial-gradient(600px 400px at 15% 10%,rgba(94,234,212,.06),transparent 60%),
    radial-gradient(700px 500px at 85% 90%,rgba(167,139,250,.06),transparent 60%); }}
  .wrap {{ max-width:900px; margin:0 auto; }}
  h1 {{ font-size:clamp(1.6rem,5vw,2.4rem); font-weight:600; margin-bottom:.4rem; }}
  .meta {{ color:var(--dim); font-size:.85rem; margin-bottom:1.5rem; }}
  .banner {{ padding:.9rem 1.2rem; border-radius:10px; font-size:1rem; font-weight:600;
    margin-bottom:1.5rem; border:1px solid; }}
  .banner.ok {{ color:var(--accent); border-color:var(--accent); background:rgba(94,234,212,.07); }}
  .banner.fail {{ color:var(--red); border-color:var(--red); background:rgba(248,113,113,.08);
    animation:pulse 2s infinite; }}
  .banner.note {{ color:var(--accent2); border-color:var(--accent2); background:rgba(167,139,250,.07);
    font-weight:400; font-size:.85rem; margin-top:-1rem; margin-bottom:1.5rem; }}
  @keyframes pulse {{ 50% {{ opacity:.75; }} }}
  section {{ margin-bottom:2rem; }}
  h2 {{ font-size:.95rem; font-weight:600; color:var(--accent); margin-bottom:.8rem;
    letter-spacing:.04em; text-transform:uppercase; }}
  h2::before {{ content:"// "; color:var(--dim); }}
  .term {{ background:#05080c; border:1px solid var(--border); border-radius:10px;
    font-size:.8rem; overflow:hidden; margin-bottom:1rem; }}
  .term-bar {{ background:#0d1420; padding:.45rem 1rem; color:var(--dim);
    font-size:.72rem; border-bottom:1px solid var(--border); }}
  pre {{ padding:1rem 1.2rem; overflow-x:auto; white-space:pre-wrap; word-break:break-all; }}
  .w {{ color:var(--fg); }} .r {{ color:var(--red); font-weight:600; }} .c {{ color:var(--dim); }}
  .card {{ background:var(--card); border:1px solid var(--border); border-radius:10px;
    padding:1.1rem 1.3rem; font-size:.88rem; }}
  .card.warn {{ border-color:var(--red); }}
  .card h3 {{ font-size:.9rem; margin-bottom:.4rem; }}
  ul {{ margin-left:1.2rem; color:var(--dim); }}
  code {{ color:var(--accent2); }}
  a {{ color:var(--accent); text-decoration:none; }}
  a:hover {{ text-decoration:underline; }}
  footer {{ margin-top:2.5rem; padding-top:1.2rem; border-top:1px solid var(--border);
    color:var(--dim); font-size:.82rem; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>System Logs</h1>
  <div class="meta">generated {esc(now)} · auto-refreshes every 30s · failures highlighted in red · secrets redacted</div>
  {banner}
  {exhausted_html}
  <section><h2>Latest poll events</h2>{main_html}</section>
  {f'<section><h2>Service journal</h2>{journal_html}</section>' if journal_html else ''}
  {f'<section><h2>Agent transcripts</h2>{agent_sections}</section>' if agent_sections else ''}
  <footer><a href="/">← back to the index</a> · part of the <a href="/tickets/">ticket loop</a></footer>
</div>
</body>
</html>
"""

os.makedirs(os.path.dirname(OUT), exist_ok=True)
tmp = OUT + ".tmp"
with open(tmp, "w") as f:
    f.write(page)
os.replace(tmp, OUT)
print(f"wrote {OUT} ({'OK' if status_ok else 'FAILING'})")