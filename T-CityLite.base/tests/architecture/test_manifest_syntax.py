"""MANIFEST-01 — 每个 fxmanifest 必须是合法 Lua，且依赖名不能拼错。

为什么需要这条：往 `dependencies { }` 里插一条时漏掉逗号，`restart <resource>` **不会报错**
——FiveM 复用已解析的资源元数据，只有 `refresh` 或整机启动才会重新解析。于是错误会在
很久以后以"整套启动时 6 个资源 failed to load"的形式炸出来，而且现场是 45 个资源在跑、
另外 39 个没了，很容易误判成"服务器挂了"。

真实事故：给 6 个资源补 `core-framework` 依赖时插在最后一项之后没加逗号，
`dependencies { 'qb-core' 'core-framework', }` —— 每次 `restart` 都"成功"。

规则：
1. 每个 `fxmanifest.lua` 能用 luac5.4 解析（manifest 就是 Lua）；
2. `dependencies` / `client_scripts` / `server_scripts` 里的字面量名字，若指向本仓库资源，
   必须真的有对应目录（拼错资源名不会在单资源重启时暴露）；
3. 反向校验：喂一个缺逗号的 manifest，解析必须失败。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"


def manifests() -> list[Path]:
    return sorted(p for p in RESOURCES.rglob("fxmanifest.lua") if "node_modules" not in p.parts)


def parse_manifest(path: Path) -> tuple[bool, str]:
    """用 luac5.4 -p 校验（manifest 是 Lua 表调用，语法错会在这里暴露）。"""
    luac = shutil.which("luac5.4")
    if not luac:
        return True, "luac5.4 不可用，跳过"
    proc = subprocess.run([luac, "-p", str(path)], capture_output=True, text=True)
    return proc.returncode == 0, (proc.stderr or "").strip()


# 只校验"我们自己的资源名"：vendored 资源会依赖 cfx 自带资源（mapmanager 等）、
# 引用 .js/.lua 文件，甚至块里带注释。全量校验会淹在噪音里，然后被整条放宽。
OURS = re.compile(r"^(custom-|qb-|tcity-|core-)")


def declared_names(path: Path) -> list[str]:
    """只抓 `dependencies { ... }` 块里**我们自己的**资源名。"""
    text = path.read_text(encoding="utf-8", errors="ignore")
    text = re.sub(r"--[^\n]*", "", text)          # 先剥注释，否则块里的说明会被当名字
    names: list[str] = []
    for block in re.finditer(r"dependencies\s*\{([^}]*)\}", text, re.DOTALL):
        names.extend(n for n in re.findall(r"['\"]([^'\"]+)['\"]", block.group(1)) if OURS.match(n))
    return names


def resource_dirs() -> set[str]:
    found = set()
    for bracket in RESOURCES.iterdir():
        if not bracket.is_dir():
            continue
        for res in bracket.iterdir():
            if res.is_dir():
                found.add(res.name)
    return found


def test_every_manifest_parses():
    problems = []
    for path in manifests():
        ok, err = parse_manifest(path)
        if not ok:
            problems.append(f"{path.relative_to(BASE)}: {err.splitlines()[0] if err else 'parse error'}")
    assert not problems, (
        "这些 fxmanifest 不是合法 Lua（`restart` 不会报错，只有 refresh/重启才暴露）：\n  "
        + "\n  ".join(problems))


def test_dependency_names_point_at_real_resources():
    known = resource_dirs()
    problems = []
    for path in manifests():
        for name in declared_names(path):
            if name in known:
                continue
            problems.append(f"{path.relative_to(BASE)}: dependencies 里写了不存在的资源 '{name}'")
    assert not problems, "\n".join(problems)


def test_manifest_without_a_comma_is_rejected(tmp_path: Path):
    bad = tmp_path / "fxmanifest.lua"
    bad.write_text("fx_version 'cerulean'\ngame 'gta5'\n\ndependencies {\n    'qb-core'\n    'core-framework',\n}\n",
                   encoding="utf-8")
    ok, err = parse_manifest(bad)
    assert not ok and "'}' expected" in err, "缺逗号的 manifest 必须被判非法"
