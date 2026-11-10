#!/usr/bin/env python3
"""开服就绪检查（launch readiness）。

`release_check.py` 管的是"这份代码能不能合"；这里管的是"这台机器能不能开门让人进来"。两者查的东西
几乎不重叠 —— 前者看 diff/文档/密钥，后者看容量、身份、生产开关、数据库账号、备份与迁移状态。

两类作用域：

* **repo** —— 只看入库文件，能在 CI 跑（`--ci` 只跑这一半）；
* **local** —— 只看本机（`server.cfg`、备份目录），那份 cfg 是 gitignored 的。

用法::

    python3 tools/dev/launch_check.py            # 全跑（开服前在服务器上跑）
    python3 tools/dev/launch_check.py --ci       # 只跑 repo 半区（CI/闸门用）
    python3 tools/dev/launch_check.py --json

退出码：0 = 没有未解决的 P0；1 = 有 P0；2 = 环境缺失。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RESOURCES = BASE / "resources"
#: 想检查"备好的生产 cfg"时，用 TCITY_SERVER_CFG=<路径> 指过去（本机默认是开发那份）
SERVER_CFG = Path(os.environ.get("TCITY_SERVER_CFG", str(BASE / "server.cfg")))
MODULES = BASE / "configs" / "modules"

#: 只该在开发环境加载的资源：出现在默认启动集里就是"把调试入口开给了玩家"
DEV_ONLY_RESOURCES = {
    "custom-testing": "游戏内自动化测试（/test、/stress）",
    "custom-agent-ops": "Agent Ops 观测/介入（事件环、/agent）",
    "tcity-e2e": "服务端 E2E harness",
    "custom-debug": "黑屏诊断与强制修复工具",
    "hud-position-tool": "HUD 定位调试（/mapsize /ringpos /huddebug）",
}

#: 命令名里带这些词的，必须自己证明"只给管理员/控制台"
DEV_COMMAND_HINT = re.compile(r"(dev|debug|test|seed|bench|probe|placement)$", re.I)
#: 允许的守卫形状（任一即可）
COMMAND_GUARD = re.compile(
    r"source\s*~=\s*0"
    r"|IsPlayerAceAllowed|IsAdmin|HasPermission|GetConvar\("
    r"|QBCore\.Functions\.GetPermission|isboss"
    r"|['\"](?:admin|god|superadmin)['\"]"      # QBCore.Commands.Add 的第 6 参数
    r"|Config\.CommandPermission|qbcore\.(?:god|admin)",
    re.I,
)
PLACEHOLDER = re.compile(r"(?i)(x{6,}|replace[_-]?with|your[_-]|<[^>]+>|dev-[a-z]+-token|\*{3,})")
VENDOR_DOC_PREFIX = "[system]/monitor/"
SENSITIVE_PATTERNS = {
    "FiveM license key": re.compile(r"cfxk_[A-Za-z0-9]{15,}"),
    "硬编码密码": re.compile(r"(?i)\b(?:password|passwd|pwd)\s*[:=]\s*['\"][^'\"]{6,}['\"]"),
    "Agent 令牌": re.compile(r"(?i)\b(?:agent_actions_token|agent_live_token)\b[^\n]{0,24}['\"][A-Za-z0-9_\-]{12,}['\"]"),
}
COMMENT = re.compile(r"--\[=*\[.*?\]=*\]|--[^\n]*", re.S)
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".ico", ".webp", ".woff", ".woff2", ".ttf", ".zip", ".svg", ".mp3", ".ogg"}


@dataclass
class Finding:
    check: str
    level: str          # P0 / P1 / P2
    scope: str          # repo / local
    ok: bool
    detail: str
    fix: str = ""

    def line(self) -> str:
        mark = "✅" if self.ok else ("❌" if self.level == "P0" else "⚠️")
        suffix = f"  → {self.fix}" if not self.ok and self.fix else ""
        return f"{mark} [{self.level}] {self.check}: {self.detail}{suffix}"


def _tracked_files() -> list[Path]:
    output = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True).stdout
    return [REPO / line for line in output.splitlines() if line.strip()]


def _balance(text: str, open_index: int) -> str:
    """从 `(` 起按括号配对取整段（跳过引号里的括号）。"""
    depth = 0
    index = open_index
    quote = ""
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[open_index:index + 1]
        index += 1
    return text[open_index:]


# ══════════════════════════════════════════════════════════════════
# repo 半区（CI 可跑）
# ══════════════════════════════════════════════════════════════════

def check_dev_resources_not_in_default_boot() -> Finding:
    offenders = []
    # ① 模块 cfg（递归，防止有人在子目录里塞一份）
    for module in sorted(MODULES.rglob("*.cfg")):
        if module.name == "dev.cfg":
            continue
        for line in module.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = re.match(r"\s*(?:ensure|start)\s+[\"']?([\w\-]+)", line)
            if match and match.group(1) in DEV_ONLY_RESOURCES:
                offenders.append(f"{module.name}: {match.group(1)}")

    # ② 真正决定启动集的 server.cfg（本地那份，或 TCITY_SERVER_CFG 指的那份）
    #    这里最容易漏：运维只要在 server.cfg 里加一行 exec dev.cfg，玩家的 /test 就回来了。
    if SERVER_CFG.exists():
        text = SERVER_CFG.read_text(encoding="utf-8", errors="ignore")
        if re.search(r"^\s*exec\s+configs/modules/dev\.cfg", text, re.M):
            offenders.append(f"{SERVER_CFG.name}: exec configs/modules/dev.cfg")
        for match in re.finditer(r"^\s*(?:ensure|start)\s+[\"']?([\w\-]+)", text, re.M):
            if match.group(1) in DEV_ONLY_RESOURCES:
                offenders.append(f"{SERVER_CFG.name}: {match.group(1)}")
    return Finding(
        "#1 调试资源不在默认启动集",
        "P0", "repo", not offenders,
        "干净" if not offenders else "默认会加载：" + "、".join(offenders),
        "把这几行挪到 configs/modules/dev.cfg（生产不 exec 那份）",
    )


def _console_command_sites() -> list[tuple[Path, int, str, str]]:
    """(文件, 行号, 命令名, **整段调用**)。整段而不是固定窗口 —— 权限参数在命令体末尾。"""
    sites = []
    pattern = re.compile(
        r"(?:QBCore\.Commands\.Add|RegisterCommand)\(\s*['\"]([\w\-]+)['\"]"
    )
    for path in RESOURCES.rglob("*.lua"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in pattern.finditer(text):
            call = _balance(text, text.find("(", match.start()))
            sites.append((path, text.count("\n", 0, match.start()) + 1, match.group(1), call))
    return sites


def check_dev_commands_are_guarded() -> Finding:
    server_offenders, client_offenders = [], []
    for path, line, name, call in _console_command_sites():
        if not DEV_COMMAND_HINT.search(name):
            continue
        relative = path.relative_to(RESOURCES).as_posix()
        if "/tests/" in f"/{relative}" or relative.startswith("tests/"):
            continue
        if any(resource in relative for resource in DEV_ONLY_RESOURCES):
            continue
        # 注释里写 IsAdmin 不算守卫：判据跑在去注释后的文本上
        if COMMAND_GUARD.search(COMMENT.sub("", call)):
            continue
        bucket = client_offenders if "/client" in relative else server_offenders
        bucket.append(f"{name} ({relative}:{line})")
    detail = "干净" if not server_offenders else (
        f"服务端 {len(server_offenders)} 条没守卫：" + "、".join(server_offenders[:6])
    )
    if client_offenders:
        detail += f"；客户端 {len(client_offenders)} 条（P2）"
    return Finding(
        "#2 服务端 dev/test 命令有守卫",
        "P0", "repo", not server_offenders, detail,
        "handler 里加 `if source ~= 0 then return end`，或 QBCore.Commands.Add 的第 6 参数给 'admin'，"
        "或用 convar 开关（参考 police_backup_dev）",
    )


def check_no_secrets_in_repo() -> Finding:
    hits = []
    for path in _tracked_files():
        if path.suffix.lower() in BINARY_SUFFIXES:
            continue
        relative_repo = path.relative_to(REPO).as_posix()
        if relative_repo.startswith("tools/") or relative_repo.startswith("tests/") or "/tests/" in f"/{relative_repo}":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for label, pattern in SENSITIVE_PATTERNS.items():
            for match in pattern.finditer(text):
                value = match.group(0)
                if PLACEHOLDER.search(value):
                    continue
                literal = re.search(r"""['"]([A-Za-z0-9_\-+/=]{16,})['"]""", value)
                candidate = literal.group(1) if literal else value
                if not (len(candidate) >= 16
                        and re.search(r"[A-Za-z]", candidate) and re.search(r"\d", candidate)):
                    continue
                tag = "（vendored 示例，P2）" if VENDOR_DOC_PREFIX in relative_repo else ""
                hits.append(f"{label}{tag}: {relative_repo}")
                break
            else:
                continue
            break
    only_vendor = bool(hits) and all("vendored" in hit for hit in hits)
    return Finding(
        "#3 入库文件无密钥",
        "P1" if only_vendor else "P0", "repo", not hits,
        "干净" if not hits else "、".join(hits[:6]),
        "把密钥挪到 gitignored 的 server.cfg / 环境变量",
    )


PROD_TEMPLATE_KEYS = (
    ("sv_maxclients 32", "容量占位"),
    ("set onesync on", "OneSync 显式开启"),
    ("agent_actions_enabled 0", "动作代理默认关闭"),
    ("agent_live_enabled 0", "live 感知默认关闭"),
    ("configs/modules/dev.cfg", "明确写了生产不要 exec dev.cfg"),
)


def check_prod_template_exists() -> Finding:
    template = BASE / "configs" / "prod" / "server.cfg.example"
    if not template.exists():
        return Finding(
            "#4 生产配置模板入库", "P1", "repo", False,
            f"缺少 {template.relative_to(REPO)}",
            "新增 configs/prod/server.cfg.example（无密钥），写清 maxclients / onesync / agent 开关 / DB 账号",
        )
    text = template.read_text(encoding="utf-8", errors="ignore")
    missing = [why for needle, why in PROD_TEMPLATE_KEYS if needle not in text]
    db_ok = re.search(r'mysql://(?!(?:root|\$\{))[\w.-]+:', text) is not None
    if not db_ok:
        missing.append("DB 账号不是 root")
    return Finding(
        "#4 生产配置模板入库且内容完整", "P1", "repo", not missing,
        "存在且齐全" if not missing else "模板缺：" + "、".join(missing),
        "把缺的项补进模板（它是「生产该长什么样」的唯一说明书）",
    )


def check_backup_tooling_exists() -> Finding:
    tool = REPO / "tools" / "dev" / "db_backup.py"
    doc = REPO / "docs" / "engineering" / "2026-11-launch-runbook.md"
    problems = []
    if not tool.exists():
        problems.append("缺 db_backup.py")
    elif "mariadb-dump" not in tool.read_text(encoding="utf-8", errors="ignore"):
        problems.append("db_backup.py 里没有 dump 实现")
    if not doc.exists():
        problems.append("缺 launch-runbook.md")
    else:
        text = doc.read_text(encoding="utf-8", errors="ignore")
        for needle in ("db_backup.py", "恢复演练"):
            if needle not in text:
                problems.append(f"runbook 里没写 {needle}")
    return Finding(
        "#5 备份与恢复手册",
        "P0", "repo", not problems,
        "齐" if not problems else "；".join(problems),
        "新增 tools/dev/db_backup.py（dump + 保留策略）与 docs/engineering/2026-11-launch-runbook.md（含恢复演练）",
    )


# ══════════════════════════════════════════════════════════════════
# local 半区（只在部署机跑）
# ══════════════════════════════════════════════════════════════════

def _cfg_text() -> str | None:
    return SERVER_CFG.read_text(encoding="utf-8", errors="ignore") if SERVER_CFG.exists() else None


def _cfg_value(text: str, key: str) -> str | None:
    # `sv_maxclients 8` 这种裸写法不带 set/setr，两种都要认
    match = re.search(rf'^\s*(?:(?:set|setr)\s+)?{re.escape(key)}\s+"?([^"\n]*)"?', text, re.M)
    return match.group(1).strip() if match else None


def check_capacity() -> Finding:
    text = _cfg_text()
    if text is None:
        return Finding("#6 容量", "P0", "local", False, "本地没有 server.cfg", "在部署机上放好 server.cfg")
    value = _cfg_value(text, "sv_maxclients")
    slots = int(value) if value and value.isdigit() else 0
    return Finding(
        "#6 容量 sv_maxclients", "P0", "local", slots >= 32,
        f"sv_maxclients = {slots}" + ("（开发值，开服前必须改）" if slots and slots < 32 else ""),
        "按实际槽位设置（≥32），同时 `set onesync on`",
    )


def check_onesync() -> Finding:
    text = _cfg_text()
    if text is None:
        return Finding("#7 OneSync", "P0", "local", False, "本地没有 server.cfg", "")
    enabled = re.search(r"^\s*set\s+onesync\s+\"?on", text, re.M) is not None
    return Finding(
        "#7 OneSync 显式开启", "P1", "local", enabled,
        "已开启" if enabled else "server.cfg 里没有 `set onesync on`（32+ 槽位必须显式打开）",
        "在 server.cfg 里加 `set onesync on`",
    )


def check_hostname() -> Finding:
    text = _cfg_text()
    if text is None:
        return Finding("#8 服务器名", "P1", "local", False, "本地没有 server.cfg", "")
    hostname = _cfg_value(text, "sv_hostname") or ""
    clean = bool(hostname) and not re.search(r"(?i)\bdev\b|调试|test", hostname) and "<" not in hostname
    return Finding(
        "#8 服务器名不是 DEV", "P1", "local", clean, f"sv_hostname = {hostname or '（空）'}",
        "改成对外展示的名字（玩家列表里第一眼看到的就是它）",
    )


def check_agent_switches() -> Finding:
    text = _cfg_text()
    if text is None:
        return Finding("#9 Agent 开关", "P0", "local", False, "本地没有 server.cfg", "")
    actions = _cfg_value(text, "agent_actions_enabled") or "0"
    live = _cfg_value(text, "agent_live_enabled") or "0"
    tokens = [_cfg_value(text, name) for name in ("agent_actions_token", "agent_actions_admin_token", "agent_live_token")]
    secrets_present = any(token and len(token) >= 8 for token in tokens)
    enabled = actions in {"1", "true", "yes"} or live in {"1", "true", "yes"}
    # 开着但没 token 更糟：要么等于裸奔，要么实现里根本不校验 —— 两种情况都不许 P0 归零
    ok = (not enabled) or secrets_present
    return Finding(
        "#9 Agent 动作/live 关闭或换 token", "P0", "local", ok,
        f"agent_actions_enabled={actions} agent_live_enabled={live}"
        + ("（cfg 里还有明文 dev token）" if secrets_present else ""),
        "生产环境设 0 / 移除；确需开启就换新 token 并只给受信网络",
    )


def check_db_account() -> Finding:
    text = _cfg_text()
    if text is None:
        return Finding("#10 数据库账号", "P0", "local", False, "本地没有 server.cfg", "")
    match = re.search(r'mysql_connection_string\s+"mysql://([^:]+):', text)
    user = match.group(1) if match else "?"
    return Finding(
        "#10 数据库账号不是 root", "P0", "local", user not in {"root", "?"},
        f"user = {user}",
        "建专用账号：只给 TCityLite 库的 SELECT/INSERT/UPDATE/DELETE + 必要 DDL",
    )


def check_backups_fresh() -> Finding:
    directory = REPO / "backups"
    if not directory.exists():
        return Finding("#11 最近备份", "P0", "local", False, "没有 backups/ 目录（从没备份过？）",
                       "跑 tools/dev/db_backup.py，并配成每天一次")
    candidates = sorted(directory.glob("*.sql"), key=lambda path: path.stat().st_mtime, reverse=True)
    if not candidates:
        return Finding("#11 最近备份", "P0", "local", False, "backups/ 里没有 .sql 文件",
                       "跑 tools/dev/db_backup.py，并配成每天一次")
    newest = candidates[0]
    age_hours = (datetime.now().timestamp() - newest.stat().st_mtime) / 3600
    # 只看 mtime 会把空文件/半截文件当成"最近备份" —— manifest 里的表数与 sha256 才是证据
    manifest = newest.with_suffix(".json")
    problems = []
    if age_hours > 24:
        problems.append(f"最近备份 {age_hours:.1f} 小时前")
    if not manifest.exists():
        problems.append("缺 manifest（无法证明可恢复）")
    else:
        try:
            info = json.loads(manifest.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            info = {}
        if info.get("bytes") != newest.stat().st_size:
            problems.append("manifest 记录的大小与文件不一致")
        if int(info.get("tables", 0)) < 50:
            problems.append(f"备份里只有 {info.get('tables', 0)} 张表（像是空库/半截）")
    return Finding(
        "#11 最近备份可恢复（24h 内 + manifest 对得上）", "P0", "local", not problems,
        "、".join(problems) if problems else f"{newest.name}，{age_hours:.1f} 小时前",
        "配置定时任务：每天跑一次 db_backup.py，保留 7 天",
    )


REPO_CHECKS = (
    check_dev_resources_not_in_default_boot,
    check_dev_commands_are_guarded,
    check_no_secrets_in_repo,
    check_prod_template_exists,
    check_backup_tooling_exists,
)
def check_placeholders_replaced() -> Finding:
    """模板里的 `<...>` 不能原样上生产 —— 这一项防的是"把 example 复制过去就开服"。"""
    text = _cfg_text()
    if text is None:
        return Finding("#12 占位符已替换", "P0", "local", False, "本地没有 server.cfg", "")
    problems = []
    license_value = _cfg_value(text, "sv_licenseKey") or ""
    if "<" in license_value or not re.match(r"^cfxk_[A-Za-z0-9_]{10,}$", license_value):
        problems.append("sv_licenseKey 缺失/是占位符")
    rcon = _cfg_value(text, "rcon_password") or ""
    if "<" in rcon or len(rcon) < 12:
        problems.append("rcon_password 太短或是占位符")
    match = re.search(r'mysql_connection_string\s+"mysql://[^:]+:([^@]*)@', text)
    password = match.group(1) if match else ""
    if not password or "<" in password:
        problems.append("DB 口令是占位符")
    return Finding(
        "#12 占位符已替换（license / rcon / DB 口令）", "P0", "local", not problems,
        "已替换" if not problems else "、".join(problems),
        "把 configs/prod/server.cfg.example 里的 <...> 换成真实值",
    )


LOCAL_CHECKS = (
    check_capacity,
    check_onesync,
    check_hostname,
    check_agent_switches,
    check_db_account,
    check_backups_fresh,
    check_placeholders_replaced,
)


def run(include_local: bool = True) -> list[Finding]:
    findings = [check() for check in REPO_CHECKS]
    if include_local:
        findings.extend(check() for check in LOCAL_CHECKS)
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="开服就绪检查")
    parser.add_argument("--ci", action="store_true", help="只跑 repo 半区（不含本机 server.cfg）")
    parser.add_argument("--json", action="store_true", help="机器可读输出")
    args = parser.parse_args(argv)

    findings = run(include_local=not args.ci)
    blocking = [item for item in findings if not item.ok and item.level == "P0"]
    warnings = [item for item in findings if not item.ok and item.level != "P0"]

    if args.json:
        print(json.dumps([
            {"check": item.check, "level": item.level, "scope": item.scope,
             "ok": item.ok, "detail": item.detail, "fix": item.fix}
            for item in findings
        ], ensure_ascii=False, indent=1))
    else:
        for item in findings:
            print(item.line())
        print()
        print(f"P0 未解决 {len(blocking)} 项，P1/P2 警告 {len(warnings)} 项")

    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
