#!/usr/bin/env python3
"""fxserver_console.py — run a command on a running FXServer console and read its output.

Drives the server through its detachable `screen` session: type the line into the
console (screen `stuff` needs a literal CR to submit), then read the console page.
The echoed text is NOT a reliable confirmation: the console mixes concurrent stdout into the
input line, so `version` can echo as `vector2version` while executing correctly. Confirm by
effect (`Started resource X`, an expected print), never by the echo.
back with `hardcopy` and print only what appeared after the echoed command.

Usage:
  fxserver_console.py "status"                 # wait 3s, print new console output
  fxserver_console.py -w 8 "restart custom-phone"
  fxserver_console.py --page                   # dump the current console page
  fxserver_console.py --raw "say hi"           # keep ANSI colours
  fxserver_console.py --probe-rcon HOST PORT PASS   # is there a Source-RCON channel?

Env:
  FXSERVER_SCREEN     screen session name (default: fxserver)
  FXSERVER_ENV_FILE   optional KEY=VALUE file to load (setdefault semantics) — the
                      tool shell is a non-interactive bash that never reads
                      ~/.bashrc, so a helper script must load its own env.

Notes:
  - `hardcopy` copies the visible page only (80x24 by default), so long replies wrap
    and older lines scroll away; read straight after the action you care about.
  - Some server builds have no RCON at all: their TCP port answers HTTP
    (`/info.json` -> 200) and closes on a Source-RCON auth packet. Probe with
    --probe-rcon before building anything on that channel.
"""

import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SESSION = os.environ.get("FXSERVER_SCREEN", "fxserver")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def load_env_file() -> None:
    path = os.environ.get("FXSERVER_ENV_FILE")
    if not path:
        return
    file = Path(path).expanduser()
    if not file.is_file():
        return
    for raw in file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def screen(*args: str) -> int:
    proc = subprocess.run(["screen"] + list(args), capture_output=True, text=True)
    return proc.returncode


def session_alive() -> bool:
    proc = subprocess.run(["screen", "-ls"], capture_output=True, text=True)
    return any("\t" in line and SESSION in line for line in proc.stdout.splitlines())


def hardcopy() -> list[str]:
    path = tempfile.mktemp(prefix="fx_page_", suffix=".txt")
    screen("-S", SESSION, "-X", "hardcopy", path)
    time.sleep(0.3)
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return []
    finally:
        Path(path).unlink(missing_ok=True)
    return [line.rstrip("\r") for line in text.splitlines()]


def send(command: str) -> int:
    if not session_alive():
        print(f"no screen session {SESSION!r} — start the server detached under screen", file=sys.stderr)
        return 3
    # 先空发一个回车：控制台的输入行不清空（退格/Ctrl+U 都无效），残留会和下一条
    # 命令拼成 `randomitemsrestart qb-hud`；把残留当成一条命令丢掉再发真命令。
    screen("-S", SESSION, "-p", "0", "-X", "stuff", "\r")
    time.sleep(0.25)
    return screen("-S", SESSION, "-p", "0", "-X", "stuff", command.rstrip("\n") + "\r")


def after_echo(lines: list[str], command: str) -> list[str]:
    marker = command.strip()
    for index in range(len(lines) - 1, -1, -1):
        if lines[index].strip().startswith(marker):
            return lines[index + 1:]
    return lines


def probe_rcon(host: str, port: int, password: str) -> int:
    """Send one Source-RCON auth packet and report what the port does."""
    def packet(ident: int, kind: int, body: str) -> bytes:
        data = struct.pack("<ii", ident, kind) + body.encode() + b"\x00\x00"
        return struct.pack("<i", len(data)) + data

    try:
        sock = socket.create_connection((host, port), timeout=5)
    except OSError as exc:
        print(f"connect failed: {exc}")
        return 3
    with sock:
        sock.sendall(packet(1, 3, password))
        sock.settimeout(4)
        try:
            data = sock.recv(64)
        except OSError as exc:
            print(f"no reply ({type(exc).__name__}) — port is not an RCON speaker")
            return 4
    if not data:
        print("connection closed without a reply — this port does not speak Source RCON")
        return 4
    ident = struct.unpack("<i", data[4:8])[0] if len(data) >= 8 else None
    print(f"RCON channel answered (id={ident}); auth {'ok' if ident != -1 else 'rejected'}")
    return 0 if ident != -1 else 2


def main(argv: list[str]) -> int:
    load_env_file()
    args = argv[1:]
    wait_s = 3.0
    strip_ansi = "--raw" not in args
    args = [a for a in args if a != "--raw"]

    if args and args[0] == "--probe-rcon":
        host = args[1] if len(args) > 1 else "127.0.0.1"
        port = int(args[2]) if len(args) > 2 else 30120
        password = args[3] if len(args) > 3 else os.environ.get("FXSERVER_RCON_PASS", "")
        return probe_rcon(host, port, password)

    if args and args[0] == "--page":
        print("\n".join(ANSI.sub("", line) if strip_ansi else line for line in hardcopy()))
        return 0

    if args and args[0] in ("-w", "--wait"):
        wait_s = float(args[1])
        args = args[2:]

    if not args:
        print(__doc__, file=sys.stderr)
        return 1

    command = " ".join(args)
    if send(command) != 0:
        return 3
    time.sleep(wait_s)
    lines = after_echo(hardcopy(), command)
    text = "\n".join(ANSI.sub("", line) if strip_ansi else line for line in lines)
    out = "\n".join(line for line in text.splitlines() if line.strip())
    print(out if out else "(no output on the console page)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
