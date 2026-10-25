"""DOCS-02 — 活跃文档里引用的路径必须真实存在；历史归档显式豁免。

范围变了两次，记下来免得后人再走一遍：

1. 最初只查 ``docs/engineering/**`` + ``docs/agent/**``——安全，但大量文档是盲区；
2. 后来按目录逐个收编（client / analysis / server-design）——每次都要改闸门代码，
   而且"没收编的目录"和"修好的目录"在报告里长得一样，看不出还欠多少；
3. 现在改成**默认全覆盖 + 显式豁免**：全仓所有 ``*.md`` 都要零断链，唯一例外是
   带 ``LEGACY.md`` 标记的历史归档目录，且这些目录必须登记在 ``legacy_docs.json`` 里。

双向校验很关键：
- 有标记但没登记 → 红（不许自己偷偷把目录标成历史以逃避闸门）；
- 登记了但没标记／目录没了 → 红（豁免不许烂在表里）。

历史归档不修引用是有意的：那些文档描述的是当时的状态，把路径改成今天的会伪造历史。
新文档不要写进归档目录；要引用其中结论，就把结论抄进活跃文档并注明出处文件名。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
REGISTRY = Path(__file__).resolve().parent / "legacy_docs.json"
MARKER = "LEGACY.md"
IGNORED_DIRS = {"node_modules", ".git", "alpine", "txData", "cache", ".venv"}

PATH_TOKEN = re.compile(r"`([^`\s]+)`")
PATH_SUFFIXES = (".md", ".lua", ".py", ".json", ".sql", ".ts", ".svelte", ".cfg", ".sh", ".mjs", ".js", ".html")
SKIP_CHARS = set("{}*<>|$…\u3000")
PLACEHOLDERS = ("[name]", "[hash]", "[res]", "[area]", "[slug]", "[topic]", "[date]", "[x]")


def looks_like_path(token: str) -> bool:
    if any(ch in token for ch in SKIP_CHARS):
        return False
    if any(ph in token for ph in PLACEHOLDERS):   # [name]-[hash].js 这类是构建占位，不是路径
        return False
    if "/" not in token:                          # 裸文件名在文档里当"名字"用，不校验存在性
        return False
    if token.startswith(("http", "www", "~", "/dev", "/tmp", "/etc", "pip", "npm", "node ", "git ", "python")):
        return False
    if " " in token or token.startswith("-"):
        return False
    return token.endswith(PATH_SUFFIXES)


def resolve(token: str, doc: Path) -> bool:
    token = token.split("::")[0].split("#")[0]
    for root in (REPO, BASE, doc.parent, REPO / "docs"):
        if (root / token).exists():
            return True
    return False


def broken_links(text: str, doc: Path) -> list[str]:
    return [t for t in {m.group(1) for m in PATH_TOKEN.finditer(text)} if looks_like_path(t) and not resolve(t, doc)]


def registered_legacy() -> dict[str, dict]:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))["dirs"]


def legacy_dirs() -> set[Path]:
    return {REPO / rel for rel in registered_legacy()}


def is_legacy(path: Path, dirs: set[Path]) -> bool:
    return any(path == d or d in path.parents for d in dirs)


def marked_dirs() -> set[Path]:
    """仓库里所有带 LEGACY.md 的目录（含被标记目录的子目录也会命中，取父目录去重后判断）。"""
    found = set()
    for marker in REPO.rglob(MARKER):
        if IGNORED_DIRS & set(marker.parts):
            continue
        found.add(marker.parent)
    return found


def active_docs() -> list[Path]:
    dirs = legacy_dirs()
    return sorted(
        p for p in REPO.rglob("*.md")
        if p.is_file() and not (IGNORED_DIRS & set(p.parts)) and not is_legacy(p, dirs)
    )


# ---------------------------------------------------------------------------
# 正题
# ---------------------------------------------------------------------------

def test_active_docs_have_no_broken_paths():
    problems = []
    for doc in active_docs():
        for token in broken_links(doc.read_text(encoding="utf-8"), doc):
            problems.append(f"{doc.relative_to(REPO)}: {token}")
    assert not problems, (
        "活跃文档引用了不存在的路径。修法：指向新位置；若文件已删除，改写成不带反引号的叙述；"
        "历史文档请移到带 LEGACY.md 的归档目录。\n  " + "\n  ".join(problems))


def test_scope_is_not_empty():
    """防止"扫描范围为空 → 永远绿"这种假绿。"""
    docs = active_docs()
    assert len(docs) >= 150, f"活跃文档只有 {len(docs)} 份，范围被改坏了？"


def test_every_legacy_marker_is_registered():
    unregistered = sorted(str(p.relative_to(REPO)) for p in marked_dirs() - legacy_dirs())
    assert not unregistered, (
        "这些目录带了 LEGACY.md 但没登记在 legacy_docs.json："
        + ", ".join(unregistered) + "\n豁免必须显式登记（含理由），不能自己贴个标记就跳过闸门。")


def test_every_registered_legacy_dir_still_exists_and_is_marked():
    stale = []
    for rel in registered_legacy():
        d = REPO / rel
        if not d.is_dir():
            stale.append(f"{rel}: 目录不存在")
        elif not (d / MARKER).is_file():
            stale.append(f"{rel}: 缺少 {MARKER}")
    assert not stale, "豁免表里的目录已失效，请删掉对应登记：\n  " + "\n  ".join(stale)


def test_every_legacy_entry_has_a_reason():
    missing = [rel for rel, meta in registered_legacy().items() if not str(meta.get("reason", "")).strip()]
    assert not missing, "历史归档必须写理由：" + ", ".join(missing)


def test_legacy_dirs_are_not_the_majority():
    """归档可以存在，但不能变成默认——活跃文档要远多于归档文档。"""
    dirs = legacy_dirs()
    archived = [p for p in REPO.rglob("*.md")
                if p.is_file() and not (IGNORED_DIRS & set(p.parts)) and is_legacy(p, dirs)]
    active = active_docs()
    assert len(archived) < len(active), (
        f"归档 {len(archived)} 份 ≥ 活跃 {len(active)} 份——归档正在变成默认，" 
        "检查是不是有人把目录错标成 LEGACY。")


# ---------------------------------------------------------------------------
# 反向校验
# ---------------------------------------------------------------------------

def test_rules_fire_on_bad_shapes(tmp_path: Path):
    doc = REPO / "AGENTS.md"
    assert broken_links("见 `docs/engineering/does-not-exist.md`", doc)
    assert not broken_links("见 `docs/engineering/CONSTITUTION.md`", doc)
    for token in ("`docs/<area>/plans/x.md`", "`assets/[name]-[hash].js`", "`https://example.com/x.md`"):
        assert not looks_like_path(token.strip("`"))
    assert not broken_links("`CONSTITUTION.md`", REPO / "docs" / "engineering" / "x.md")

    # 豁免只对登记目录生效，且覆盖子目录
    reg = {REPO / "docs/police"}
    assert is_legacy(REPO / "docs/police/x.md", reg)
    assert is_legacy(REPO / "docs/police/deep/x.md", reg)
    assert not is_legacy(REPO / "docs/police2/x.md", reg), "前缀相近的目录不许被误豁免"
    assert not is_legacy(REPO / "docs/engineering/x.md", reg)
