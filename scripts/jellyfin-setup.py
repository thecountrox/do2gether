#!/usr/bin/env python3
"""Bring a fresh Jellyfin up to a usable state through its API, with no browser.

Completes the startup wizard, creates an admin user, adds a Movies library, scans it, and prints the
credentials + the direct-play URL for the first item. Idempotent: re-running reuses the existing user
and library.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8096"
HEADERS = {
    "Content-Type": "application/json",
    "Authorization": (
        'MediaBrowser Client="do2gether-setup", Device="cli", '
        'DeviceId="do2gether-setup", Version="0.1.0"'
    ),
}
USER = "clawn"
PASSWORD = "jellyfin-dev-only"


def call(path: str, data=None, method="POST", token: str | None = None, timeout=30):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method)
    for k, v in HEADERS.items():
        req.add_header(k, v)
    if token:
        req.add_header("X-Emby-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        return {"_status": e.code, "_body": e.read().decode()[:300]}


def main() -> int:
    info = call("/System/Info/Public", method="GET")
    print("server:", info.get("ServerName"), info.get("Version"),
          "| wizard done:", info.get("StartupWizardCompleted"))

    if not info.get("StartupWizardCompleted"):
        call("/Startup/Configuration", {
            "UICulture": "en-US", "MetadataCountryCode": "US",
            "PreferredMetadataLanguage": "en",
        })
        call("/Startup/User", {"Name": USER, "Password": PASSWORD})
        print("wizard: user created")
        call("/Startup/RemoteAccess", {
            "EnableRemoteAccess": True, "EnableAutomaticPortMapping": False,
        })
        done = call("/Startup/Complete")
        print("wizard complete:", done)

    auth = call("/Users/AuthenticateByName", {"Username": USER, "Pw": PASSWORD})
    token = auth.get("AccessToken")
    user_id = auth.get("User", {}).get("Id")
    if not token:
        print("auth failed:", auth)
        return 1
    print("token ok, user", user_id)

    folders = call("/Library/VirtualFolders", method="GET")
    have_movies = any(f.get("Name") == "Movies" for f in folders if isinstance(folders, list))
    if not have_movies:
        call(f"/Library/VirtualFolders?name=Movies&collectionType=movies"
             f"&refreshLibrary=true&paths=/media", {})
        print("library added")
        time.sleep(3)
    # kick a scan and wait for the first item to appear
    for attempt in range(30):
        items = call("/Items?Recursive=true&IncludeItemTypes=Movie&Limit=5", method="GET", token=token)
        got = items.get("Items") or []
        if got:
            first = got[0]
            print("item:", first["Id"], first["Name"])
            print("direct:", f"{BASE}/Videos/{first['Id']}/stream?static=true&api_key={token}")
            print("PASSWORD", PASSWORD)
            return 0
        time.sleep(2)
    print("no items appeared; check /media scan")
    return 1


if __name__ == "__main__":
    sys.exit(main())
