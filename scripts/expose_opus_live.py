#!/usr/bin/env python3
"""Add (or replace) the password-gated Caddy block for the Opus live viewer."""
import re
import secrets
import string
import subprocess
from pathlib import Path

CADDYFILE = Path("/home/ubuntu/.local/etc/caddy/Caddyfile")
MARK_BEGIN = "# >>> opus-live viewer (managed) >>>"
MARK_END = "# <<< opus-live viewer (managed) <<<"
HOST = "opus.141.253.97.15.sslip.io"
UPDATER = Path("/home/ubuntu/.local/share/caddy/..")

alphabet = string.ascii_letters + string.digits
password = "".join(secrets.choice(alphabet) for _ in range(16))

hashed = subprocess.run(
    ["caddy", "hash-password", "--plaintext", password],
    capture_output=True, text=True, check=True,
).stdout.strip()

block = f"""{MARK_BEGIN}
{HOST} {{
	encode zstd gzip
	basic_auth {{
		wt {hashed}
	}}
	reverse_proxy 127.0.0.1:8899 {{
		flush_interval -1
	}}
	log {{
		output file /home/ubuntu/.local/share/caddy/access.log
		format console
	}}
}}
{MARK_END}
"""

text = CADDYFILE.read_text()
text = re.sub(
    re.escape(MARK_BEGIN) + r".*?" + re.escape(MARK_END) + r"\n?",
    "",
    text,
    flags=re.DOTALL,
)
CADDYFILE.write_text(text.rstrip() + "\n\n" + block)

proc = subprocess.run(
    ["sudo", "-n", "systemctl", "restart", "pull-picker-proxy.service"],
    capture_output=True, text=True,
)
print("restart rc:", proc.returncode, proc.stderr.strip()[:200])
print("PASSWORD:", password)
