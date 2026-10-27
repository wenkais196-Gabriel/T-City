"""OPS-04 — 重启不丢数据这件事必须有证据，不能靠"看起来还在"。

`core-framework/services/persistence_manager.lua` 用 LOCAL `DirtyFlush` 绕开了
`_G.DirtyFlush` 被清空的问题，但**没有回归证据**证明 `kill -9` + 重启之后玩家的钱、职业、
背包、容器还在。`tools/ops/persistence_check.py` 用快照对比补上这条证据。

这里的规则全是反向形状：坏快照必须被检出，而且不能因为行序不同就误报。

    python3 -m pytest -q tests/architecture/test_ops_persistence.py
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "ops" / "persistence_check.py"


def _load_module():
    assert TOOL.is_file(), f"缺少工具: {TOOL}"
    spec = importlib.util.spec_from_file_location("ops_persistence_check", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ops_persistence_check", module)
    spec.loader.exec_module(module)
    return module


def _player(citizenid="ABC12345", cash=1200, bank=5000, job="police", grade=2, onduty=True, metadata=None):
    row = {
        "citizenid": citizenid,
        "cash": cash,
        "bank": bank,
        "job": job,
        "job_grade": grade,
        "onduty": onduty,
    }
    if metadata is not None:
        row["metadata"] = metadata
    return row


def test_diff_detects_money_job_inventory_metadata_and_stash_changes():
    """钱、职业、背包、metadata、容器——五类数据各改一处，每类都要报出来并点名主体。"""
    mod = _load_module()
    before = mod.snapshot(
        [dict(_player(), metadata={"bloodtype": "A+"})],
        [{"citizenid": "ABC12345", "item": "water", "amount": 3}],
        [{"identifier": "glovebox-04KJD627", "item": "lockpick", "amount": 2}],
    )
    after = mod.snapshot(
        [_player(cash=900, job="unemployed", grade=0, onduty=False,
                 metadata={"bloodtype": "AB-"})],
        [{"citizenid": "ABC12345", "item": "water", "amount": 2}],
        [],
    )
    diffs = mod.diff_snapshots(before, after)
    joined = "\n".join(diffs)

    assert "cash" in joined and "1200" in joined and "900" in joined, f"现金变化要报: {diffs}"
    assert "job" in joined, f"职业变化要报: {diffs}"
    assert "metadata" in joined or "bloodtype" in joined, f"metadata 变化要报: {diffs}"
    assert "物品 water" in joined, f"背包变化要报: {diffs}"
    assert "glovebox-04KJD627" in joined and "lockpick" in joined, f"容器变化要报: {diffs}"
    assert all(("ABC12345" in d) or ("glovebox" in d) for d in diffs), (
        f"每条差异都要点名主体: {diffs}"
    )


def test_diff_detects_missing_player_and_never_fires_on_identical_or_reordered_rows():
    """两种"不该报"的形状（完全相同、仅行序不同）必须安静；真缺失必须报"缺失"。"""
    mod = _load_module()
    items_a = [
        {"citizenid": "ABC12345", "item": "water", "amount": 3},
        {"citizenid": "ABC12345", "item": "pistol", "amount": 1},
    ]
    items_b = list(reversed(items_a))

    base = mod.snapshot([_player(), _player("XYZ99999")], items_a)
    assert mod.diff_snapshots(base, base) == [], "自己和自己比必须零差异"

    reordered = mod.snapshot([_player("XYZ99999"), _player()], items_b)
    assert mod.diff_snapshots(base, reordered) == [], "行序不同不是数据丢失，不能报红"

    shrunk = mod.snapshot([_player()], items_a)
    diffs = mod.diff_snapshots(base, shrunk)
    assert len(diffs) == 1, f"只应报一条缺失: {diffs}"
    assert "XYZ99999" in diffs[0] and "缺失" in diffs[0], f"要明确说玩家没了: {diffs[0]}"


def test_parser_detects_slot_map_and_sql_matches_real_schema():
    """解析器要认 {slot: item} 字典；SQL 必须对准真实表名/列名（inventories 的键是 identifier）。"""
    mod = _load_module()
    rows = mod._json_items('{"1": {"name": "water", "amount": 2}, "3": {"name": "bread"}}')
    assert [r["name"] for r in rows] == ["water", "bread"], rows
    assert mod._json_items("not json") == []

    source = TOOL.read_text(encoding="utf-8")
    assert "FROM players" in source, "玩家表查询不见了"
    assert "FROM inventories" in source, "容器表查询不见了"
    assert "identifier, items" in source, "inventories 的列是 identifier，不是 citizenid"
    assert "FROM inventory " not in source, "库里没有 inventory 这张表，别退回去"
