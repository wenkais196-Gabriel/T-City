"""DOCS-02 — 约束区文档里引用的路径必须真实存在。

范围**刻意收窄**：只检查 agent 真正会照着做的文档——根/分区 ``AGENTS.md`` 与
``docs/engineering/**``。全仓 351 份 md、2862 处路径引用里有大量历史文档，一次全量
收紧只会逼人加几百条豁免；先把"会被执行的那一层"钉死，其余用
``tools/dev/docs_links_report.py`` 出报告、逐步收编。

跳过判定：URL、命令、通配（``*``）、模板占位（``<x>``、``{a,b}``）、
以及明显不是路径的 token。反向校验保证"引用不存在的文件"一定会被抓到。

Run: ``python3 -m pytest -q tests/architecture/test_docs_links.py``
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
IGNORED_DIRS = {"node_modules", ".git", "alpine", "txData", "cache"}
CONSTRAINT_DIRS = [REPO / "docs" / "engineering"]

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


def constraint_docs() -> list[Path]:
    """范围 = 所有 AGENTS.md（动态发现）+ docs/engineering/**。"""
    docs = [
        p for p in REPO.rglob("AGENTS.md")
        if p.is_file() and not (IGNORED_DIRS & set(p.parts))
    ]
    for d in CONSTRAINT_DIRS:
        docs.extend(sorted(d.rglob("*.md")))
    return docs


def test_constraint_docs_have_no_broken_paths():
    problems = []
    for doc in constraint_docs():
        for token in broken_links(doc.read_text(encoding="utf-8"), doc):
            problems.append(f"{doc.relative_to(REPO)}: {token}")
    assert not problems, "约束区文档引用了不存在的路径（agent 会照着做）：\n" + "\n".join(problems)


def test_the_scope_is_not_empty():
    """防止"扫描范围为空 → 永远绿"这种假绿。"""
    docs = constraint_docs()
    assert len(docs) >= 5, f"约束区文档只有 {len(docs)} 份，范围被改坏了？"


def test_rules_fire_on_bad_shapes(tmp_path=None):
    doc = REPO / "AGENTS.md"
    assert broken_links("见 `docs/engineering/does-not-exist.md`", doc)
    assert not broken_links("见 `docs/engineering/CONSTITUTION.md`", doc)
    # 占位/通配/URL 不算路径
    for token in ("`docs/<area>/plans/x.md`", "`assets/[name]-[hash].js`", "`https://example.com/x.md`"):
        assert not looks_like_path(token.strip("`"))
    # 相对本文档目录也能解析
    assert not broken_links("`CONSTITUTION.md`", REPO / "docs" / "engineering" / "x.md")
