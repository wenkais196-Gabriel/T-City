#!/usr/bin/env python3
"""在真机上点一次「请求支援」—— 全流程不需要鼠标。

做法（每一步都读回状态确认，盲按必然失败）：
  1. 取 `/live/clients`，手机没开就先按 M；
  2. `adc <src> phoneui police_mdt` 直达 MDT 调度页；
  3. 逐次按 Down，直到 `phone.focus` 显示「请求支援」（最多 14 次）；
  4. 按 Enter 触发，然后回读 `police_backup_state` 与最近审计。

依赖同目录的 fivem_console.py（MCP→RCON）与 live token 环境变量。

用法：
    export FIVEM_RCON_PASSWORD=... TCITY_LIVE_TOKEN=...
    python3 tools/dev/police_request_backup.py            # 默认 127.0.0.1:30130
    python3 tools/dev/police_request_backup.py --dry-run  # 只走到焦点，不按 Enter
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_API = "http://127.0.0.1:30130/custom-director/agent/v1"


def api(path: str, token: str) -> dict:
    request = urllib.request.Request(f"{DEFAULT_API}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.loads(response.read().decode("utf-8"))


def phone_state(token: str) -> dict:
    clients = api("/live/clients", token).get("clients") or []
    if not clients:
        raise SystemExit("没有客户端在线：先让玩家进游戏")
    client = clients[0]
    return {"source": client.get("source"), "phone": (client.get("state") or {}).get("phone") or {}}


def console(*args: str) -> str:
    """发一条控制台命令。多个参数按空格拼成**一条**命令（fivem_console 只收一个位置参数）。"""
    command = " ".join(part for part in args if part)
    result = subprocess.run([sys.executable, str(HERE / "fivem_console.py"), command],
                            capture_output=True, text=True, timeout=180)
    return (result.stdout or result.stderr).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", default=os.environ.get("TCITY_LIVE_TOKEN", ""))
    parser.add_argument("--focus-label", default="请求支援")
    parser.add_argument("--max-steps", type=int, default=14)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if not args.token:
        raise SystemExit("缺少 TCITY_LIVE_TOKEN")

    # 这两个 convar 会在资源重启/重连后失效（真机反复踩过）：
    # 每次进来先垫一遍，否则 phoneui 静默被拒，焦点会在桌面图标间乱走。
    console("setr agent_devcmd_enabled 1")
    console("setr phone_ui_nav 1")
    time.sleep(1.0)

    state = phone_state(args.token)
    source = state["source"]
    phone = state["phone"]

    # 真机上会遇到"状态说手机开着，但 NUI 没挂载"（frames 空）：先关再开一次。
    if phone.get("open") and not phone.get("frames"):
        print("状态说开着但 frames 为空，先关再开")
        console("--key", "M")
        time.sleep(2.0)
        console("--key", "M")
        time.sleep(2.5)
        phone = phone_state(args.token)["phone"]

    if not phone.get("open"):
        console("--key", "M")
        time.sleep(2.5)
        state = phone_state(args.token)
        phone = state["phone"]
        if not phone.get("open"):
            raise SystemExit("手机没打开（M 无效？）")

    # 无条件重新定位到 MDT（phoneui 幂等）。convar 复制的滞后在真机上很常见，
    # 所以这里重试 3 次、每次重设一次 convar。
    for attempt in range(1, 4):
        console("setr phone_ui_nav 1")
        console("adc", f"{source} phoneui police_mdt")
        time.sleep(2.5)
        phone = phone_state(args.token)["phone"]
        if (phone.get("app") or {}).get("id") == "police_mdt":
            break
        if attempt == 3:
            raise SystemExit(
                "phoneui 没把手机切到 MDT（app=%r frames=%r）；先确认 phone_ui_nav=1"
                % ((phone.get("app") or {}).get("id"), phone.get("frames")))

    # 按键必须发给游戏窗口：Hermes/终端抢走前台时，Down 会打到别处（真机踩过）。
    if os.name == "nt":
        subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Add-Type -AssemblyName Microsoft.VisualBasic;"
             "[Microsoft.VisualBasic.Interaction]::AppActivate('FiveM') | Out-Null"],
            capture_output=True, timeout=30)

    reached = False
    focus = None
    for step in range(1, args.max_steps + 1):
        state = phone_state(args.token)
        focus = (state["phone"] or {}).get("focus")
        if focus == args.focus_label:
            reached = True
            print(f"焦点已到「{args.focus_label}」（{step - 1} 次 Down）")
            break
        console("--key", "Down")
        time.sleep(0.9)
        if args.verbose:
            print(f"  step {step}: focus={focus!r} -> 按了 Down")

    if not reached:
        raise SystemExit(f"{args.max_steps} 步内没走到「{args.focus_label}」，当前焦点：{focus}")

    if args.dry_run:
        print("dry-run：不按 Enter")
        return 0

    # Enter 也可能因为窗口失焦而丢：按一次 → 看状态 → 最多重试 3 次。
    for attempt in range(1, 4):
        focus_game_window()
        console("--key", "Enter")
        time.sleep(3)
        state = console("police_backup_state")
        if "no live units" not in state:
            print(state)
            return 0
        print(f"第 {attempt} 次 Enter 没触发请求，重试")
        time.sleep(2)
    print("三次 Enter 都没触发请求：检查焦点是否还在「请求支援」上")
    return 1


def focus_game_window() -> None:
    """点一下游戏窗口中心把它切到前台（SetForegroundWindow 常被系统拒绝）。"""
    if os.name != "nt":
        return
    subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;"
         "public class M{[DllImport(\"user32.dll\")]public static extern bool SetCursorPos(int x,int y);"
         "[DllImport(\"user32.dll\")]public static extern void mouse_event(uint f,uint dx,uint dy,uint d,"
         "System.UIntPtr e);}';"
         "[M]::SetCursorPos(1280,700)|Out-Null;"
         "[M]::mouse_event(0x0002,0,0,0,[System.UIntPtr]::Zero);"
         "Start-Sleep -Milliseconds 80;"
         "[M]::mouse_event(0x0004,0,0,0,[System.UIntPtr]::Zero)"],
        capture_output=True, timeout=30)


if __name__ == "__main__":
    raise SystemExit(main())
