#!/usr/bin/env python3
"""启动顺序（P2-2）—— 把"谁先起、为什么"从注释里搬到可校验的数据结构。

问题：`server.cfg` 是 gitignored，里面那 17 行 `exec configs/modules/xxx.cfg` 的顺序只活在
本地文件；模块 cfg 里的顺序约束（"core-framework 依赖 production-freeze，排在两者之间"）只活在
注释里。换台机器 / 删掉注释，顺序就没人知道了，而错序的表现是"资源启动失败"或更糟的
"启动时机不对 → exports 还没注册"，恰好在真机上才暴露。

现在的形状：
  * `configs/boot.json` —— 模块 exec 顺序的唯一事实来源（入库）；
  * 每个模块 cfg 里的 `ensure` 行 —— 资源级顺序（入库）；
  * 本工具 —— 把两层合起来，按 fxmanifest 的 `dependency` 校验「依赖必须先于使用」。

用法::

    python3 tools/dev/boot_cfg.py --check          # 校验（CI 与闸门用同一份逻辑）
    python3 tools/dev/boot_cfg.py --list           # 打印解析出的启动序列
    python3 tools/dev/boot_cfg.py --check --server-cfg T-CityLite.base/server.cfg
                                                   # 额外核对本地 server.cfg 的 exec 顺序

退出码：0 = 通过；1 = 有错序/未知资源；2 = 输入缺失。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RESOURCES = BASE / "resources"
MODULES = BASE / "configs" / "modules"
BOOT = BASE / "configs" / "boot.json"

#: FiveM 内置 / 平台级依赖：不在 resources/ 下，也不该被 ensure
BUILTIN_DEP = re.compile(r"^(/|@|https?://)")
#: 由平台自带（citizen/ 或内置资源），不在本仓库
BUILTIN_RESOURCE = {"chat", "mapmanager", "spawnmanager", "sessionmanager", "hardcap",
                    "basic-gamemode", "baseevents", "monitor", "runcode", "yarn", "webpack"}

ENSURE = re.compile(r"^\s*ensure\s+([\w\-\@\.]+)\s*(?:#.*)?$")   # cfg 里允许行尾 # 注释
EXEC_MODULE = re.compile(r"^\s*exec\s+configs/modules/([\w\-]+\.cfg)\s*$")
DEP_KEYWORD = re.compile(r"\b(dependencies|dependency|depend)\b", re.I)
QUOTED = re.compile(r"""['"]([^'"]+)['"]""")
COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]|--[^\n]*", re.S)


class BootError(Exception):
    """启动顺序有问题（`message` 直接给人看）。"""


def strip_comments(source: str) -> str:
    return COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), source)


def _statement(text: str, index: int) -> str:
    """关键词之后的内容：`{`/`(` 走括号配对，否则取到行尾。"""
    length = len(text)
    while index < length and text[index] in " \t":
        index += 1
    if index < length and text[index] in "{(":
        opener = text[index]
        closer = "}" if opener == "{" else ")"
        depth, start = 0, index + 1
        while index < length:
            if text[index] == opener:
                depth += 1
            elif text[index] == closer:
                depth -= 1
                if depth == 0:
                    return text[start:index]
            index += 1
        return text[start:]

    end = text.find("\n", index)
    return text[index:end if end != -1 else length]


def resource_index(resources: Path = RESOURCES) -> dict[str, Path]:
    """资源名 → 目录（资源放在 `[qb]/qb-core` 这类分类子目录下）。"""
    index: dict[str, Path] = {}
    for manifest in resources.rglob("fxmanifest.lua"):
        index.setdefault(manifest.parent.name, manifest.parent)
    return index


def manifest_dependencies(name: str, index: dict[str, Path]) -> list[str]:
    directory = index.get(name)
    if not directory:
        return []
    for filename in ("fxmanifest.lua", "__resource.lua"):
        path = directory / filename
        if not path.exists():
            continue
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        deps: list[str] = []
        for match in DEP_KEYWORD.finditer(text):
            deps.extend(QUOTED.findall(_statement(text, match.end())))
        return deps
    return []


def boot_modules(boot: Path = BOOT) -> tuple[list[str], dict[str, str]]:
    data = json.loads(boot.read_text(encoding="utf-8"))
    return list(data.get("modules", [])), dict(data.get("optional_modules", {}))


def module_ensures(module: str, modules: Path = MODULES) -> list[str]:
    path = modules / module
    if not path.exists():
        raise BootError(f"boot.json 列了 {module}，但 {path} 不存在")
    out = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        match = ENSURE.match(line)
        if match:
            out.append(match.group(1))
    return out


def startup_sequence(boot: Path = BOOT, modules: Path = MODULES) -> list[tuple[str, str]]:
    """[(resource, module), ...]，按真实 exec 顺序展开。"""
    order, _optional = boot_modules(boot)
    sequence: list[tuple[str, str]] = []
    for module in order:
        sequence.extend((resource, module) for resource in module_ensures(module, modules))
    return sequence


def check(boot: Path = BOOT, modules: Path = MODULES, resources: Path = RESOURCES,
          server_cfg: Path | None = None) -> list[str]:
    """返回问题列表（空 = 通过）。"""
    problems: list[str] = []
    order, optional = boot_modules(boot)

    if not order:
        problems.append("boot.json 没有 modules 列表")

    # 1) 模块清单与目录一致
    on_disk = {path.name for path in modules.glob("*.cfg")}
    listed = set(order) | set(optional)
    for missing in sorted(on_disk - listed):
        problems.append(f"configs/modules/{missing} 没有出现在 boot.json（modules 或 optional_modules）")
    for unknown in sorted(listed - on_disk):
        problems.append(f"boot.json 列了 {unknown}，但 configs/modules/ 里没有这个文件")
    duplicated = [name for name in order if order.count(name) > 1]
    for name in sorted(set(duplicated)):
        problems.append(f"boot.json 里 {name} 出现了 {order.count(name)} 次")

    # 2) 资源不重复、不指空
    index = resource_index(resources)
    sequence = startup_sequence(boot, modules)
    seen: dict[str, str] = {}
    for resource, module in sequence:
        if resource in seen:
            problems.append(f"{resource} 被 ensure 了两次（{seen[resource]} 和 {module}）")
        seen[resource] = module
        if resource not in index and resource not in BUILTIN_RESOURCE:
            problems.append(f"{module} ensure 了不存在的资源 {resource}")

    # 3) 依赖必须先于使用
    position = {resource: i for i, (resource, _) in enumerate(sequence)}
    for resource, module in sequence:
        if resource not in index:
            continue
        for dep in manifest_dependencies(resource, index):
            if BUILTIN_DEP.match(dep):
                continue
            if dep in BUILTIN_RESOURCE:
                continue
            if dep not in position:
                problems.append(f"{resource}（{module}）依赖 {dep}，但启动序列里没有它")
                continue
            if position[dep] > position[resource]:
                problems.append(
                    f"{resource}（{module}）依赖 {dep}，但 {dep} 排在它后面"
                    f"（#{position[dep]} > #{position[resource]}）"
                )

    # 4) 本地 server.cfg 的 exec 顺序（可选；那份文件 gitignored）
    if server_cfg and server_cfg.exists():
        executed = [m.group(1) for line in server_cfg.read_text(encoding="utf-8", errors="ignore").splitlines()
                    if (m := EXEC_MODULE.match(line))]
        if executed != order:
            problems.append(
                "server.cfg 的 exec 顺序与 boot.json 不一致："
                f"server.cfg={executed} boot.json={order}"
            )
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="启动顺序校验（P2-2）")
    parser.add_argument("--check", action="store_true", help="校验启动顺序")
    parser.add_argument("--list", action="store_true", help="打印启动序列")
    parser.add_argument("--server-cfg", type=Path, default=None,
                        help="顺带核对本地 server.cfg 的 exec 顺序（该文件不入库）")
    parser.add_argument("--json", action="store_true", help="机器可读输出")
    args = parser.parse_args(argv)

    if not BOOT.exists():
        print(f"[boot] 缺少 {BOOT}", file=sys.stderr)
        return 2

    try:
        if args.list:
            sequence = startup_sequence()
            if args.json:
                print(json.dumps([{"resource": r, "module": m} for r, m in sequence],
                                 ensure_ascii=False, indent=1))
            else:
                for number, (resource, module) in enumerate(sequence, start=1):
                    print(f"{number:3d}. {resource:32s} ← {module}")
            return 0

        problems = check(server_cfg=args.server_cfg)
    except BootError as exc:
        print(f"[boot] {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps({"ok": not problems, "problems": problems}, ensure_ascii=False, indent=1))
    elif problems:
        print(f"[boot] {len(problems)} 个问题：")
        for problem in problems:
            print(f"  - {problem}")
    else:
        sequence = startup_sequence()
        print(f"[boot] 通过：{len(sequence)} 个资源、{len(boot_modules()[0])} 个模块，依赖顺序正确")

    if args.check or not problems:
        return 0 if not problems else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
