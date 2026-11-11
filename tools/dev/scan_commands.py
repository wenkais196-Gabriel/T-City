#!/usr/bin/env python3
"""生成管理员命令清单（docs/client/ux/admin-commands.md）。

为什么要有这个工具
------------------
管理员最常问的两件事：**有什么命令**、**这条命令我能用吗**。仓库里 300+ 条命令
散在 100+ 个资源里，游戏内 `/amenu` 只印了 10 条硬编码的。这个工具把全仓扫一遍，
按「权限来源」和「是否危险」列出来，生成一份可检索的清单。

设计约束
--------
* 只读扫描：不改任何资源。
* 权限列必须来自**调用本身**（`QBCore.Commands.Add` 的最后一个参数 / `IsPlayerAceAllowed`），
  不能靠命令名猜。
* 括号配对要用「API 名之后的第一个 `(`」，否则会撞进 `Lang:t(...)` 里，权限参数永远读不到。
* 危险命令但没有判权的，单独标红 —— 那是真正需要修的地方。

用法::

    python3 tools/dev/scan_commands.py            # 写文档
    python3 tools/dev/scan_commands.py --check    # 只比对，不写（闸门用）
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RES = REPO / "T-CityLite.base" / "resources"
OUT_MD = REPO / "docs" / "client" / "ux" / "admin-commands.md"

CALL = re.compile(r"(QBCore\.Commands\.Add|RegisterCommand)\s*\(\s*['\"]([\w:_.-]+)['\"]")
DANGER = {
    "addmoney", "setmoney", "removemoney", "giveitem", "removeitem", "car", "dv", "dvall",
    "tp", "tpm", "kick", "ban", "unban", "setjob", "setgang", "setpermission",
    "addpermission", "removepermission", "togglepvp", "openserver", "closeserver",
    "revive", "heal", "aduty", "clearinventory", "clearme", "givemelicense",
    "revokelicense", "revokemelicense", "reinstatelicense", "suspendlicense",
}

FRONTMATTER = """---
id: ux-admin-commands
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

> **本文件由 `tools/dev/scan_commands.py` 生成，不要手改。**
> 改代码后跑一次：`python3 tools/dev/scan_commands.py`；闸门 `test_admin_commands_doc.py` 会比对是否过期。
"""


def balanced_call(text: str, start: int, limit: int = 4000) -> str:
    depth = 0
    for index in range(start, min(len(text), start + limit)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return text[start:start + limit]


#: 回调内部自建的门禁（注册成 user，但进了回调先判定）。扫描器要能认出来，
#: 否则文档会把"注册成 user + 内部判定"写成"全体可用"，管理员照着文档会误判。
INLINE_GATES = ("canUseLicenseTool", "CanRevive", "canActOn", "HasPermission(",
                "IsPlayerAceAllowed(", "PolicePolicy.Can(", "QBCore.Functions.HasPermission(")


def classify(call: str, api: str) -> str:
    perms = re.findall(r"['\"](god|admin|mod|user)['\"]", call)
    if perms and perms[-1] != "user":
        return "QBCore: " + perms[-1]
    for gate in INLINE_GATES:
        if gate in call:
            name = gate.rstrip("(")
            return "handler 内判定: " + name
    if perms:
        return "QBCore: " + perms[-1]
    ace = re.search(r"IsPlayerAceAllowed\(\s*\w+\s*,\s*['\"]([^'\"]+)['\"]", call)
    if ace:
        return "ACE: " + ace.group(1)
    if re.search(r"HasPermission\(", call):
        return "HasPermission"
    if re.search(r"Getter\.(job|gang)|PlayerData\.job\.(name|type)", call):
        return "job/gang 判定"
    if api == "RegisterCommand" and re.search(r",\s*true\s*\)\s*$", call):
        return "restricted=true"
    return "—"


def resource_of(path: Path) -> str:
    parts = path.relative_to(RES).parts
    # resources/<分类>/<资源>/... → 取"资源"那一层；直接在 resources/ 下的取第一层
    return str(parts[1]) if len(parts) > 1 else str(parts[0])


def scan() -> list[dict]:
    rows = []
    for path in sorted(RES.rglob("*.lua")):
        if any(part in {"node_modules", "html", "web", "dist", "stream"} for part in path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for match in CALL.finditer(text):
            api, name = match.group(1), match.group(2)
            call = balanced_call(text, text.index("(", match.start()))
            line = text[: match.start()].count("\n") + 1
            rows.append({
                "resource": resource_of(path),
                "where": f"{path.relative_to(REPO).as_posix()}:{line}",
                "command": name,
                "api": api,
                "permission": classify(call, api),
                "dangerous": name in DANGER,
            })
    return rows


def render(rows: list[dict]) -> str:
    lines = [FRONTMATTER, ""]
    lines.append("# 管理员命令清单")
    lines.append("")
    lines.append(f"共 **{len(rows)}** 条命令。`权限` 列是扫描器从调用里读到的判定；"
                 "`—` 表示没读到（**新命令默认不该是 `—`**）。")
    lines.append("")

    dangerous_none = [r for r in rows if r["dangerous"] and r["permission"] == "—"]
    lines.append(f"## 危险命令但没有判权：{len(dangerous_none)} 条")
    lines.append("")
    if dangerous_none:
        lines.append("| 命令 | 位置 |")
        lines.append("|---|---|")
        for row in dangerous_none:
            lines.append(f"| `{row['command']}` | {row['where']} |")
    else:
        lines.append("无。")
    lines.append("")

    by_perm: dict[str, int] = {}
    for row in rows:
        key = row["permission"].split(":")[0]
        by_perm[key] = by_perm.get(key, 0) + 1
    lines.append("## 权限分布")
    lines.append("")
    lines.append("| 权限来源 | 命令数 |")
    lines.append("|---|---|")
    for key in sorted(by_perm, key=lambda k: -by_perm[k]):
        lines.append(f"| {key} | {by_perm[key]} |")
    lines.append("")

    by_res: dict[str, list[dict]] = {}
    for row in rows:
        by_res.setdefault(row["resource"], []).append(row)

    lines.append("## 按资源分组")
    lines.append("")
    for resource in sorted(by_res):
        lines.append(f"### {resource}")
        lines.append("")
        lines.append("| 命令 | API | 权限 | 位置 |")
        lines.append("|---|---|---|---|")
        for row in sorted(by_res[resource], key=lambda r: r["command"]):
            flag = " ⚠️" if row["dangerous"] and row["permission"] == "—" else ""
            lines.append(f"| `{row['command']}`{flag} | {row['api']} | {row['permission']} | {row['where']} |")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只比对，不写文件")
    parser.add_argument("--json", action="store_true", help="打印 JSON 统计")
    args = parser.parse_args(argv[1:])

    rows = scan()
    content = render(rows)
    if args.json:
        print(json.dumps({"total": len(rows),
                          "no_permission": sum(1 for r in rows if r["permission"] == "—"),
                          "dangerous_without_permission":
                              sum(1 for r in rows if r["dangerous"] and r["permission"] == "—")},
                         ensure_ascii=False))

    if args.check:
        if not OUT_MD.exists():
            print(f"缺少 {OUT_MD}，先跑一次不带 --check 的", file=sys.stderr)
            return 1
        current = OUT_MD.read_text(encoding="utf-8")
        if current != content:
            print("命令清单已过期，请重跑：python3 tools/dev/scan_commands.py", file=sys.stderr)
            return 1
        print("命令清单是最新的")
        return 0

    OUT_MD.parent.mkdir(parents=True, exist_ok=True)
    OUT_MD.write_text(content, encoding="utf-8")
    print(f"已写入 {OUT_MD.relative_to(REPO)}（{len(rows)} 条命令）")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        sys.exit(0)
