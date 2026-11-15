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


def run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],  # NOSONAR
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_bill_rules_hold():
    proc = run_probe(SETTLE)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 22/22" in proc.stdout


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


def test_receipt_is_wired_into_the_completion_path():
    """完成路径必须真的开一张回执，否则这套算式没人调用。"""
    manager = MANAGER.read_text(encoding="utf-8")
    assert "local function issueSettleReceipt" in manager
    assert "issueSettleReceipt(src, citizenid, questId, rentalResult, vendorSummary)" in manager
    # 押金 / 售出两边的数据必须真的取到（取不到就会算出一张全 0 的账单）
    assert "rentalResult and rentalResult.refund" in manager
    assert "vendorSummary and vendorSummary.revenue" in manager


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
