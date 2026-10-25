"""DOCS-01 — agent 文件的层级契约（索引化、不重复、不漂移）。

约束模型见 ``docs/engineering/agent-operating-model.md``：根 ``AGENTS.md`` 是**索引**
（≤ 110 行），每个分区一份 ``AGENTS.md`` 只写"这一层的约束"。这条闸门守三件事：

1. 根文件必须**登记**每一份分区文件——否则 agent 读不到它，规则等于没写；
2. 分区文件必须有固定小节（唯一入口 / 禁止 / 改动前必读 / 验收命令），
   缺任何一个都说明它退化成了随笔；
3. ``CLAUDE.md`` 只能是**指针**（≤ 20 行）。它和 ``AGENTS.md`` 各写一份规则时，
   两份必然分叉，而分叉比没有规则更危险。

含反向校验：把错误形状喂进判定函数，规则必须报红。

Run: ``python3 -m pytest -q tests/architecture/test_agent_docs.py``
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
REPO = BASE.parent
ROOT_DOC = REPO / "AGENTS.md"
CLAUDE = REPO / "CLAUDE.md"
CONSTITUTION = REPO / "docs" / "engineering" / "CONSTITUTION.md"

IGNORED_DIRS = {"node_modules", ".git", "alpine", "txData", "cache"}


def area_docs() -> list[Path]:
    """动态发现所有分区 AGENTS.md（根文件除外）。

    这里必须**发现**而不是写死清单：写死的清单挡不住"新加了一份没人注册的
    AGENTS.md"——那正是注入测试抓到的漏洞（新增文件应该红，结果绿）。
    """
    docs = []
    for path in REPO.rglob("AGENTS.md"):
        if path == ROOT_DOC or IGNORED_DIRS & set(path.relative_to(REPO).parts):
            continue
        docs.append(path)
    return sorted(docs)


AREA_DOCS = area_docs()

ROOT_MAX_LINES = 110
CLAUDE_MAX_LINES = 20
REQUIRED_SECTIONS = ("唯一入口", "禁止", "改动前必读", "验收命令")


def line_count(text: str) -> int:
    return len(text.splitlines())


def missing_sections(text: str, required=REQUIRED_SECTIONS) -> list[str]:
    return [name for name in required if not re.search(rf"^##+\s+.*{re.escape(name)}", text, re.M)]


def unregistered_docs(root_text: str, docs=None) -> list[str]:
    """`docs` 不能写成默认生成器：生成器只能被消费一次，第二次调用会静默返回空（假绿）。"""
    docs = [str(p.relative_to(REPO)) for p in area_docs()] if docs is None else list(docs)
    missing = []
    for rel in docs:
        tail = rel.split("resources/")[-1] if "resources/" in rel else rel
        if rel not in root_text and tail not in root_text:
            missing.append(rel)
    return missing


def claude_is_pointer(text: str) -> list[str]:
    problems = []
    if "AGENTS.md" not in text:
        problems.append("CLAUDE.md 没有指向 AGENTS.md")
    if line_count(text) > CLAUDE_MAX_LINES:
        problems.append(f"CLAUDE.md 有 {line_count(text)} 行，应 ≤ {CLAUDE_MAX_LINES}（它是指针，不是规则文件）")
    return problems


def constitution_rows(text: str) -> int:
    # 条数以表格行计数（第 1 列是编号）
    return len(re.findall(r"^\|\s*\d+\s*\|", text, re.M))


def constitution_landings_missing(text: str) -> list[str]:
    """每条条款的"落点"列里提到的路径必须真实存在。"""
    missing = []
    for cell in re.findall(r"\|\s*`([^`]+)`\s*\|\s*$", text, re.M):
        cand = cell.split("::")[0].lstrip("./")
        roots = (REPO, BASE, BASE / "tests" / "architecture")
        if not any((r / cand).exists() for r in roots):
            missing.append(cell)
    return missing


def test_root_agents_doc_is_an_index():
    text = ROOT_DOC.read_text(encoding="utf-8")
    assert line_count(text) <= ROOT_MAX_LINES, (
        f"根 AGENTS.md 有 {line_count(text)} 行，超过 {ROOT_MAX_LINES}："
        "把细节下沉到分区文件，根文件只留索引"
    )


def test_every_area_doc_is_registered_in_the_root_index():
    root = ROOT_DOC.read_text(encoding="utf-8")
    missing = unregistered_docs(root)
    assert not missing, "根索引没有登记这些分区文件（agent 找不到它们）：\n" + "\n".join(missing)


def test_no_orphan_agents_doc_exists():
    """仓库里任何 AGENTS.md 都必须在根索引登记——包括以后新增的那些。"""
    root = ROOT_DOC.read_text(encoding="utf-8")
    orphans = [str(p.relative_to(REPO)) for p in area_docs()
               if str(p.relative_to(REPO)) not in root and str(p.relative_to(BASE)) not in root]
    assert not orphans, "这些 AGENTS.md 没有在根索引登记（agent 不会读到）：\n" + "\n".join(orphans)


def test_area_docs_keep_the_fixed_sections():
    problems = []
    assert area_docs(), "一份分区 AGENTS.md 都没有？范围被改坏了"
    for path in area_docs():
        assert path.is_file(), f"缺少分区文件：{path.relative_to(REPO)}"
        for name in missing_sections(path.read_text(encoding="utf-8")):
            problems.append(f"{path.relative_to(REPO)}: 缺少小节「{name}」")
    assert not problems, "\n".join(problems)


def test_area_docs_stay_small():
    problems = [
        f"{p.relative_to(REPO)}: {line_count(p.read_text(encoding='utf-8'))} 行"
        for p in area_docs()
        if line_count(p.read_text(encoding="utf-8")) > 120
    ]
    assert not problems, "分区文件超过 120 行，说明内容该拆或该下沉：\n" + "\n".join(problems)


def test_claude_md_is_only_a_pointer():
    problems = claude_is_pointer(CLAUDE.read_text(encoding="utf-8"))
    assert not problems, "; ".join(problems)


def test_constitution_has_ten_clauses_with_real_landings():
    text = CONSTITUTION.read_text(encoding="utf-8")
    assert constitution_rows(text) == 10, f"宪法应为 10 条，实际 {constitution_rows(text)} 条"
    missing = constitution_landings_missing(text)
    assert not missing, "宪法条款的落点不存在（写了也就没人能验证）：\n" + "\n".join(missing)


def test_root_index_links_only_to_existing_files():
    """根索引里出现的反引号路径必须真的存在（解析依据：仓库根 或 T-CityLite.base）。"""
    text = ROOT_DOC.read_text(encoding="utf-8")
    missing = []
    for token in re.findall(r"`([^`\s]+)`", text):
        if any(ch in token for ch in "{}*<>|$…") or token.startswith(("http", "-", "git", "pytest", "npm", "node", "python", "luac", "screen", "tcity", "tail", "cd ")):
            continue
        if "/" not in token:                      # 裸文件名是"名字"，不是路径引用
            continue
        if not re.search(r"\.(md|lua|py|json|sql|ts|svelte|cfg|sh|mjs)$", token):
            continue
        if not (REPO / token).exists() and not (BASE / token).exists():
            missing.append(token)
    assert not missing, "根索引引用了不存在的文件：\n" + "\n".join(sorted(set(missing)))


# ---------------------------------------------------------------------------
# 反向校验：判定函数必须能抓住错误形状
# ---------------------------------------------------------------------------


def test_rules_fire_on_bad_shapes():
    # 1) 未登记的分区文件
    assert unregistered_docs("根索引只有这一句话")
    assert not unregistered_docs(
        "\n".join(str(p.relative_to(REPO)) for p in area_docs())
    )

    # 2) 缺小节
    assert missing_sections("## 范围\n## 禁止\n")
    assert not missing_sections("## 唯一入口\n## 禁止\n## 改动前必读\n## 验收命令\n")

    # 3) CLAUDE.md 写成了规则文件
    assert claude_is_pointer("# CLAUDE.md\n" + "\n".join(["规则"] * 40))
    assert not claude_is_pointer("# CLAUDE.md\n见 AGENTS.md\n")

    # 4) 宪法的落点不存在
    assert constitution_landings_missing("| 1 | x | y | `does/not/exist.py` |")
    assert not constitution_landings_missing("| 1 | x | y | `docs/engineering/CONSTITUTION.md` |")
