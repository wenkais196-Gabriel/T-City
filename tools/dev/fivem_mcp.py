#!/usr/bin/env python3
"""真机操作代理：通过 fivem-mcp-server 驱动运行中的 FiveM 客户端。

为什么不直接用 `fivem_console.py`：那个只做「控制台命令 + 单次按键」。玩法验证要的是一串动作
（截图 → 按键 → 点 NUI → 读客户端控制台 → 对照服务端数据），所以这里把 MCP 的几个工具包成
一条命令一个动作，便于在 shell 里按步骤执行、也便于把证据（截图/日志）落盘。

子命令::

    python3 tools/dev/fivem_mcp.py window                # 窗口是否在前台
    python3 tools/dev/fivem_mcp.py focus                 # 抢焦点（按键前必须）
    python3 tools/dev/fivem_mcp.py shot OUT.png          # 截图（maxSide 可选）
    python3 tools/dev/fivem_mcp.py key Down              # 按一次键（pressed+released）
    python3 tools/dev/fivem_mcp.py hold W 600            # 按住 W 600ms
    python3 tools/dev/fivem_mcp.py click 960 540         # 点 NUI
    python3 tools/dev/fivem_mcp.py scroll -3             # 滚轮（负=下）
    python3 tools/dev/fivem_mcp.py client "cmd"          # 客户端 F8 控制台命令
    python3 tools/dev/fivem_mcp.py console [--limit 40]  # 读客户端控制台最近若干行
    python3 tools/dev/fivem_mcp.py wait 2000             # 等
    python3 tools/dev/fivem_mcp.py bridge phone "phoneui" # 走 mcpb 桥（服务端/客户端内部）
    python3 tools/dev/fivem_mcp.py launch                # 启动客户端并连接默认端口
    python3 tools/dev/fivem_mcp.py quit                  # 优雅退出

环境变量：FIVEM_RCON_ADDRESS（默认 127.0.0.1:30130）、FIVEM_RCON_PASSWORD。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SERVER_CFG = REPO / "T-CityLite.base" / "server.cfg"

NPX_CANDIDATES = [
    os.path.expandvars(r"%APPDATA%\npm\npx.cmd"),
    os.path.expandvars(r"%APPDATA%\npm\npx"),
]


class McpSession:
    def __init__(self, command: list[str], env: dict[str, str], timeout: float = 60.0):
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", env=env, bufsize=1,
        )
        self.messages: list[dict] = []
        threading.Thread(target=self._reader, daemon=True).start()
        self.next_id = 1
        self.initialize(timeout)

    def _reader(self) -> None:
        for line in self.process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.messages.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    def _send(self, payload: dict) -> None:
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()

    def _wait(self, request_id: int, timeout: float) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            for index, message in enumerate(self.messages):
                if message.get("id") == request_id:
                    return self.messages.pop(index)
            time.sleep(0.03)
        raise TimeoutError(f"等 MCP 回复超时（id={request_id}，{timeout}s）")

    def initialize(self, timeout: float = 60.0) -> None:
        self._send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "tcity-playtest", "version": "0.1"}}})
        reply = self._wait(0, timeout)
        if "error" in reply:
            raise SystemExit(f"MCP initialize 失败：{reply['error']}")
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def call(self, tool: str, arguments: dict | None = None, timeout: float = 120.0) -> dict:
        request_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                    "params": {"name": tool, "arguments": arguments or {}}})
        reply = self._wait(request_id, timeout)
        if "error" in reply:
            raise SystemExit(f"工具 {tool} 失败：{reply['error']}")
        return reply.get("result") or {}

    def close(self) -> None:
        try:
            self.process.kill()
        except OSError:
            pass


def text_of(result: dict) -> str:
    parts = []
    for item in result.get("content") or []:
        if item.get("type") == "text":
            parts.append(item.get("text", ""))
        elif item.get("type") == "image":
            parts.append(f"[image {len(item.get('data', ''))} bytes base64]")
    return "\n".join(part for part in parts if part).strip()


def rcon_password() -> str:
    password = os.environ.get("FIVEM_RCON_PASSWORD", "").strip()
    if password:
        return password
    if not SERVER_CFG.exists():
        raise SystemExit("缺少 FIVEM_RCON_PASSWORD，且找不到 server.cfg")
    import re

    match = re.search(r'set\s+rcon_password\s+"([^"]+)"', SERVER_CFG.read_text(encoding="utf-8", errors="ignore"))
    if not match:
        raise SystemExit("server.cfg 里没有 rcon_password")
    return match.group(1)



def run_seq(session: McpSession, steps: str) -> int:
    """按 `;` 分隔执行动作序列，逐步打印，失败即停。"""
    for raw in steps.split(";"):
        step = raw.strip()
        if not step:
            continue
        verb, _, rest = step.partition(":")
        verb = verb.strip().lower()
        try:
            if verb == "focus":
                session.call("focus_window")
                print("focus")
            elif verb == "key":
                session.call("press_key", {"key": rest, "durationMs": 60})
                print(f"key {rest}")
            elif verb == "hold":
                key, _, ms = rest.partition(":")
                session.call("press_key", {"key": key, "durationMs": int(ms or 500)})
                print(f"hold {key} {ms}ms")
            elif verb == "moveclick":
                parts = rest.split(":")
                x, y = int(parts[0]), int(parts[1])
                session.call("focus_window")
                session.call("mouse_move", {"x": x, "y": y, "absolute": True})
                session.call("wait", {"ms": 120})
                session.call("click", {"button": "left", "double": False})
                print(f"moveclick {x},{y}")
            elif verb in {"move", "mouse"}:
                parts = rest.split(":")
                session.call("mouse_move", {"x": int(parts[0]), "y": int(parts[1]), "absolute": True})
                print(f"move {rest}")
            elif verb == "click":
                session.call("focus_window")
                session.call("click", {"button": "left", "double": False})
                print("click")
            elif verb == "scroll":
                session.call("scroll", {"amount": int(rest)})
                print(f"scroll {rest}")
            elif verb == "client":
                output = text_of(session.call("client_command", {"command": rest, "timeoutMs": 4000},
                                              timeout=40))
                print(f"client> {rest}\n{output}")
            elif verb == "wait":
                session.call("wait", {"ms": int(rest)})
                print(f"wait {rest}ms")
            elif verb == "shot":
                result = session.call("screenshot", {"maxSide": 1280})
                for item in result.get("content") or []:
                    if item.get("type") == "image":
                        payload = base64.b64decode(item.get("data", ""))
                        target = Path(rest)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(payload)
                        print(f"shot {target} ({len(payload)} bytes)")
            elif verb == "console":
                print(text_of(session.call("read_console",
                                           {"target": "client", "limit": int(rest or 30)})))
            elif verb == "log":
                print(text_of(session.call("read_client_log", {"limit": int(rest or 30)})))
            else:
                print(f"?? 未知动作 {verb}")
                return 1
        except SystemExit as error:
            print(f"!! 动作 {verb} 失败：{error}")
            return 1
        except Exception as error:  # noqa: BLE001 - 真机动作，任何异常都要能继续排查
            print(f"!! 动作 {verb} 异常：{type(error).__name__}: {error}")
            return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="驱动运行中的 FiveM 客户端（MCP）")
    sub = parser.add_subparsers(dest="action", required=True)

    seq = sub.add_parser("seq")
    seq.add_argument("steps", help="分号分隔：focus / key:Escape / hold:W:600 / moveclick:100:200 / "
                                  "click / move:x:y / scroll:-3 / client:cmd / wait:800 / shot:path.png / "
                                  "console:40 / log:40")

    sub.add_parser("window")
    sub.add_parser("focus")
    sub.add_parser("info")
    sub.add_parser("status")

    readlog = sub.add_parser("readlog")
    readlog.add_argument("--limit", type=int, default=60)
    readlog.add_argument("--contains", default="")
    sub.add_parser("launch")
    sub.add_parser("quit")

    shot = sub.add_parser("shot")
    shot.add_argument("out")
    shot.add_argument("--max-side", type=int, default=1280)

    key = sub.add_parser("key")
    key.add_argument("key")
    key.add_argument("--down-ms", type=int, default=60)

    hold = sub.add_parser("hold")
    hold.add_argument("key")
    hold.add_argument("ms", type=int)

    click = sub.add_parser("click")
    click.add_argument("x", type=int)
    click.add_argument("y", type=int)
    click.add_argument("--button", default="left")
    click.add_argument("--double", action="store_true")

    moveclick = sub.add_parser("moveclick")
    moveclick.add_argument("x", type=int)
    moveclick.add_argument("y", type=int)
    moveclick.add_argument("--pause-ms", type=int, default=120)

    move = sub.add_parser("move")
    move.add_argument("x", type=int)
    move.add_argument("y", type=int)

    scroll = sub.add_parser("scroll")
    scroll.add_argument("amount", type=int)

    client = sub.add_parser("client")
    client.add_argument("command")
    client.add_argument("--timeout-ms", type=int, default=4000)

    console = sub.add_parser("console")
    console.add_argument("--limit", type=int, default=40)
    console.add_argument("--contains", default="")

    wait = sub.add_parser("wait")
    wait.add_argument("ms", type=int)

    bridge = sub.add_parser("bridge")
    bridge.add_argument("target", choices=["server", "client"])
    bridge.add_argument("op")
    bridge.add_argument("--src", type=int, default=0)
    bridge.add_argument("--arg", action="append", default=[])

    args = parser.parse_args(argv)

    npx = next((candidate for candidate in NPX_CANDIDATES if candidate and os.path.exists(candidate)),
               shutil.which("npx"))
    if not npx:
        raise SystemExit("找不到 npx")

    env = {**os.environ,
           "FIVEM_RCON_ADDRESS": os.environ.get("FIVEM_RCON_ADDRESS", "127.0.0.1:30130"),
           "FIVEM_RCON_PASSWORD": rcon_password()}

    session = McpSession([npx, "-y", "fivem-mcp-server"], env)
    try:
        if args.action == "seq":
            return run_seq(session, args.steps)
        if args.action == "window":
            print(text_of(session.call("window_status")))
        elif args.action == "focus":
            session.call("focus_window")
            print("focused")
        elif args.action == "status":
            print(text_of(session.call("status")))
        elif args.action == "readlog":
            arguments = {"limit": args.limit}
            if args.contains:
                arguments["contains"] = args.contains
            print(text_of(session.call("read_client_log", arguments)))
        elif args.action == "info":
            print(text_of(session.call("server_info")))
        elif args.action == "launch":
            print(text_of(session.call("launch", {"connectTo": "127.0.0.1:30130"}, timeout=120)))
        elif args.action == "quit":
            print(text_of(session.call("quit_game", {"force": False}, timeout=120)))
        elif args.action == "shot":
            result = session.call("screenshot", {"maxSide": args.max_side})
            saved = False
            for item in result.get("content") or []:
                if item.get("type") == "image":
                    payload = base64.b64decode(item.get("data", ""))
                    target = Path(args.out)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(payload)
                    print(f"saved {target} ({len(payload)} bytes)")
                    saved = True
            if not saved:
                print("截图失败：" + text_of(result))
                return 1
        elif args.action == "key":
            session.call("press_key", {"key": args.key, "durationMs": args.down_ms})
            print(f"key {args.key}")
        elif args.action == "hold":
            session.call("press_key", {"key": args.key, "durationMs": args.ms})
            print(f"hold {args.key} {args.ms}ms")
        elif args.action == "click":
            session.call("click", {"button": args.button, "double": args.double})
            print(f"click {args.x},{args.y}")
        elif args.action == "moveclick":
            session.call("focus_window")
            session.call("mouse_move", {"x": args.x, "y": args.y, "absolute": True})
            session.call("wait", {"ms": args.pause_ms})
            session.call("click", {"button": "left", "double": False})
            print(f"moveclick {args.x},{args.y}")
        elif args.action == "move":
            session.call("mouse_move", {"x": args.x, "y": args.y, "absolute": True})
            print(f"move {args.x},{args.y}")
        elif args.action == "scroll":
            session.call("scroll", {"amount": args.amount})
            print(f"scroll {args.amount}")
        elif args.action == "client":
            print(text_of(session.call("client_command",
                                       {"command": args.command, "timeoutMs": args.timeout_ms},
                                       timeout=max(30, args.timeout_ms / 1000 + 20))))
        elif args.action == "console":
            arguments = {"target": "client", "limit": args.limit}
            if args.contains:
                arguments["contains"] = args.contains
            print(text_of(session.call("read_console", arguments)))
        elif args.action == "wait":
            session.call("wait", {"ms": args.ms})
            print(f"waited {args.ms}ms")
        elif args.action == "bridge":
            print(text_of(session.call("bridge", {
                "target": args.target, "op": args.op, "src": args.src, "args": args.arg,
            })))
        return 0
    finally:
        session.close()


if __name__ == "__main__":
    sys.exit(main())
