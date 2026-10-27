"""ORPHAN-01 — `[custom]` 下不许有"看起来在跑、其实没被清单加载"的脚本。

真实教训：`custom-main/server/security.lua`（260 行）与 `custom-security/server/security.lua`
是同一份安全服务的两份拷贝，只差 26 行（日志前缀、`custom-main` → `custom-logs` 导出名）。
按"重复实现"的思路应该合并——但 `custom-main/fxmanifest.lua` **根本没列这个文件**：
它是资源拆分（security 迁到 custom-security、日志迁到 custom-logs、犯罪迁到 custom-crime）
之后留下的残骸。

这类死代码比没有代码更贵：

* 它会被当成权威实现去读、去改（本轮就差点去"修"它）；
* 它让重复实现的统计虚高，看不出真实收敛进展；
* 它让 `exports['custom-main']:LogSecurity` 这种调用看起来"应该有"，实际一调就炸。

同一批残骸还有 `custom-main/server/{}` 里的 `crime.lua`、`logs.lua` 与 `client/security.lua`，
以及 `custom-admin/client/menu.lua`。

规则：`[custom]` 下每个 `.lua` 要么出现在自己资源的 fxmanifest 里（含 `dir/*.lua` 通配），
要么在文件名或路径上明确标记为非运行时产物：
- `_` 前缀（临时探针/脚本）
- 位于 `tests/`、`dev/`、`tools/` 目录
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources" / "[custom]"

NON_RUNTIME_DIRS = {"tests", "dev", "tools"}
MANIFESTS = ("fxmanifest.lua", "__resource.lua")


def manifest_text(resource: Path) -> str:
    for name in MANIFESTS:
        candidate = resource / name
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8", errors="ignore")
    return ""


def listed(rel: str, text: str) -> bool:
    """rel 是否被清单直接列出，或被 `dir/*.lua` 通配覆盖。"""
    rel = rel.lstrip("./")
    if f"'{rel}'" in text or f'"{rel}"' in text:
        return True
    directory = rel.rsplit("/", 1)[0] if "/" in rel else ""
    if directory and (f"'{directory}/*.lua'" in text or f'"{directory}/*.lua"' in text):
        return True
    return False


def orphans(resources: list[Path]) -> list[str]:
    found = []
    for resource in resources:
        text = manifest_text(resource)
        for path in sorted(resource.rglob("*.lua")):
            rel = path.relative_to(resource).as_posix()
            if path.name in MANIFESTS or path.name.startswith("_"):
                continue
            if any(part in NON_RUNTIME_DIRS for part in path.relative_to(resource).parts[:-1]):
                continue
            if not listed(rel, text):
                found.append(f"{resource.name}/{rel}")
    return found


def custom_resources() -> list[Path]:
    return sorted(p for p in CUSTOM.iterdir() if p.is_dir())


def test_no_orphan_scripts_in_custom():
    found = orphans(custom_resources())
    assert not found, (
        "这些脚本没被自己的 fxmanifest 加载（资源拆分后的残骸，或被误当成运行时文件）：\n  "
        + "\n  ".join(found)
        + "\n\n要么加进清单，要么删掉；临时文件用 `_` 前缀，测试用 tests/ 目录。")


def test_every_custom_resource_has_a_manifest():
    missing = [r.name for r in custom_resources() if not manifest_text(r)]
    assert not missing, "这些资源目录没有 fxmanifest：" + ", ".join(missing)


def test_rules_fire_on_bad_shapes(tmp_path: Path):
    res = tmp_path / "custom-demo"
    res.mkdir()
    (res / "fxmanifest.lua").write_text(
        "fx_version 'cerulean'\nserver_scripts {\n    'server/main.lua',\n}\n", encoding="utf-8")
    (res / "server").mkdir()
    (res / "server" / "main.lua").write_text("-- loaded\n", encoding="utf-8")
    (res / "server" / "dead.lua").write_text("-- orphan\n", encoding="utf-8")
    (res / "server" / "_probe.lua").write_text("-- temp\n", encoding="utf-8")
    (res / "tests").mkdir()
    (res / "tests" / "case.lua").write_text("-- test\n", encoding="utf-8")

    assert orphans([res]) == ["custom-demo/server/dead.lua"]

    # 通配覆盖后不再是孤儿
    (res / "fxmanifest.lua").write_text(
        "fx_version 'cerulean'\nserver_scripts {\n    'server/*.lua',\n}\n", encoding="utf-8")
    assert orphans([res]) == []
