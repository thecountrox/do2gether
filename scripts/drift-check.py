#!/usr/bin/env python3
"""Two-client drift check against a live room server.

Tokens are user-bound now, so the host client creates the room (`--create`, which binds the token to
its own id) and the guest token is minted through the bot API with `WT_BOT_TOKEN`.

Exits non-zero when p95 drift exceeds the video tolerance.
"""
from __future__ import annotations

import json
import os
import re
import select
import subprocess
import sys
import time
import urllib.request

SERVER = os.environ.get("SERVER", "https://watch.141.253.97.15.sslip.io")
BIN = os.environ.get("WT_PLAY", "/home/ubuntu/watch-together/rust/target/debug/wt-play")
TOLERANCE_MS = 250
ENV_FILE = "/home/ubuntu/watch-together/deploy/wt-server.env"


def bot_token() -> str:
    for line in open(ENV_FILE):
        if line.startswith("WT_BOT_TOKEN="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("no WT_BOT_TOKEN in deploy/wt-server.env")


def mint(room: str, user_id: str, name: str) -> str:
    req = urllib.request.Request(
        f"{SERVER}/rooms/{room}/tokens",
        data=json.dumps({"user_id": user_id, "user_name": name}).encode(),
        method="POST",
    )
    req.add_header("content-type", "application/json")
    req.add_header("authorization", "Bearer " + bot_token())
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())["join_token"]


class Client:
    def __init__(self, args: list[str]):
        self.proc = subprocess.Popen(
            [BIN, "--server", SERVER, *args, "--simulate"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        self.lines: list[str] = []

    def read_until(self, pattern: str, timeout: float = 20.0) -> str | None:
        deadline = time.time() + timeout
        rx = re.compile(pattern)
        while time.time() < deadline:
            r, _, _ = select.select([self.proc.stdout], [], [], 0.5)
            if not r:
                continue
            line = self.proc.stdout.readline()
            if not line:
                break
            self.lines.append(line.rstrip())
            m = rx.search(line)
            if m:
                return m.group(1)
        return None

    def send(self, line: str) -> None:
        if self.proc.stdin and self.proc.poll() is None:
            try:
                self.proc.stdin.write(line + "\n")
                self.proc.stdin.flush()
            except BrokenPipeError:
                pass

    def drain(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.proc.stdout], [], [], 0.3)
            if r:
                line = self.proc.stdout.readline()
                if not line:
                    break
                self.lines.append(line.rstrip())

    def stop(self) -> None:
        self.send("q")
        try:
            out, _ = self.proc.communicate(timeout=6)
            if out:
                self.lines.extend(out.splitlines())
        except subprocess.TimeoutExpired:
            self.proc.kill()
            out, _ = self.proc.communicate()
            if out:
                self.lines.extend(out.splitlines())


def drifts(lines: list[str]) -> list[int]:
    out = []
    for ln in lines:
        m = re.search(r"drift=([+-]?\d+)", ln)
        if m:
            out.append(abs(int(m.group(1))))
    return out


def main() -> int:
    host = Client(["--create", "--name", "ann"])
    token = host.read_until(r"^share: .*--token ([^ ]+)", timeout=25)
    room = host.read_until(r"^room: (\S+)", timeout=5) or ""
    if not token:
        print("host client never produced a token; output:")
        print("\n".join(host.lines[-12:]))
        host.stop()
        return 1
    if not room:
        for ln in host.lines:
            m = re.match(r"room: (\S+)", ln)
            if m:
                room = m.group(1)
                break
    print(f"room {room}")

    guest_token = mint(room, "bob", "Bob")
    guest = Client(["--room", room, "--token", guest_token, "--name", "bob"])

    time.sleep(2)
    host.send("play")
    host.drain(8)
    guest.drain(0.2)

    host.send("seek 30000")
    host.drain(6)
    guest.drain(0.2)

    guest.send("pause")
    guest.drain(3)
    guest.send("play")
    guest.drain(6)
    host.drain(0.5)

    host.stop()
    guest.stop()

    ok = True
    for name, c in (("ann", host), ("bob", guest)):
        d = drifts(c.lines)
        if not d:
            print(f"{name}: no samples")
            print("\n".join(c.lines[-6:]))
            ok = False
            continue
        d_sorted = sorted(d)
        p95 = d_sorted[max(0, int(len(d_sorted) * 0.95) - 1)]
        print(f"{name}: samples={len(d)} max={max(d)}ms p95={p95}ms")
        if p95 > TOLERANCE_MS:
            ok = False

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
