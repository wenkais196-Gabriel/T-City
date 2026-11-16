"""DOCS-03 — 计划文档的 `plan-status` 机器可读块必须先红后绿。

背景：计划正文里的「✅ 完成 / 🟡 进行中 / 待施工」是散文，`--check` 看不见，
于是「done 但没有任何可复核证据」和「真的做完了」在索引里长得一样。
这里给 `tools/docs_lifecycle.py --check` 补形状闸门：

- frontmatter 有 `plan_status: 1` ⇔ 正文有 ```plan-status 块（双向）；
- 每行 4 列；state ∈ {todo, wip, done}；date 合法；id 唯一且与正文切片表首列一致；
- `done` 的 ev 必须是单个 `#数字` 或仓内存在的相对路径；
  `ev: -` 或 PR 区间（`#289–#297`）**不算证据** —— 只报 `未取证` WARN，不阻断。

本文件自己就是反向校验：坏形状 → `--check` 退出码 1；`done` 无证据 → 输出 `未取证`。
测试用临时仓库跑真实的 `main()`，不碰本仓文档。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

TOOL = Path(__file__).resolve().parents[3] / "tools" / "docs_lifecycle.py"

SLICE_TABLE = """| 片 | 内容 |
|---|---|
| S1 | 第一片 |
| S2a | 第二片 |
"""

GOOD_BLOCK = """```plan-status
S1  | done | #302 | 2026-11-16
S2a | wip  | -    | -
```"""


def _doc(extra: str = "", block: str = GOOD_BLOCK, table: str = SLICE_TABLE) -> str:
    return f"""---
id: fixture-plan
type: plan
status: active
system: meta
updated: 2026-11-16
review_by: 2027-04-30
{extra}---

# 测试计划

## 1. 切片

{table}
{block}
"""


def _load_tool():
    spec = importlib.util.spec_from_file_location("docs_lifecycle_under_test", TOOL)
    assert spec and spec.loader, f"找不到工具：{TOOL}"
    module = importlib.util.module_from_spec(spec)
    sys.modules["docs_lifecycle_under_test"] = module
    spec.loader.exec_module(module)
    return module


def _run_check(tmp_path: Path, doc_text: str, monkeypatch, capsys, files=()):
    for rel in files:
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("proof\n", encoding="utf-8")
    doc = tmp_path / "docs" / "plan" / "fixture.md"
    doc.parent.mkdir(parents=True, exist_ok=True)
    doc.write_text(doc_text, encoding="utf-8")

    module = _load_tool()
    module.REPO = str(tmp_path)          # 让 iter_docs()/rel() 只看临时仓库
    monkeypatch.setattr(sys, "argv", ["docs_lifecycle.py", "--check"])
    code = module.main()
    return code, capsys.readouterr().out


BAD_CASES = [
    pytest.param("missing_block", "plan_status: 1\n", "", "缺少", id="missing-block"),
    pytest.param("missing_key", "", GOOD_BLOCK, "plan_status: 1", id="missing-key"),
    pytest.param(
        "three_columns", "plan_status: 1\n",
        "```plan-status\nS1 | done | #302\n```", "4 列", id="three-columns"),
    pytest.param(
        "illegal_state", "plan_status: 1\n",
        "```plan-status\nS1 | finished | #302 | 2026-11-16\n```", "state", id="illegal-state"),
    pytest.param(
        "id_not_in_slices", "plan_status: 1\n",
        "```plan-status\nS1 | done | #302 | 2026-11-16\nS3 | todo | - | -\n```",
        "切片 ID", id="id-not-in-slices"),
    pytest.param(
        "done_unverifiable_ev", "plan_status: 1\n",
        "```plan-status\nS1 | done | docs/does-not-exist.md | 2026-11-16\n"
        "S2a | wip | - | -\n```", "不可复核", id="done-unverifiable-ev"),
    pytest.param(
        "bad_date", "plan_status: 1\n",
        "```plan-status\nS1 | done | #302 | 2026-13-40\nS2a | wip | - | -\n```",
        "日期", id="bad-date"),
]


@pytest.mark.parametrize("case,extra,block,needle", BAD_CASES)
def test_plan_status_bad_shapes_are_rejects(
        case, extra, block, needle, tmp_path, monkeypatch, capsys):
    """坏形状必须让 `--check` 返回 1，并指出坏在哪一列/哪个 ID。"""
    code, out = _run_check(tmp_path, _doc(extra=extra, block=block), monkeypatch, capsys)
    assert code == 1, f"{case}: 期望 --check 退出码 1，实际 {code}\n{out}"
    assert needle in out, f"{case}: 输出里没有「{needle}」\n{out}"


def test_plan_status_unverified_done_detects_warning(tmp_path, monkeypatch, capsys):
    """`done` 但 ev 是 `-` / PR 区间 → `未取证` WARN，不阻断（退出码 0）。"""
    for ev in ("-", "#289–#297", "#289-#297"):
        block = f"""```plan-status
S1  | done | {ev} | 2026-11-16
S2a | wip  | - | -
```"""
        code, out = _run_check(
            tmp_path, _doc(extra="plan_status: 1\n", block=block), monkeypatch, capsys)
        assert code == 0, f"ev={ev}: WARN 不应阻断\n{out}"
        assert "未取证" in out, f"ev={ev}: 没有输出「未取证」\n{out}"


def test_indented_example_detects_no_real_block(tmp_path, monkeypatch, capsys):
    """规范/模板里 4 空格缩进的示例不是真实块：没有 `plan_status: 1` 也不该报错。"""
    block = """    ```plan-status
    S1 | todo | - | -
    S2a | todo | - | -
    ```"""
    code, out = _run_check(tmp_path, _doc(extra="", block=block), monkeypatch, capsys)
    assert code == 0, out
    assert "plan_status 开关" not in out, out


@pytest.mark.parametrize("ev", ["#302", "proof/evidence.txt"])
def test_plan_status_good_shape_detects_no_error(ev, tmp_path, monkeypatch, capsys):
    """合法块（PR 号或仓内路径）→ 0 error。"""
    block = f"""```plan-status
S1  | done | {ev} | 2026-11-16
S2a | wip  | - | -
```"""
    code, out = _run_check(
        tmp_path, _doc(extra="plan_status: 1\n", block=block),
        monkeypatch, capsys, files=("proof/evidence.txt",) if "/" in ev else ())
    assert code == 0, f"合法块被误判：\n{out}"
    assert "errors=0" in out, out


# ---------------------------------------------------------------- BOARD 新鲜度

def _run_tool(tmp_path: Path, argv: list[str], monkeypatch, capsys) -> tuple[int, str]:
    module = _load_tool()
    module.REPO = str(tmp_path)
    monkeypatch.setattr(sys, "argv", ["docs_lifecycle.py", *argv])
    code = module.main()
    return code, capsys.readouterr().out


def test_board_staleness_detects_injected_edit_and_missing_file(tmp_path, monkeypatch, capsys):
    """BOARD.md 是生成物：过期或手改，`--check` 必须报出来。

    真实故障（2026-11-16，PR #320 与 #321 交叉）：另一个 PR 把一份 plan 改名，
    BOARD 里那行链接指错，块校验全绿、看板却是错的。判据只有一条：重算 == 落盘。
    """
    doc = tmp_path / "docs" / "plan" / "fixture.md"
    doc.parent.mkdir(parents=True, exist_ok=True)
    doc.write_text(_doc(extra="plan_status: 1\n"), encoding="utf-8")

    code, out = _run_tool(tmp_path, ["--board"], monkeypatch, capsys)
    assert code == 0 and (tmp_path / "docs/plan/BOARD.md").exists(), out

    code, out = _run_tool(tmp_path, ["--check"], monkeypatch, capsys)
    assert "BOARD.md 不是最新" not in out, out
    assert "BOARD.md 不存在" not in out, out

    board = tmp_path / "docs/plan/BOARD.md"
    board.write_text(board.read_text(encoding="utf-8") + "\n| 手改一行 |\n", encoding="utf-8")
    code, out = _run_tool(tmp_path, ["--check"], monkeypatch, capsys)
    assert "BOARD.md 不是最新" in out, f"手改后没报：{out}"

    board.unlink()
    code, out = _run_tool(tmp_path, ["--check"], monkeypatch, capsys)
    assert "BOARD.md 不存在" in out, f"删掉后没报：{out}"
