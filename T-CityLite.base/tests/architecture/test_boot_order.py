"""P2-2 闸门：启动顺序必须可校验，而不是活在注释里。

背景：`server.cfg` 是 gitignored，`exec configs/modules/*.cfg` 的顺序只活在那份本地文件；模块 cfg 里的
顺序约束（"core-framework 依赖 production-freeze，排在两者之间"）只活在注释里。删掉注释、换台机器，
顺序就没人知道了 —— 而错序的症状是"资源起不来"或"启动时机不对（exports 还没注册）"，只在真机暴露。

判据（`tools/dev/boot_cfg.py` 的 `check()`）：
  1. `configs/boot.json` 与 `configs/modules/*.cfg` 一一对应（不漏、不多、不重复）；
  2. 每条 `ensure` 指向真实存在的资源（FiveM 内置的除外），且同一资源只 ensure 一次；
  3. **依赖必须先于使用**：按 fxmanifest 的 `dependency` / `depend` 逐个校验位置；
  4. 可选的本地 `server.cfg` exec 顺序核对（那份文件不入库，CI 不做）。

反向形状都构造在同一条校验逻辑上，所以"删掉注释"不影响判定 —— 这正是一条断言。
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, (REPO / "tools" / "dev").as_posix())

import boot_cfg  # noqa: E402

BASE = REPO / "T-CityLite.base"


# ══════════════════════════════════════════════════════════════════
# 正向：真实仓库
# ══════════════════════════════════════════════════════════════════

def test_real_boot_order_respects_manifest_dependencies():
    problems = boot_cfg.check()
    assert not problems, "启动顺序有问题：\n  - " + "\n  - ".join(problems)

    # boot.json 与模块目录一一对应（不漏、不多）
    order, optional = boot_cfg.boot_modules()
    on_disk = {path.name for path in (BASE / "configs" / "modules").glob("*.cfg")}
    assert set(order) | set(optional) == on_disk, (
        f"boot.json 与模块目录不一致：只在磁盘={sorted(on_disk - set(order) - set(optional))} "
        f"只在 boot.json={sorted((set(order) | set(optional)) - on_disk)}"
    )

    # 本地有 server.cfg 时顺带核对 exec 顺序（该文件不入库，CI 上没有）
    server_cfg = BASE / "server.cfg"
    if server_cfg.exists():
        mismatch = boot_cfg.check(server_cfg=server_cfg)
        assert not mismatch, "本地 server.cfg 与 boot.json 不一致：\n  - " + "\n  - ".join(mismatch)
# ══════════════════════════════════════════════════════════════════
# 反向形状
# ══════════════════════════════════════════════════════════════════

def _fixture(tmp_path: Path, *, modules: dict[str, str], boot_modules: list[str],
             deps: dict[str, list[str]] | None = None) -> tuple[Path, Path, Path]:
    """搭一棵最小树：boot.json + modules/*.cfg + resources/<res>/fxmanifest.lua。"""
    configs = tmp_path / "configs"
    mod_dir = configs / "modules"
    mod_dir.mkdir(parents=True)
    resources = tmp_path / "resources"
    resources.mkdir()

    for name, body in modules.items():
        (mod_dir / name).write_text(body, encoding="utf-8")
    (configs / "boot.json").write_text(
        json.dumps({"modules": boot_modules}, ensure_ascii=False), encoding="utf-8")

    for name, requirements in (deps or {}).items():
        directory = resources / name
        directory.mkdir()
        block = "".join(f"    '{dep}',\n" for dep in requirements)
        (directory / "fxmanifest.lua").write_text(
            f"fx_version 'cerulean'\ngame 'gta5'\ndependencies {{\n{block}}}\n", encoding="utf-8")
    return configs / "boot.json", mod_dir, resources


def test_reverse_dependency_after_user_is_detected(tmp_path):
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure core\nensure consumer\n"},
        boot_modules=["a.cfg"],
        deps={"core": [], "consumer": ["core"]},
    )
    # 每行都带"顺序说明"，但没有注释能救 —— 判据看的是位置
    (mods / "a.cfg").write_text(
        "# 顺序说明：core 必须在 consumer 之前（历史原因）\nensure consumer\nensure core\n",
        encoding="utf-8",
    )
    problems = boot_cfg.check(boot=boot, modules=mods, resources=res)
    assert any("排在它后面" in p for p in problems), problems


def test_reverse_order_comment_alone_cannot_mask_wrong_order(tmp_path):
    """DoD 原话：删掉顺序注释后闸门仍能拦住错序 —— 反过来，注释写对了也不能掩盖错序。"""
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "# core 先于 consumer（注释齐全）\nensure consumer\nensure core\n"},
        boot_modules=["a.cfg"],
        deps={"consumer": ["core"], "core": []},
    )
    assert boot_cfg.check(boot=boot, modules=mods, resources=res)


def test_reverse_duplicate_ensure_is_detected(tmp_path):
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure core\n", "b.cfg": "ensure core\n"},
        boot_modules=["a.cfg", "b.cfg"],
        deps={"core": []},
    )
    problems = boot_cfg.check(boot=boot, modules=mods, resources=res)
    assert any("被 ensure 了两次" in p for p in problems), problems


def test_reverse_unknown_resource_is_detected(tmp_path):
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure core\nensure ghost\n"},
        boot_modules=["a.cfg"],
        deps={"core": []},
    )
    problems = boot_cfg.check(boot=boot, modules=mods, resources=res)
    assert any("ghost" in p for p in problems), problems


def test_reverse_unlisted_module_file_is_detected(tmp_path):
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure core\n", "forgotten.cfg": "ensure core\n"},
        boot_modules=["a.cfg"],
        deps={"core": []},
    )
    problems = boot_cfg.check(boot=boot, modules=mods, resources=res)
    assert any("forgotten.cfg" in p for p in problems), problems


def test_reverse_missing_dependency_from_sequence_is_detected(tmp_path):
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure consumer\n"},
        boot_modules=["a.cfg"],
        deps={"consumer": ["core"]},
    )
    problems = boot_cfg.check(boot=boot, modules=mods, resources=res)
    assert any("启动序列里没有它" in p for p in problems), problems


def test_reverse_server_cfg_mismatch_is_detected(tmp_path):
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure core\n", "b.cfg": ""},
        boot_modules=["a.cfg", "b.cfg"],
        deps={"core": []},
    )
    server_cfg = tmp_path / "server.cfg"
    server_cfg.write_text("exec configs/modules/b.cfg\nexec configs/modules/a.cfg\n", encoding="utf-8")
    problems = boot_cfg.check(boot=boot, modules=mods, resources=res, server_cfg=server_cfg)
    assert any("exec 顺序与 boot.json 不一致" in p for p in problems), problems


def test_reverse_nested_resource_layout_is_supported(tmp_path):
    """资源在 `[qb]/qb-core` 这类子目录里，依赖校验照样要生效。"""
    boot, mods, res = _fixture(
        tmp_path,
        modules={"a.cfg": "ensure consumer\nensure core\n"},
        boot_modules=["a.cfg"],
        deps={},
    )
    for name in ("core", "consumer"):
        directory = res / "[qb]" / name
        directory.mkdir(parents=True)
        deps_block = "dependencies { 'core' }" if name == "consumer" else ""
        (directory / "fxmanifest.lua").write_text(
            f"fx_version 'cerulean'\n{deps_block}\n", encoding="utf-8")
    assert boot_cfg.check(boot=boot, modules=mods, resources=res)
