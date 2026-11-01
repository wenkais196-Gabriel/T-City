#!/usr/bin/env python3
"""把 FiveM 游戏窗口切到前台（真机按键前的必要一步）。

为什么需要它：
  `fivem_console.py --key` 走的是 MCP 的 `press_key`，它要求游戏窗口在前台，
  否则直接报 "could not bring the game window to the foreground (Alt-Tab lock?)"。
  而系统会拒绝普通进程的 `SetForegroundWindow`（前台锁定），
  必须用 `AttachThreadInput` 把当前线程挂到目标窗口线程上才切得过来。

用法：
    python3 tools/dev/fivem_focus.py            # 切窗口 + 点一下中心
    python3 tools/dev/fivem_focus.py --no-click # 只切窗口
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

SW_RESTORE = 9


def find_fivem_window() -> int | None:
    """按标题找 FiveM 的 GTA 进程窗口。"""
    found: list[tuple[int, str]] = []
    EnumProc = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)

    def _cb(hwnd, _lparam):
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            title = buf.value
            if title and ("FiveM" in title or "GTA" in title):
                found.append((hwnd, title))
        return True

    user32.EnumWindows(EnumProc(_cb), 0)
    if not found:
        return None
    # 取标题最长的那个（真正的游戏窗口标题带服务器名）
    found.sort(key=lambda item: len(item[1]), reverse=True)
    return found[0][0]


def focus(hwnd: int) -> bool:
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
        time.sleep(0.3)

    fg = user32.GetForegroundWindow()
    if fg == hwnd:
        return True

    # 前台锁定：把本线程挂到当前前台窗口线程上再 SetForegroundWindow
    target_thread = user32.GetWindowThreadProcessId(hwnd, None)
    fg_thread = user32.GetWindowThreadProcessId(fg, None) if fg else 0
    attached = False
    if fg_thread and fg_thread != target_thread:
        attached = bool(user32.AttachThreadInput(fg_thread, target_thread, True))
    try:
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
        user32.SetFocus(hwnd)
    finally:
        if attached:
            user32.AttachThreadInput(fg_thread, target_thread, False)

    time.sleep(0.2)
    return user32.GetForegroundWindow() == hwnd


def click_center(hwnd: int) -> None:
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    cx = (rect.left + rect.right) // 2
    cy = (rect.top + rect.bottom) // 2
    user32.SetCursorPos(cx, cy)
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)  # left down
    time.sleep(0.05)
    user32.mouse_event(0x0004, 0, 0, 0, 0)  # left up


def main() -> int:
    ap = argparse.ArgumentParser(description="把 FiveM 窗口切到前台")
    ap.add_argument("--no-click", action="store_true", help="只切窗口，不点中心")
    args = ap.parse_args()

    if sys.platform != "win32":
        print("only on windows")
        return 2

    hwnd = find_fivem_window()
    if not hwnd:
        print("没有找到 FiveM 窗口：游戏没开？")
        return 1

    ok = focus(hwnd)
    if not ok:
        print("SetForegroundWindow 被拒，改用点击窗口中心强切")
        click_center(hwnd)
        time.sleep(0.3)
        ok = user32.GetForegroundWindow() == hwnd

    if ok and not args.no_click:
        click_center(hwnd)

    print(f"hwnd={hwnd} foreground={ok}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
