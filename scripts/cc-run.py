#!/usr/bin/env python3
"""Run a Claude Code task with a watch: live state file, auto-continue on turn caps, and a single
machine-readable summary at the end.

Why this exists: `claude -p` stops dead when it hits `--max-turns`, often mid-edit, and nothing tells
the caller. This wrapper keeps a `state.json` an agent can poll, resumes automatically when the turn
budget runs out, and distinguishes "done" from "stuck on a question" from "crashed".

    python3 scripts/cc-run.py --name t19 --prompt "Read TASK.md and do it" --batches 4

State file (default `<cwd>/.cc/<name>/state.json`):
    {"phase": "running|done|needs_input|failed", "batch": 1, "turn": 7,
     "last_tool": "Bash", "last_text": "…", "cost_usd": 1.23, "session_id": "…",
     "updated": 1794730000, "result": "…"}

Exit code: 0 done, 2 needs_input, 1 failed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

DONE = "done"
NEEDS_INPUT = "needs_input"
FAILED = "failed"
RUNNING = "running"

# The model asks the caller something instead of finishing. We cannot answer for the human, so stop
# and say so rather than burning turns.
QUESTION_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"requires? (?:your )?(?:approval|permission)",
        r"permission denied",
        r"not allowed to (?:write|edit|run)",
        r"shall i \b",
        r"should i \b.*\?",
        r"would you like me to\b",
        r"which (?:one|approach|option) (?:do you|would you)",
        r"cannot continue without\b",
        r"needs? your input",
        r"blocked on\b",
    )
]


def relay_env() -> dict[str, str]:
    """The Anthropic-compatible proxy lives on gigapc; its key never lands in a file."""
    key = os.environ.get("CC_KEY")
    if not key:
        try:
            out = subprocess.run(
                [
                    "ssh", "-o", "BatchMode=yes", "-i",
                    os.path.expanduser("~/.ssh/clawn_gigapc"),
                    "thecount@100.85.230.19",
                    'sed -n "/^access:/,/^management:/p" ~/.cli-proxy-api/config.yaml '
                    '| grep -oE "sk-[A-Za-z0-9_-]+" | head -1',
                ],
                capture_output=True, text=True, timeout=25, check=False,
            )
            key = out.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            key = ""
    env = dict(os.environ)
    if key:
        env["ANTHROPIC_API_KEY"] = key
        env.setdefault("ANTHROPIC_BASE_URL", "http://100.85.230.19:8317")
        env.setdefault("ANTHROPIC_SMALL_FAST_MODEL", "claude-haiku-5-5")
    return env


def write_state(path: Path, state: dict) -> None:
    state["updated"] = int(time.time())
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1))
    tmp.replace(path)


def looks_like_question(text: str) -> bool:
    return any(p.search(text) for p in QUESTION_PATTERNS)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--turns", type=int, default=80, help="per batch")
    ap.add_argument("--batches", type=int, default=3, help="auto-continue at most this many times")
    ap.add_argument("--tools", default="Read,Write,Edit,Bash")
    ap.add_argument("--cwd", default=".")
    ap.add_argument("--state-dir", default=".cc")
    ap.add_argument("--continue-session", action="store_true",
                    help="resume the newest session in this directory instead of starting fresh")
    args = ap.parse_args()

    cwd = Path(args.cwd).resolve()
    state_dir = (cwd / args.state_dir / args.name)
    state_dir.mkdir(parents=True, exist_ok=True)
    state_path = state_dir / "state.json"
    log_path = state_dir / "transcript.jsonl"

    state = {
        "phase": RUNNING, "batch": 0, "turn": 0, "last_tool": None, "last_text": "",
        "cost_usd": 0.0, "session_id": None, "result": "", "name": args.name,
    }
    write_state(state_path, state)

    env = relay_env()
    if "ANTHROPIC_API_KEY" not in env:
        state.update(phase=FAILED, result="no proxy key (ssh to gigapc failed and CC_KEY unset)")
        write_state(state_path, state)
        print(json.dumps({"phase": FAILED, "result": state["result"]}))
        return 1

    prompt = args.prompt
    resumed = args.continue_session
    for batch in range(1, args.batches + 1):
        state.update(batch=batch, phase=RUNNING)
        write_state(state_path, state)

        cmd = [
            "claude", "-p", prompt,
            "--model", args.model,
            "--max-turns", str(args.turns),
            "--allowedTools", args.tools,
            "--output-format", "stream-json",
            "--verbose",
        ]
        if resumed:
            cmd.insert(1, "--continue")

        with log_path.open("a") as log:
            proc = subprocess.Popen(
                cmd, cwd=str(cwd), env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                log.write(line)
                log.flush()
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = event.get("type")
                if kind == "system" and event.get("subtype") == "init":
                    state["session_id"] = event.get("session_id")
                elif kind == "assistant":
                    for block in (event.get("message") or {}).get("content") or []:
                        if block.get("type") == "text" and block.get("text"):
                            state["last_text"] = block["text"][-400:]
                        elif block.get("type") == "tool_use":
                            state["last_tool"] = block.get("name")
                            state["turn"] = state.get("turn", 0) + 1
                elif kind == "result":
                    state["cost_usd"] = round(
                        (state.get("cost_usd") or 0) + (event.get("total_cost_usd") or 0), 4
                    )
                    state["subtype"] = event.get("subtype")
                    state["result"] = (event.get("result") or "")[:2000]
                write_state(state_path, state)

            stderr = proc.stderr.read() if proc.stderr else ""
            code = proc.wait()

        if code == 0 and state.get("subtype") not in ("error_max_turns",):
            state["phase"] = DONE
            write_state(state_path, state)
            print(json.dumps({
                "phase": DONE, "batch": batch, "turns": state["turn"],
                "cost_usd": state["cost_usd"], "state": str(state_path),
                "result": state["result"][:400],
            }))
            return 0

        if state.get("subtype") == "error_max_turns":
            # Out of turns, not out of work: continue the same session with a nudge.
            resumed = True
            prompt = (
                "Continue the task. Do not restart or re-plan what is already done: run the tests and "
                "the analyzer, fix what is still broken, and finish the remaining sections."
            )
            continue

        if looks_like_question(state.get("last_text", "") + "\n" + stderr):
            state.update(phase=NEEDS_INPUT, result=state.get("result") or stderr[-800:])
            write_state(state_path, state)
            print(json.dumps({"phase": NEEDS_INPUT, "state": str(state_path),
                              "question": state["last_text"][-400:]}))
            return 2

        state.update(phase=FAILED, result=(state.get("result") or stderr[-800:] or f"exit {code}"))
        write_state(state_path, state)
        print(json.dumps({"phase": FAILED, "state": str(state_path), "result": state["result"][:400]}))
        return 1

    state.update(phase=FAILED, result=f"still hitting the turn cap after {args.batches} batches")
    write_state(state_path, state)
    print(json.dumps({"phase": FAILED, "state": str(state_path), "result": state["result"]}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
