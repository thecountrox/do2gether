#!/usr/bin/env python3
"""Live viewer for the Claude Code (Opus) session working in ~/watch-together.

Server-rendered on purpose: the Hermes preview pane is a sandboxed cross-origin iframe, so a
subresource fetch() is blocked. The page embeds its own data and refreshes with <meta refresh>.

  /             dashboard (self-refreshing every 2s)
  /events.json  raw payload for curl / other tools
"""
from __future__ import annotations

import glob
import html
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = "/home/ubuntu/.claude/projects/-home-ubuntu-watch-together"
REPO = "/home/ubuntu/watch-together"
TMUX = "task15"
STATUS_FILE = os.path.join(REPO, "cc_task15.status")
RESULT_FILE = os.path.join(REPO, "cc_task15.json")
MAX_EVENTS = 140
PAGE_REFRESH_S = 2


def newest_transcript() -> str | None:
    files = glob.glob(os.path.join(PROJECT, "*.jsonl"))
    return max(files, key=os.path.getmtime) if files else None


def clip(s: str, n: int = 320) -> str:
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def local_hhmmss(stamp: str | None) -> str:
    """Transcript stamps are UTC; show them in the box's local timezone."""
    if not stamp:
        return ""
    try:
        dt = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return stamp[11:19]
    return dt.astimezone().strftime("%H:%M:%S")


def tool_detail(name: str, inp: dict) -> str:
    if name == "Bash":
        return clip(inp.get("command", ""), 220)
    if name in ("Read", "NotebookRead", "Write", "Edit", "MultiEdit"):
        return clip(inp.get("file_path", ""), 170)
    if name == "Grep":
        return clip(f"{inp.get('pattern', '')}  {inp.get('path', '')}", 170)
    if name == "Glob":
        return clip(inp.get("pattern", ""), 170)
    if name == "TodoWrite":
        todos = inp.get("todos") or []
        done = sum(1 for t in todos if t.get("status") == "completed")
        cur = next((t.get("content", "") for t in todos if t.get("status") == "in_progress"), "")
        return clip(f"{done}/{len(todos)} done · {cur}", 170)
    return clip(json.dumps(inp)[:220], 220)


def parse_events(path: str) -> list[dict]:
    events: list[dict] = []
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            msg = rec.get("message") or {}
            role = msg.get("role")
            ts = local_hhmmss(rec.get("timestamp"))
            content = msg.get("content")
            if isinstance(content, str) and content.strip():
                events.append({"ts": ts, "kind": "text", "role": role, "body": clip(content, 600)})
            for b in content if isinstance(content, list) else []:
                kind = b.get("type")
                if kind == "text" and b.get("text", "").strip():
                    events.append({"ts": ts, "kind": "text", "role": role,
                                   "body": clip(b["text"], 700)})
                elif kind == "tool_use":
                    name = b.get("name", "?")
                    events.append({"ts": ts, "kind": "tool", "name": name,
                                   "body": tool_detail(name, b.get("input") or {})})
                elif kind == "tool_result":
                    raw = b.get("content")
                    if isinstance(raw, list):
                        raw = " ".join(c.get("text", "") for c in raw if isinstance(c, dict))
                    events.append({"ts": ts, "kind": "result",
                                   "error": bool(b.get("is_error")), "body": clip(raw or "", 420)})
    return events[-MAX_EVENTS:]


def session_state() -> dict:
    alive = subprocess.run(["tmux", "has-session", "-t", TMUX],
                           capture_output=True).returncode == 0
    status = None
    if not alive and os.path.exists(STATUS_FILE):
        try:
            status = open(STATUS_FILE).read().strip()
        except Exception:
            status = "?"
    result = None
    if status and os.path.exists(RESULT_FILE) and os.path.getsize(RESULT_FILE) > 0:
        try:
            d = json.load(open(RESULT_FILE))
            result = {
                "subtype": d.get("subtype"),
                "turns": d.get("num_turns"),
                "cost": round(d.get("total_cost_usd") or 0, 3),
                "result": clip(d.get("result") or "", 3000),
                "models": list((d.get("modelUsage") or {}).keys()),
            }
        except Exception:
            result = None
    return {"alive": alive, "status": status, "result": result}


def render(state: dict, events: list[dict]) -> str:
    running = bool(state["alive"])
    state_label = "running" if running else (state["status"] or "idle")
    tools = sum(1 for e in events if e["kind"] == "tool")

    rows = []
    for e in events:
        if e["kind"] == "text":
            rows.append(
                '<div class="ev"><div class="ic">✎</div><div class="bd">'
                f'<div class="who">{html.escape(e.get("role") or "")}</div>'
                f'<div class="txt">{html.escape(e["body"])}</div></div></div>'
            )
        elif e["kind"] == "tool":
            rows.append(
                '<div class="ev"><div class="ic">▸</div><div class="bd">'
                f'<div class="who">{html.escape(e.get("ts") or "")}</div>'
                f'<div class="tl">{html.escape(e.get("name", ""))}</div>'
                f'<code class="cmd">{html.escape(e["body"])}</code></div></div>'
            )
        else:
            cls = "res err" if e.get("error") else "res"
            rows.append(
                f'<div class="ev"><div class="ic">·</div><div class="bd">'
                f'<div class="{cls}">{html.escape(e["body"])}</div></div></div>'
            )

    body = "".join(rows) or '<div class="empty">waiting for the first transcript lines…</div>'
    foot = ""
    r = state["result"]
    if r:
        foot = (f'final: {html.escape(str(r["subtype"]))} · {r["turns"]} turns · '
                f'${r["cost"]} · {html.escape(",".join(r["models"]))}')
        if r["result"]:
            foot += f'<div class="res">{html.escape(r["result"])}</div>'

    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="{PAGE_REFRESH_S}">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Opus live</title>
<style>
:root{{--bg:#0C0613;--plum:#1A0E27;--line:rgba(255,232,248,.16);--tx:#FFF4FB;--dim:#B7A2C8;
--violet:#C08CFF;--cyan:#62EAF4;--yel:#FFD45E;--err:#FF7A7A}}
*{{box-sizing:border-box;margin:0}}
body{{background:radial-gradient(600px 300px at 90% -10%,rgba(255,95,174,.14),transparent 60%),var(--bg);
color:var(--tx);font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-size:13px;padding:14px}}
.hdr{{display:flex;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap}}
.dot{{width:9px;height:9px;border-radius:50%;background:var(--yel);box-shadow:0 0 10px var(--yel)}}
.dot.run{{background:var(--cyan);box-shadow:0 0 12px var(--cyan)}}
h1{{font-size:15px;font-weight:800}}
.pill{{border:1.5px solid var(--line);border-radius:999px;padding:3px 10px;font-size:11px;font-weight:700;color:#EBDDF2}}
.meta{{color:var(--dim);font-size:11px}}
.feed{{border:1.5px solid var(--line);border-radius:16px;background:var(--plum);height:440px;overflow:auto;padding:10px}}
.ev{{display:flex;gap:9px;padding:6px}}
.ev+.ev{{border-top:1px solid rgba(255,232,248,.06)}}
.ic{{flex:0 0 16px;text-align:center;font-size:12px;opacity:.85}}
.bd{{flex:1;min-width:0}}
.who{{font-size:10.5px;letter-spacing:.09em;text-transform:uppercase;color:var(--dim);font-weight:700}}
.txt{{line-height:1.45;margin-top:2px;word-break:break-word}}
.tl{{color:var(--violet);font-weight:800;margin-top:1px}}
.cmd{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;color:#E9DCF6;
background:#ffffff0d;border:1px solid var(--line);border-radius:8px;padding:4px 7px;margin-top:3px;
display:block;white-space:pre-wrap;word-break:break-all}}
.res{{color:var(--dim);font-family:ui-monospace,Menlo,monospace;font-size:11px;white-space:pre-wrap;word-break:break-word}}
.res.err{{color:var(--err)}}
.empty{{color:var(--dim);text-align:center;padding:40px 10px}}
.foot{{margin-top:8px;color:var(--dim);font-size:11px}}
</style></head><body>
<div class="hdr">
  <span class="dot{' run' if running else ''}"></span>
  <h1>Opus 5.5 · watch-together UI</h1>
  <span class="pill">{html.escape(state_label)}</span>
  <span class="pill">{tools} tools · {len(events)} events</span>
  <span class="meta">{time.strftime('%H:%M:%S')} · refreshes every {PAGE_REFRESH_S}s</span>
</div>
<div class="feed" id="feed">{body}</div>
<div class="foot">{foot}</div>
<script>
var f=document.getElementById('feed'),k='opuslive-scroll';
var y=sessionStorage.getItem(k);
f.scrollTop = y===null ? f.scrollHeight : parseInt(y,10);
f.addEventListener('scroll',function(){{sessionStorage.setItem(k,String(f.scrollTop));}});
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 - base class signature
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        tr = newest_transcript()
        events = parse_events(tr) if tr else []
        state = session_state()
        if path in ("/", "/index.html"):
            self._send(200, render(state, events).encode(), "text/html; charset=utf-8")
            return
        if path == "/events.json":
            payload = {"events": events, "transcript": os.path.basename(tr) if tr else None,
                       "now": int(time.time() * 1000), **state}
            self._send(200, json.dumps(payload).encode(), "application/json")
            return
        self._send(404, b'{"error":"not found"}', "application/json")


if __name__ == "__main__":
    print("opus live viewer on http://127.0.0.1:8899", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8899), Handler).serve_forever()
