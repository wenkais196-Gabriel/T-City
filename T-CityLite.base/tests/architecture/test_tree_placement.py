"""TREE-01 — 新文件必须放在 `docs/engineering/TREE.md` §2 决策树指定的位置。

为什么这条闸门只判「新增 / 重命名」：
存量有历史原因（`T-CityLite.base/tests/` 根 18 个 lua、base docs 根 40 篇），
一次性判它们会逼着在同一天做一次大搬迁，而大搬迁的 review 成本会把规则本身拖死。
所以口径是「从今天起新增的必须放对」，存量按 `TREE.md` §7 登记、分批处理。

判据来源：`git diff --name-only --diff-filter=AR <base>...HEAD`。
- PR 构建：`GITHUB_BASE_REF` → fetch 后与该 base 比；
- 本地/其他：退回 `HEAD^`（只看最近一次提交）；
- 两者都拿不到（浅克隆且首提交）：**skip 并说明**——不是放行，是这条闸门在该环境不可判定。

含反向校验：把错误形状喂进 `verdict()`，规则必须报红（`tests/AGENTS.md` 要求）。
它拦不住什么，逐条写在 `TREE.md` §6——那份清单和这条闸门同等重要。

Run: ``python3 -m pytest -q tests/architecture/test_tree_placement.py``
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path, PurePosixPath

import pytest

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
REPO = Path(__file__).resolve().parents[3]          # 仓库根

# `T-CityLite.base/tests/` 根允许出现的可执行文件名（TREE.md §3）。
# 进这张表 = 改 TREE.md + 改这里，同 PR，带理由。
ROOT_PY_ALLOW = {
    "check_cfgs.py",
    "check_dependencies.py",
    "check_bus_wiring.py",
    "check_db_schema.py",
    "check_lua_syntax.py",
    "light_lint.py",
    "conftest.py",
    "run_all.py",
    "p0_sources.py",
}
ROOT_SH_ALLOW = {"run_db_tests.sh"}

# 资源类别（`ensure` 只认资源名，但类别目录本身是约定；新增类别会让 conftest 找不到资源）。
KNOWN_CATEGORIES = {
    "[custom]",
    "[qb]",
    "[standalone]",
    "[system]",
    "[cfx-default]",
    "[compat]",
    "[defaultmaps]",
    "[voice]",
}

# 版本号 / 副本进了文件名（TREE.md §4；doc-lifecycle.md §3 同义）。
VERSIONED = re.compile(r"_v\d+|[-_](?:final|new)(?=[.\-_]|$)|副本", re.IGNORECASE)
# 文件名里的日期：只有 audit/research 类型才允许（快照才需要日期）。
DATE_IN_NAME = re.compile(r"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)")
SNAPSHOT_TYPES = {"audit", "research"}


def frontmatter_type(text: str) -> str | None:
    """从扁平 YAML frontmatter 里取 `type`（不引入 YAML 依赖，与 docs_lifecycle.py 同口径）。"""
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end < 0:
        return None
    for line in text[3:end].splitlines():
        stripped = line.strip()
        if stripped.startswith("type:"):
            return stripped.split(":", 1)[1].strip().strip("\"'")
    return None


def verdict(rel: str, text: str | None = None) -> str | None:
    """返回 None = 放对了；返回 str = 放错了的理由。纯函数，可被反向校验直接调用。

    `text` 只在文件名带日期时需要（用来判断 frontmatter 的 `type`）；不传则跳过该条，
    避免把「读不到内容」误判成违规。
    """
    p = PurePosixPath(rel)
    name = p.name

    if VERSIONED.search(name.lower()):
        return "版本号/副本不进文件名（版本由 git 承载）"

    if p.suffix == ".md" and DATE_IN_NAME.search(name) and text is not None:
        if frontmatter_type(text) not in SNAPSHOT_TYPES:
            return "文件名带日期，但 type 不是 audit/research（日期只给快照用）"

    tests_root = PurePosixPath("T-CityLite.base/tests")
    if p.parent == tests_root:
        if p.suffix in {".lua", ".js"}:
            return "测试脚本必须进 tests/game/（控制台 exec）、tests/lua/（裸 lua5.4）或 tests/js/（node）"
        if p.suffix == ".py" and p.name not in ROOT_PY_ALLOW:
            return "新增 pytest/检查脚本放 tests/ 子目录；只有 TREE.md §3 白名单能留根"
        if p.suffix == ".sh" and p.name not in ROOT_SH_ALLOW:
            return "新增 shell 检查脚本放 tests/ 子目录或 tools/dev/"

    if p.parent == PurePosixPath("T-CityLite.base/docs") and p.suffix == ".md":
        return "新文档放 T-CityLite.base/docs/ 的已有子目录（agent/ standards/ architecture/ design/ systems/ audit/ archive/）"

    parts = p.parts
    if len(parts) > 3 and parts[0] == "T-CityLite.base" and parts[1] == "resources":
        if parts[2] not in KNOWN_CATEGORIES:
            return f"资源类别 {parts[2]} 不在白名单（新增类别会让 conftest.resolve_resource 找不到资源）"

    return None


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True)


def changed_paths() -> list[str] | None:
    """本次新增/重命名的文件；无法判定时返回 None（调用方 skip 并写明原因）。"""
    base_ref = os.environ.get("GITHUB_BASE_REF") or os.environ.get("TREE_BASE_REF")
    if base_ref:
        fetched = _git("fetch", "--no-tags", "--depth=1", "origin", base_ref)
        if fetched.returncode != 0:
            return None
        ref = f"origin/{base_ref}"
        # 浅克隆下可能没有 merge-base，退回两点比较（PR 分支通常直接基于 base）。
        diff = _git("diff", "--name-only", "--diff-filter=AR", f"{ref}...HEAD")
        if diff.returncode != 0:
            diff = _git("diff", "--name-only", "--diff-filter=AR", ref, "HEAD")
        if diff.returncode != 0:
            return None
        # CI 里工作树是干净的，只判提交差异。
        return [line for line in diff.stdout.splitlines() if line.strip()]

    # 本地：判"最近一次提交 + 已暂存 + 未暂存 + 未跟踪"，否则新增文件在提交前永远看不见，
    # 反向注入也验不了（第一版就踩了这个坑）。
    paths: set[str] = set()
    if _git("rev-parse", "--verify", "HEAD^").returncode == 0:
        committed = _git("diff", "--name-only", "--diff-filter=AR", "HEAD^...HEAD")
        if committed.returncode == 0:
            paths.update(p for p in committed.stdout.splitlines() if p.strip())
    pending = _git("diff", "--name-only", "--diff-filter=AR", "HEAD")
    if pending.returncode == 0:
        paths.update(p for p in pending.stdout.splitlines() if p.strip())
    untracked = _git("ls-files", "--others", "--exclude-standard")
    if untracked.returncode == 0:
        paths.update(p for p in untracked.stdout.splitlines() if p.strip())
    return sorted(paths) if paths else ([] if _git("rev-parse", "--verify", "HEAD").returncode == 0 else None)


def test_new_and_renamed_files_are_placed_correctly():
    paths = changed_paths()
    if paths is None:
        pytest.skip("拿不到 base ref（浅克隆/首个提交）——本环境无法判定新增文件位置")

    bad = {}
    for rel in paths:
        text = None
        if rel.endswith(".md"):
            target = REPO / rel
            if target.is_file():
                text = target.read_text(encoding="utf-8", errors="ignore")
        why = verdict(rel, text)
        if why:
            bad[rel] = why
    assert not bad, "新文件放错位置（判据见 docs/engineering/TREE.md §2）：\n" + "\n".join(
        f"  {p}: {why}" for p, why in sorted(bad.items())
    )


# --- 反向校验：错误形状必须红、正确形状必须绿 -------------------------------


def test_reverse_check_rejects_lua_in_tests_root():
    assert verdict("T-CityLite.base/tests/foo_test.lua"), "tests/ 根的 .lua 必须被判红"


def test_reverse_check_accepts_lua_in_lane_directories():
    for rel in (
        "T-CityLite.base/tests/game/foo_test.lua",
        "T-CityLite.base/tests/lua/foo_test.lua",
        "T-CityLite.base/tests/js/foo.js",
    ):
        assert verdict(rel) is None, f"{rel} 应在允许的位置"


def test_reverse_check_rejects_unknown_py_in_tests_root():
    assert verdict("T-CityLite.base/tests/random_check.py"), "tests/ 根的新 .py 不在白名单必须判红"


def test_reverse_check_accepts_allowlisted_root_scripts():
    for name in sorted(ROOT_PY_ALLOW):
        assert verdict(f"T-CityLite.base/tests/{name}") is None, f"{name} 是白名单内的根脚本"


def test_reverse_check_rejects_root_md_in_base_docs():
    assert verdict("T-CityLite.base/docs/new-note.md"), "base docs 根的新 .md 必须判红"


def test_reverse_check_accepts_md_in_base_docs_subdir():
    for rel in (
        "T-CityLite.base/docs/standards/new-note.md",
        "T-CityLite.base/docs/archive/new-note.md",
        "T-CityLite.base/docs/agent/new-note.md",
    ):
        assert verdict(rel) is None, f"{rel} 应在允许的位置"


def test_reverse_check_rejects_unknown_resource_category():
    assert verdict("T-CityLite.base/resources/[dev]/whatever/fxmanifest.lua"), "新类别目录必须判红"


def test_reverse_check_accepts_known_resource_categories():
    for cat in sorted(KNOWN_CATEGORIES):
        assert verdict(f"T-CityLite.base/resources/{cat}/res/fxmanifest.lua") is None, cat


def test_reverse_check_rejects_versioned_filenames():
    for rel in (
        "T-CityLite.base/tests/lua/simulate_aviation_routes_v3.lua",
        "docs/plan/hotdog-final.md",
        "docs/plan/x副本.md",
    ):
        assert verdict(rel), f"{rel} 带版本号/副本，必须判红"


def test_reverse_check_rejects_date_named_doc_that_is_not_a_snapshot():
    spec_like = "---\nid: x\ntype: spec\nstatus: active\n---\n\n# x\n"
    assert verdict("docs/plan/2026-11-16-tree-standard.md", spec_like), "带日期但 type=spec 必须判红"


def test_reverse_check_accepts_date_named_snapshot():
    audit_like = "---\nid: x\ntype: audit\nstatus: final\n---\n\n# x\n"
    assert verdict("docs/analysis/2026-11-16-survey.md", audit_like) is None


def test_reverse_check_accepts_clean_documented_paths():
    assert verdict("docs/plan/tree-standard.md") is None
    assert verdict("T-CityLite.base/docs/agent/reviews/09-contract-ci.md") is None
