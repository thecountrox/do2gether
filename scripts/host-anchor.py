#!/usr/bin/env python3
"""Drive a room as its host over the websocket, so the desktop app can be checked against a real
anchor without someone clicking through the host UI.

Example: host a Jellyfin item in a fresh room, print the invite, and leave the room playing.
    python3 scripts/host-anchor.py --ref jellyfin:jelly.141.253.97.15.sslip.io/8b2ab2fa2506721d49db38751b5142c9
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import ssl
import sys
import time
import urllib.request

import websockets

DEFAULT_SERVER = os.environ.get("SERVER", "https://watch.141.253.97.15.sslip.io")


def create_room(server: str) -> dict:
    req = urllib.request.Request(f"{server}/rooms", data=b"{}", method="POST")
    req.add_header("content-type", "application/json")
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


async def run(server: str, item_ref: str, seconds: float) -> int:
    room = create_room(server)
    ws_base = server.replace("https://", "wss://").replace("http://", "ws://")
    url = f"{ws_base}/ws?room={room['room_id']}&token={room['join_token']}"
    ctx = ssl.create_default_context()
    async with websockets.connect(url, ssl=ctx, open_timeout=20) as ws:
        await ws.send(json.dumps({
            "v": 1,
            "t": "hello",
            "proto": 1,
            "client": {"id": room["host_id"], "name": "anchor", "ver": "0.1.0"},
        }))
        # wait for welcome so the server has us registered as host
        deadline = time.time() + 10
        while time.time() < deadline:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            if msg.get("t") == "welcome":
                break
        now_ms = int(time.time() * 1000)
        await ws.send(json.dumps({
            "v": 1,
            "t": "intent",
            "op": "play",
            "args": {
                "item_ref": item_ref,
                "position_ms": 0,
                "anchor_server_ms": now_ms,
                "rate": 1.0,
                "paused": False,
            },
        }))
        print(json.dumps({
            "room": room["room_id"],
            "token": room["join_token"],
            "ws": url,
            "ref": item_ref,
        }))
        await asyncio.sleep(seconds)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--seconds", type=float, default=90)
    args = ap.parse_args()
    return asyncio.run(run(args.server, args.ref, args.seconds))


if __name__ == "__main__":
    sys.exit(main())
