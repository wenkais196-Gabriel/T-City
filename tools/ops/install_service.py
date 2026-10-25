#!/usr/bin/env python3
"""安装 / 校验 systemd 单元：让服务器在崩溃后自己起来，并且日志进 journald。

用法::

    python3 tools/ops/install_service.py --check-only    # 只校验，不改系统（不需要 root）
    sudo python3 tools/ops/install_service.py            # 安装并启用
    sudo systemctl status tcity

为什么要一个"会校验的安装脚本"而不是直接 `cp`：

* `Restart=no` / 缺 `[Install]` / `ExecStart` 指向不存在的脚本，这些错误 systemd 只在
  启动那一刻报，容易变成"以为配了、其实没守护"；
* 单元文件里的绝对路径是本仓库的路径，换目录就该重新生成，而不是留一份过期的文件。

退出码：0 成功 / 1 校验失败 / 2 权限或环境不允许。
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
UNIT_SRC = REPO / "tools" / "ops" / "tcity.service"
UNIT_DST = Path("/etc/systemd/system/tcity.service")
LOG_DIR = Path("/var/log/tcity")
SERVICE_USER = "swk"
MAX_RESTART_SEC = 30


def render(text: str, repo_root: Path) -> str:
    """把模板里的 @REPO@ 换成本仓库绝对路径。

    单元文件里必须写绝对路径（systemd 不认相对路径），但仓库在不同机器/CI 上的位置不同，
    所以文件本身是模板，安装时才落地真实路径。
    """
    return text.replace("@REPO@", str(repo_root))


def _parse(text: str) -> dict[str, dict[str, str]]:
    """极简 ini 解析：只处理 systemd 需要的 key=value 与 [section]。"""
    sections: dict[str, dict[str, str]] = {}
    current = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, {})
            continue
        if "=" in line and current:
            key, _, value = line.partition("=")
            sections[current][key.strip()] = value.strip()
    return sections


def validate_unit(text: str, repo_root: Path) -> list[str]:
    """返回问题列表；空列表表示这份单元可以装。

    传入模板或已渲染的文本都行：这里统一先渲染成 repo_root 下的绝对路径再判断，
    这样同一份文件在开发机和 CI 上校验结论一致。
    """
    problems: list[str] = []
    sections = _parse(render(text, repo_root))

    for required in ("Unit", "Service", "Install"):
        if required not in sections:
            problems.append(f"缺少 [{required}] 段（缺 Install 就不会开机自启）")

    service = sections.get("Service", {})
    install = sections.get("Install", {})

    restart = service.get("Restart", "")
    if restart != "always":
        problems.append(
            f"Restart={restart or '(未设置)'}，必须是 always（FXServer 被 SIGKILL 时 on-failure 不一定拉起）"
        )

    restarts_sec = service.get("RestartSec", "")
    try:
        delay = int(restarts_sec)
    except ValueError:
        delay = None
    if delay is None or delay <= 0 or delay > MAX_RESTART_SEC:
        problems.append(f"RestartSec={restarts_sec or '(未设置)'}，应在 1..{MAX_RESTART_SEC} 秒之间")

    exec_start = service.get("ExecStart", "")
    if not exec_start:
        problems.append("缺少 ExecStart")
    else:
        parts = exec_start.split()
        script = parts[-1] if parts else ""
        if not script.startswith("/"):
            problems.append(f"ExecStart 必须是绝对路径: {exec_start}")
        elif not Path(script).is_file():
            problems.append(f"ExecStart 指向的脚本不存在: {script}")

    user = service.get("User", "")
    if not user:
        problems.append("缺少 User=，默认会用 root 跑 FXServer")
    elif user == "root":
        problems.append("User=root 不允许：root 跑服务器会掩盖写权限问题，也让日志全是 root 所有")

    workdir = service.get("WorkingDirectory", "")
    if workdir and not Path(workdir).is_dir():
        problems.append(f"WorkingDirectory 不存在: {workdir}")

    std_out = service.get("StandardOutput", "")
    if not std_out.startswith("append:/"):
        problems.append(
            f"StandardOutput={std_out or '(未设置)'}，应写成 append:/var/log/tcity/console.log（自检读这个文件）"
        )
    else:
        log_path = Path(std_out.split("append:", 1)[1])
        if not log_path.is_absolute():
            problems.append(f"StandardOutput 必须是绝对路径: {std_out}")

    if "WantedBy" not in install:
        problems.append("缺少 WantedBy=multi-user.target（开机不会自启）")

    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="安装 T-City Lite 的 systemd 单元")
    parser.add_argument("--check-only", action="store_true", help="只校验单元文件")
    parser.add_argument("--unit", default=str(UNIT_SRC), help="单元文件路径")
    args = parser.parse_args(argv)

    unit_path = Path(args.unit)
    if not unit_path.is_file():
        print(f"[service] 找不到单元文件: {unit_path}", file=sys.stderr)
        return 1

    problems = validate_unit(unit_path.read_text(encoding="utf-8"), repo_root=REPO)
    if problems:
        print("[service] 单元文件不合法：", file=sys.stderr)
        for item in problems:
            print(f"  - {item}", file=sys.stderr)
        return 1

    if args.check_only:
        print(f"OK 单元文件通过校验: {unit_path}")
        return 0

    if os.geteuid() != 0:
        print("[service] 需要 root：sudo python3 tools/ops/install_service.py", file=sys.stderr)
        return 2

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    if shutil.which("systemctl") is None:
        print("[service] 本机没有 systemctl", file=sys.stderr)
        return 2

    UNIT_DST.write_text(render(unit_path.read_text(encoding="utf-8"), REPO), encoding="utf-8")
    os.chmod(UNIT_DST, 0o644)
    for cmd in (
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", "--now", "tcity"],
    ):
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"[service] {' '.join(cmd)} 失败: {proc.stderr.strip()}", file=sys.stderr)
            return 1

    print(f"OK 已安装并启动 {UNIT_DST}")
    print("    查看状态: systemctl status tcity")
    print(f"    日志:     {LOG_DIR / 'console.log'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
