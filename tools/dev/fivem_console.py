#!/usr/bin/env python3
"""在真机上发控制台命令与按键 —— 通过 fivem-mcp-server 的 MCP stdio 接口。

为什么不用直连 RCON / 模拟键盘：
  * 本机 FXServer 的 RCON 在收到认证包后直接关连接（原始 socket 探到 0 字节 + FIN）；
  * Windows 控制台不吃管道输入（每条命令只回显 `+vstr` 这类碎片）；
  * PowerShell `keybd_event` / 桌面驱动的 foreground SendInput 到不了游戏进程，
    只有 MCP 的 `press_key` 能让 `phone.nav_edges` 真的出现边沿。
所以这里开一个 MCP 会话，走 fivem-mcp-server 内部那条通道。

用法：
    # 控制台命令
    python3 tools/dev/fivem_console.py "status"
    python3 tools/dev/fivem_console.py "restart custom-police" --wait 10

    # 确定性驱动 UI（配合 setr phone_ui_nav 1 + adc <src> phoneui <app>）
    python3 tools/dev/fivem_console.py --key Down
    python3 tools/dev/fivem_console.py --key Enter

环境变量：
    FIVEM_RCON_ADDRESS   默认 127.0.0.1:30130
    FIVEM_RCON_PASSWORD  必填（Rcon 密码在 server.cfg 里，不入库）
    FIVEM_NPX            npx 可执行文件路径；默认自动探测

退出码：0 成功、2 initialize 失败、3 工具调用失败、4 环境缺失。
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time

DEFAULT_NPX_CANDIDATES = [
    os.environ.get("FIVEM_NPX", ""),
    r"C:/Program Files/nodejs/npx.cmd",
    r"C:/Program Files (x86)/nodejs/npx.cmd",
]


class McpSession:
    """最小 MCP stdio 会话：initialize → initialized → tools/call。"""

    def __init__(self, argv: list[str], env: dict[str, str]) -> None:
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1, env=env,
        )
        self._lines: queue.Queue[str] = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self._next_id = 0

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self._lines.put(line)
        self._lines.put("")

    def _send(self, payload: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def request(self, method: str, params: dict, timeout: float) -> dict:
        self._next_id += 1
        rid = self._next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = self._lines.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if not line:
                break
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("id") == rid:
                return message
        raise TimeoutError(f"no response to {method}")

    def notify(self, method: str, params: dict) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        self.proc.terminate()


def find_npx() -> str:
    for candidate in DEFAULT_NPX_CANDIDATES:
        if candidate and os.path.exists(candidate):
            return candidate
    found = shutil.which("npx")
    if found:
        return found
    raise SystemExit("找不到 npx：设置 FIVEM_NPX 指向 npx.cmd")


def call_tool(tool: str, arguments: dict, timeout: float) -> str:
    address = os.environ.get("FIVEM_RCON_ADDRESS", "127.0.0.1:30130")
    password = os.environ.get("FIVEM_RCON_PASSWORD", "")
    if not password:
        raise SystemExit("缺少 FIVEM_RCON_PASSWORD（见 server.cfg 的 rcon_password）")

    env = dict(os.environ)
    env.update({"FIVEM_RCON_ADDRESS": address, "FIVEM_RCON_PASSWORD": password})
    session = McpSession([find_npx(), "-y", "fivem-mcp-server"], env)
    try:
        init = session.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "tcity-console", "version": "0.1"},
        }, timeout=60)
        if "error" in init:
            raise SystemExit(f"initialize 失败：{init['error']}")
        session.notify("notifications/initialized", {})
        reply = session.request("tools/call", {"name": tool, "arguments": arguments}, timeout=timeout)
        if "error" in reply:
            raise SystemExit(f"工具调用失败：{reply['error']}")
        parts = [item.get("text", "") for item in (reply.get("result") or {}).get("content") or []
                 if item.get("type") == "text"]
        return "\n".join(parts).strip()
    finally:
        session.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="真机控制台/按键（经 MCP → RCON）")
    parser.add_argument("command", nargs="?", default="", help="控制台命令，如 status / restart custom-police")
    parser.add_argument("--key", default="", help="按键，如 Down / Enter / M")
    parser.add_argument("--hold-ms", type=int, default=80, help="按键保持毫秒（默认 80）")
    parser.add_argument("--wait", type=float, default=0.0, help="命令发出后再等几秒收输出")
    parser.add_argument("--timeout", type=float, default=60.0, help="单次工具调用超时")
    args = parser.parse_args()

    if not args.command and not args.key:
        parser.error("要么给命令，要么给 --key")

    if args.key:
        output = call_tool("press_key", {"key": args.key, "holdMs": args.hold_ms}, args.timeout)
    else:
        output = call_tool("server_command", {"command": args.command}, args.timeout)

    if output:
        print(output)
    if args.wait:
        time.sleep(args.wait)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
