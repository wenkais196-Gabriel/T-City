"""S5 结算账单：算式、A19 口径、幂等。

为什么要单独一组：
    账单是最容易「看起来对、其实多算一次」的地方。三条硬口径必须钉住：
      1. **售出不进净额**（A19）：卖热狗的钱在成交当时就以现金给玩家了，
         再算进净额等于同一笔钱数两遍；
      2. **押金不上税**：那是玩家自己的钱，不是收入；
      3. **同一张回执只开一次**：重复结算返回上一张并标 replayed，金额不翻倍。
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SETTLE = BASE / "resources/[custom]/custom-quest/server/quest_settle.lua"
PROBE = Path(__file__).with_name("fixtures") / "settle_probe.lua"
MANAGER = BASE / "resources/[custom]/custom-quest/server/quest_manager.lua"
MANIFEST = BASE / "resources/[custom]/custom-quest/fxmanifest.lua"

LUA = shutil.which("lua5.4")  # NOSONAR
RENTAL = BASE / "resources/[custom]/custom-quest/server/quest_rental.lua"


def run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],  # NOSONAR
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_bill_rules_hold():
    proc = run_probe(SETTLE)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 37/37" in proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_probe_goes_red_when_sold_starts_counting_into_net(tmp_path: Path):
    """反向校验：把「售出计入净额」写进去，探针必须红。

    这条守的是 A19 —— 也是这张账单最容易被"好心"改坏的地方
    （看见售出金额就想加进净额，结果玩家以为赚了两次）。
    """
    src = SETTLE.read_text(encoding="utf-8")
    assert "local net = money(deposit - rent + leftoverValue + rawValue - tax)" in src
    broken = src.replace(
        "local net = money(deposit - rent + leftoverValue + rawValue - tax)",
        "local net = money(deposit - rent + leftoverValue + rawValue - tax + soldTotal)", 1)
    target = tmp_path / "quest_settle_broken.lua"
    target.write_text(broken, encoding="utf-8")
    proc = run_probe(target)
    assert proc.returncode != 0, "售出计入净额后探针仍然全绿 —— 这条用例没在防什么"
    assert "FAIL SOLD_NOT_IN_NET" in proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
@pytest.mark.parametrize(
    ("old", "new", "expected_fail"),
    [
        # 1. 历史列表不再过滤 billable：0 元剧情回执也会混进「已结算」。
        ("if type(receipt.context) == 'table' and receipt.context.billable == true then",
         "if true then",
         "FAIL RECENT_ONLY_BILLABLE"),
        # 2. 排序反转/去掉：新的不在前。
        ("        if a.issuedAt ~= b.issuedAt then return a.issuedAt > b.issuedAt end\n"
         "        return (a._seq or 0) > (b._seq or 0)",
         "        return (a._seq or 0) < (b._seq or 0)",
         "FAIL RECENT_NEWEST_FIRST"),
        # 3. 返回内部账本而不是副本：前端改一下金额就改坏了钱账。
        ("    out._seq = nil   -- 内部排序用，不进 DTO\n    return out\n",
         "    out._seq = nil   -- 内部排序用，不进 DTO\n    return receipt\n",
         "FAIL RECENT_COPY_SAFE"),
    ],
    ids=["billable-filter", "newest-first", "copy-safety"],
)
def test_probe_goes_red_when_recent_contract_breaks(
        tmp_path: Path, old: str, new: str, expected_fail: str):
    """反向校验：Recent 的三条契约（过滤 / 排序 / 副本）任一被改坏，探针必须红。"""
    src = SETTLE.read_text(encoding="utf-8")
    assert old in src, f"变异锚点不存在，规则已与实现脱节：{old!r}"
    target = tmp_path / "quest_settle_broken.lua"
    target.write_text(src.replace(old, new, 1), encoding="utf-8")
    proc = run_probe(target)
    assert proc.returncode != 0, f"{expected_fail}: 契约被改坏后探针仍然全绿"
    assert expected_fail in proc.stdout, f"期望探针报 {expected_fail}：\n{proc.stdout}"


def per_run_key_problems(manager: str) -> list[str]:
    """静态判据：结算键必须按班次（runToken）而不是每任务一张。"""
    problems: list[str] = []
    if "':complete:'" not in manager:
        problems.append("结算键里没有 ':complete:' 分隔符")
    if "questId .. ':complete', receipt" in manager:
        problems.append("结算键退回成每任务一张 —— 第二班会被判成第一班的回放")
    if "local function settleRunToken(" not in manager:
        problems.append("缺少 settleRunToken")
    if "rentalResult.startedAt" not in manager or "QuestRunLatest" not in manager:
        problems.append("runToken 既没取租赁起点、也没有本班起点兜底")
    return problems


def test_settlement_key_is_per_run_with_reverse_check():
    """同一班稳定、跨班不同；把键改回每任务一张必须判红。"""
    manager = MANAGER.read_text(encoding="utf-8")
    assert not per_run_key_problems(manager), "\n".join(per_run_key_problems(manager))

    broken = manager.replace(
        "questId .. ':complete:' .. (runToken or 'unknown')",
        "questId .. ':complete'", 1)
    assert per_run_key_problems(broken), "把结算键改回每任务一张后判据仍然绿"


def test_receipt_is_wired_into_the_completion_path():
    """完成路径必须真的开一张回执，否则这套算式没人调用。"""
    manager = MANAGER.read_text(encoding="utf-8")
    assert "local function issueSettleReceipt" in manager
    assert "issueSettleReceipt(src, citizenid, questId, rentalResult, vendorSummary)" in manager
    # 押金 / 售出两边的数据必须真的取到（取不到就会算出一张全 0 的账单）
    assert "rentalResult and rentalResult.refund" in manager
    assert "vendorSummary and vendorSummary.revenue" in manager

    # 账单上下文：前端要渲染这些事实，服务端负责组装（Compute 仍只算钱）。
    block = manager[manager.index("local function issueSettleReceipt"):]
    block = block[:block.index("\nend\n")]
    for field in ("quest_title", "minutes", "sold_count", "leftover", "raw_count", "billable"):
        assert f"{field} = " in block, f"回执 context 缺少 {field}"
    assert "template.title" in block
    assert "rentalResult.minutes" in block
    assert "vendorSummary.sold" in block
    assert "vendorSummary.stock" in block
    assert "vendorSummary.raw" in block
    assert "rentalResult.idempotent == false" in block


def test_rental_close_exposes_the_session_start_for_the_settle_key():
    """runToken 的事实来源：Close 必须把本班会话起点往外带（会话随后就被清掉）。"""
    rental = RENTAL.read_text(encoding="utf-8")
    block = rental[rental.index("function QuestRental.Close("):]
    block = block[:block.index("\nend\n")]
    assert "startedAt = session.startedAt" in block


def test_settle_module_is_declared_in_the_manifest():
    manifest = MANIFEST.read_text(encoding="utf-8")
    assert "server/quest_settle.lua" in manifest


def test_receipt_uses_money_format_not_percent_d():
    """金额格式化必须走 QuestMoney：`$%d` 遇到小数会抛 format 错。"""
    manager = MANAGER.read_text(encoding="utf-8")
    block = manager[manager.index("local function issueSettleReceipt"):]
    block = block[:block.index("\nend\n")]
    assert "QuestMoney(" in block
    assert "$%d" not in block
