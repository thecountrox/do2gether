#!/usr/bin/env python3
"""A small durable queue in front of `cc-run.py`, so delegated work comes back on its own.

`cc-run.py` watches one Claude Code run. This watches many: it runs them one at a time (they share a
worktree, so parallel runs would fight over the same files), records every verdict, and can be polled
or resumed from any shell or any later session.

    python3 scripts/task-queue.py add --name q20 --task TASK20.md --prompt "Read TASK20.md and do it"
    python3 scripts/task-queue.py run                 # drains the queue; exits when empty
    python3 scripts/task-queue.py status              # one line per item
    python3 scripts/task-queue.py log --name q20      # that item's verdicts

State lives in `.tasks/queue.json`; each item's Claude run keeps its own `.cc/<name>/state.json`.

A `needs_input` verdict does not stop the queue by default — the next independent item still runs, and
the notification lists what is waiting on a human. Pass `--stop-on-input` to halt instead.

Run it as a notified background job (`terminal(background=True, notify=True)`): its exit message is the
signal to take the next step, and `status` is the check in between.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUEUE = ROOT / ".tasks" / "queue.json"
LOCK = ROOT / ".tasks" / "queue.lock"


def load() -> list[dict]:
    if not QUEUE.exists():
        return []
    try:
        return json.loads(QUEUE.read_text())
    except json.JSONDecodeError:
        return []


def save(items: list[dict]) -> None:
    QUEUE.parent.mkdir(parents=True, exist_ok=True)
    tmp = QUEUE.with_suffix(".tmp")
    tmp.write_text(json.dumps(items, indent=1))
    tmp.replace(QUEUE)


def now() -> int:
    return int(time.time())


def cmd_add(args) -> int:
    items = load()
    if any(i["name"] == args.name for i in items):
        print(f"already queued: {args.name}")
        return 1
    task = Path(args.task)
    prompt = args.prompt or (
        f"Read {task.name} and implement it exactly as specified. Run the tests and the analyzer "
        f"until green. Do not stop at a plan."
    )
    items.append({
        "name": args.name,
        "task": args.task,
        "prompt": prompt,
        "turns": args.turns,
        "batches": args.batches,
        "status": "pending",
        "added": now(),
        "started": None,
        "ended": None,
        "phase": None,
        "result": None,
    })
    save(items)
    print(f"queued {args.name} ({args.task})")
    return 0


def cmd_status(args) -> int:
    items = load()
    if not items:
        print("queue empty")
        return 0
    for i in items:
        age = ""
        if i["status"] == "running" and i["started"]:
            age = f" {int(time.time()) - i['started']}s"
        print(f"{i['name']:<8} {i['status']:<9}{age:<8} {i['task']:<12} {i.get('result') or ''}"[:160])
    return 0


def cmd_log(args) -> int:
    p = ROOT / ".cc" / args.name / "state.json"
    if not p.exists():
        print(f"no run recorded for {args.name}")
        return 1
    d = json.loads(p.read_text())
    print(json.dumps({k: d.get(k) for k in
                      ("phase", "batch", "turn", "last_tool", "result")}, indent=1))
    return 0


def run_item(item: dict) -> dict:
    cmd = [
        sys.executable, str(ROOT / "scripts" / "cc-run.py"),
        "--name", item["name"],
        "--prompt", item["prompt"],
        "--turns", str(item["turns"]),
        "--batches", str(item["batches"]),
    ]
    proc = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
    line = (proc.stdout or "").strip().splitlines()
    verdict = {}
    if line:
        try:
            verdict = json.loads(line[-1])
        except json.JSONDecodeError:
            verdict = {"phase": "failed", "result": (proc.stdout or "")[-300:]}
    else:
        verdict = {"phase": "failed", "result": (proc.stderr or "")[-300:]}
    return verdict


def cmd_run(args) -> int:
    QUEUE.parent.mkdir(parents=True, exist_ok=True)
    # One drainer at a time: two would run two Claude sessions into the same files.
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
    except FileExistsError:
        print("another drainer holds .tasks/queue.lock; refusing to start")
        return 1

    summary = []
    try:
        while True:
            items = load()
            pending = [i for i in items if i["status"] == "pending"]
            if not pending:
                break
            item = pending[0]
            item["status"] = "running"
            item["started"] = now()
            save(items)
            print(f"== {item['name']} start", flush=True)

            verdict = run_item(item)

            items = load()
            for i in items:
                if i["name"] == item["name"]:
                    i["status"] = verdict.get("phase", "failed")
                    i["phase"] = verdict.get("phase")
                    i["result"] = (verdict.get("result") or "")[:400]
                    i["ended"] = now()
            save(items)
            summary.append({"name": item["name"], **{k: verdict.get(k) for k in ("phase", "result")}})
            print(f"== {item['name']} {verdict.get('phase')}", flush=True)

            if verdict.get("phase") == "needs_input" and args.stop_on_input:
                break
    finally:
        LOCK.unlink(missing_ok=True)

    print(json.dumps({"queue": "empty" if not load() else "left items", "verdicts": summary})[:2000])
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add")
    a.add_argument("--name", required=True)
    a.add_argument("--task", required=True)
    a.add_argument("--prompt")
    a.add_argument("--turns", type=int, default=45)
    a.add_argument("--batches", type=int, default=3)

    sub.add_parser("status")

    l = sub.add_parser("log")
    l.add_argument("--name", required=True)

    r = sub.add_parser("run")
    r.add_argument("--stop-on-input", action="store_true")

    args = ap.parse_args()
    return {"add": cmd_add, "status": cmd_status, "log": cmd_log, "run": cmd_run}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
