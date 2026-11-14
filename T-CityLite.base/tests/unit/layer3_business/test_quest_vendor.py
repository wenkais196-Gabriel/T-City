"""顾客会话（quest_vendor.lua）的服务端契约闸门（热狗线 S4）。

三层闸门：
  • 运行时探针跑**真实实现**（标记块抽取，不复制逻辑），覆盖 10 条硬性不变量
    + 边界（count<=0 / 未知 item / 会话不存在 / 原料耗尽）；
  • 反向校验：把 `already_settled` 那条判断删掉（改成直接重算），探针必须红 ——
    这条专门防「幂等只剩一个返回码、却仍然重复加钱」的坏形状；
  • 静态契约：钱只走 `AddMoney('cash', ..., 'quest-vendor-sale')`，本片不注册/不发送
    任何网络事件，且脚本真的被 fxmanifest 加载。

只建文件、不接线：exports / 客户端菜单 / NPC 实体都由主 agent 接。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SOURCE = BASE / "resources/[custom]/custom-quest/server/quest_vendor.lua"
MANIFEST = BASE / "resources/[custom]/custom-quest/fxmanifest.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "vendor_probe.lua"

# 优先 .exe：Windows 的 PATH 里同时有 lua5.4（可能是 Git Bash 包装脚本）
# 和 lua5.4.exe，subprocess 只能直接执行后者。
LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

EXPECTED_CHECKS = 19


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# 运行时探针：真跑源码里的会话状态机
# ---------------------------------------------------------------------------

def _run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_vendor_probe_passes():
    proc = _run_probe(SOURCE)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert f"SUMMARY {EXPECTED_CHECKS}/{EXPECTED_CHECKS}" in proc.stdout


# 「第二次结算必须 already_settled」是唯一阻止重复发钱的闸。变异点写死成一个字符串，
# 改名时这条反向校验会先醒（count != 1），而不是悄悄变成永远绿。
SETTLED_GUARD = "if offer.state == 'settled' then"


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_probe_goes_red_when_idempotency_guard_is_removed(tmp_path: Path):
    """反向校验（运行时）：删掉 already_settled 判断，探针必须红。

    探针里给足库存（2 份）并让同一个 offerId 结算两次；闸门没了以后第二次会真的
    再发一次钱，所以断言 `moneyCalls == 1` 和 `already_settled` 都会失败。
    """
    src = read(SOURCE)
    assert src.count(SETTLED_GUARD) == 1, (
        "变异点不唯一或已被改名：先更新 SETTLED_GUARD，否则这条反向校验会失效")
    mutated = src.replace(SETTLED_GUARD, "if false and offer.state == 'settled' then")
    target = tmp_path / "quest_vendor_mutant.lua"
    target.write_text(mutated, encoding="utf-8")

    proc = _run_probe(target)
    assert proc.returncode != 0, (
        "删掉 already_settled 判断后探针仍然通过 —— 幂等只剩返回码，"
        "重复结算会真的多发钱")
    failed = [line for line in proc.stdout.splitlines() if "FAIL" in line]
    assert any("offer_idempotent" in line for line in failed), (
        f"期望 offer_idempotent 变红，实际失败行：{failed}")


# ---------------------------------------------------------------------------
# 静态契约：钱的路径
# ---------------------------------------------------------------------------

MONEY_CALL = re.compile(
    r"AddMoney\(\s*'cash'\s*,[^)]*'quest-vendor-sale'\s*\)",
)


def test_money_only_moves_through_player_functions_cash_with_fixed_reason():
    src = read(SOURCE)
    assert MONEY_CALL.search(src), (
        "成交必须调用 Player.Functions.AddMoney('cash', ..., 'quest-vendor-sale')；"
        "这是对账与反刷钱的唯一凭据")
    assert src.count("AddMoney('cash'") == 1, (
        "现金入口只能有一个：NPC 成交与玩家购买都必须走同一个 payCash，"
        "否则两条路径的 reason/金额校验会漂移")


def test_money_rule_rejects_a_bank_or_untagged_payment():
    """反向校验（静态）：bank 路径 / 没有 reason 的调用必须判红。"""
    assert not MONEY_CALL.search("player.Functions.AddMoney('bank', 10, 'quest-vendor-sale')")
    assert not MONEY_CALL.search("player.Functions.AddMoney('cash', 10)")


# ---------------------------------------------------------------------------
# 静态契约：这一片不开新网络事件
# ---------------------------------------------------------------------------

FORBIDDEN_NETWORK_TOKENS = (
    "RegisterNetEvent",
    "RegisterServerEvent",
    "TriggerClientEvent",
    "TriggerEvent(",
)


def test_vendor_does_not_register_or_emit_network_events():
    src = read(SOURCE)
    offending = [token for token in FORBIDDEN_NETWORK_TOKENS if token in src]
    assert offending == [], (
        "S4 只做服务端内核：Tick 只返回动作，NPC 生成/提示由主 agent 接。"
        f"发现网络事件调用：{offending}")


def test_network_rule_rejects_a_wired_up_version():
    """反向校验（静态）：把事件接线塞进内核必须被判红。"""
    wired = (
        "RegisterNetEvent('quest:vendor:create', function() end)\n"
        "TriggerClientEvent('quest:vendor:offer', src, offer)\n"
    )
    assert [t for t in FORBIDDEN_NETWORK_TOKENS if t in wired] != []


# ---------------------------------------------------------------------------
# 静态契约：脚本被清单加载（否则组件在线上根本不会跑）
# ---------------------------------------------------------------------------

def test_vendor_is_declared_in_the_manifest():
    assert "server/quest_vendor.lua" in read(MANIFEST), (
        "quest_vendor.lua 不在 fxmanifest 的 server_scripts 里 —— "
        "探针全绿也不会在生产环境加载")


# ---------------------------------------------------------------------------
# S3 接线：做热狗（nonce 一次性 + 原料先扣再加成品）
# ---------------------------------------------------------------------------

BRIDGE = BASE / "resources/[custom]/custom-quest/server/quest_vendor_bridge.lua"
VENDOR_CLIENT = BASE / "resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua"


def test_cook_actions_are_whitelisted_on_the_only_event():
    """做热狗与收摊都必须走那条唯一的 vendorAction，不新开事件。"""
    bridge = BRIDGE.read_text(encoding="utf-8")
    actions_line = [l for l in bridge.splitlines() if l.startswith("local ACTIONS")][0]
    for action in ("accept", "reject", "purchase", "cook", "close"):
        assert f"{action} = true" in actions_line, f"{action} 不在动作白名单里"
    # 整个文件只能有一个 RegisterNetEvent
    assert bridge.count("RegisterNetEvent(") == 1


def test_cooking_consumes_raw_before_adding_stock():
    """先扣原料再加成品。

    反过来写的话，原料耗尽时 AddStock 已经成功、ConsumeRaw 返回 no_raw，
    结果就是「原料 0 还能一直做出热狗」。
    """
    bridge = BRIDGE.read_text(encoding="utf-8")
    consume = bridge.index("local consumed = QuestVendor.ConsumeRaw(citizenid)")
    add = bridge.index("local added = QuestVendor.AddStock(citizenid, result.tier, 1)")
    assert consume < add, "顺序反了：必须先扣原料"
    assert "if not consumed then" in bridge[consume:add], "扣原料失败必须提前返回"


def test_quality_comes_from_the_server_side_minigame_resolution():
    """品质由 QuestMinigame.Resolve 按 tiers 映射，客户端只说失误几次。"""
    bridge = BRIDGE.read_text(encoding="utf-8")
    assert "QuestMinigame.Resolve(citizenid, nonce" in bridge
    assert "result.tier" in bridge
    cook_config = bridge[bridge.index("function QuestVendorBridge.CookConfig()"):]
    cook_config = cook_config[:cook_config.index("\nend\n")]
    assert "max_faults = 0" in cook_config and "'exotic'" in cook_config
    assert "max_faults = 1" in cook_config and "'rare'" in cook_config


def test_closing_the_stand_does_two_things():
    """收摊要同时关会话与推进任务。

    只关会话：任务永远停在「开卖」；只推进任务：顾客继续来加钱。
    """
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    assert "TriggerServerEvent('quest:server:vendorAction', 'close'" in client
    assert "TriggerServerEvent('quest:server:nodeComplete', booth.questId, booth.stepId, 'vendor'" in client


def test_cooking_uses_the_shared_minigame_export():
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    assert "exports['qb-minigames']:KeyMinigame(10)" in client
    # 客户端不许自己判定品质
    block = client[client.index("quest:client:cookStart"):]
    block = block[:block.index("end)")]
    assert "exotic" not in block and "rare" not in block, "客户端不能自己决定品质"