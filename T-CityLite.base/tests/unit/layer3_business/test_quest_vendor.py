"""顾客会话（quest_vendor.lua）的服务端契约闸门（热狗线 S4）。

三层闸门：
  • 运行时探针跑**真实实现**（标记块抽取，不复制逻辑），覆盖 11 条硬性不变量
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

EXPECTED_CHECKS = 20


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
    两者现在**都在服务端**完成（客户端只发一条 close）—— 客户端手里的 stepId 是
    摆摊那一步的，早先拿它报 nodeComplete 会判 Step order violation。
    """
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    assert "TriggerServerEvent('quest:server:vendorAction', 'close'" in client
    bridge = BRIDGE.read_text(encoding="utf-8")
    close_block = bridge[bridge.index("if action == 'close' then"):]
    close_block = close_block[:close_block.index("\n    end\n")]
    assert "CloseFor(citizenid" in close_block, "收摊必须关顾客会话"
    assert "AdvanceStep(citizenid" in close_block, "收摊必须推进任务"


def test_cooking_uses_the_shared_minigame_export():
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    assert "exports['qb-minigames']:KeyMinigame(10)" in client
    # 客户端不许自己判定品质
    block = client[client.index("quest:client:cookStart"):]
    block = block[:block.index("end)")]
    assert "exotic" not in block and "rare" not in block, "客户端不能自己决定品质"


def test_customer_ped_is_created_and_deleted_by_the_client():
    """顾客 ped 是表现层：客户端生成、客户端删，且必须防「报价换了 ped 还在」。"""
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    assert "local function SpawnCustomerPed" in client
    assert "CreatePed(4, model" in client
    # 生成是异步的（RequestModel 会 yield）：回来时要重新确认还是同一张报价
    spawn_block = client[client.index("local wantOfferId = offerId"):]
    spawn_block = spawn_block[:spawn_block.index("end)")]
    assert "ActiveOffer.offerId ~= wantOfferId" in spawn_block, (
        "没有校验报价是否已被替换 —— 会把上一张报价的 ped 挂到新报价上，两边都删不掉")
    # 清理必须走 ClearOffer（成交/过期/替换/任务结束都汇到那里）
    clear = client[client.index("local function ClearOffer"):]
    clear = clear[:clear.index("\nend\n")]
    assert "DeleteEntity(offer.localPed)" in clear


def test_customer_ped_does_not_block_the_road():
    """顾客是冻结的无敌 ped：不挡车、不被误伤、不被事件打断。"""
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    block = client[client.index("local function SpawnCustomerPed"):]
    block = block[:block.index("\nend\n")]
    assert "FreezeEntityPosition(ped, true)" in block
    assert "SetEntityInvincible(ped, true)" in block
    assert "SetBlockingOfNonTemporaryEvents(ped, true)" in block


# ---------------------------------------------------------------------------
# 真机两处硬伤（2026-11-14 晚）：收摊推进报 Step order violation / 中文画成方块
# ---------------------------------------------------------------------------

BOOTH_CLIENT = BASE / "resources/[custom]/custom-quest/client/quest_hotdog_client.lua"
FONT = BASE / "resources/[custom]/custom-quest/fonts/hotdog_ui.ttf"
FONT_TOOL = BASE.parent / "tools/dev/build_quest_font.py"


def test_closing_the_stand_does_not_report_a_stale_step_id():
    """收摊不许再由客户端报 nodeComplete。

    真机：`vendorState.stepId` 是**摆摊**那一步的 id（开卖时就推下来了），拿它去 nodeComplete
    会被判 `Step order violation: expected step_sell, got step_place_stand`，红字刷屏。
    现在改由服务端在 close 动作里自己推进。
    """
    client = VENDOR_CLIENT.read_text(encoding="utf-8")
    assert "nodeComplete', booth.questId, booth.stepId, 'vendor'" not in client
    bridge = BRIDGE.read_text(encoding="utf-8")
    assert "local function vendorStepIdOf" in bridge, "服务端必须自己找 vendor 步骤"
    close_block = bridge[bridge.index("if action == 'close' then"):]
    close_block = close_block[:close_block.index("\n    end\n")]
    assert "QuestManager.AdvanceStep(citizenid, booth.questId, stepId, {})" in close_block


def test_chinese_text_uses_a_bundled_font():
    """GTA 内置字体没有 CJK：界面中文必须走自带字体的 id。"""
    for path in (VENDOR_CLIENT, BOOTH_CLIENT):
        src = path.read_text(encoding="utf-8")
        assert "RegisterFontFile('fonts/hotdog_ui.ttf')" in src, f"{path.name} 没有注册中文字体"
        # 代码里不许再出现硬编码 4 号字体（注释里提到可以）
        code = "\n".join(line.split("--")[0] for line in src.splitlines())
        assert "SetTextFont(4)" not in code, f"{path.name} 还有硬编码字体 4 —— 中文会变方块"
    assert FONT.exists(), "缺 fonts/hotdog_ui.ttf（跑 tools/dev/build_quest_font.py）"


def test_font_subset_is_in_sync_with_the_source_strings():
    """改了文案不重跑字体会让新字变方块，所以字符集有指纹。"""
    import importlib.util

    spec = importlib.util.spec_from_file_location("build_quest_font", FONT_TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)   # type: ignore[union-attr]
    chars = module.char_set()
    stamp = FONT.with_suffix(".sha256")
    assert stamp.exists(), "缺字符集指纹"
    assert stamp.read_text(encoding="utf-8").strip() == module.fingerprint(chars), (
        "源码里的字符集变了 —— 重跑 tools/dev/build_quest_font.py")


# ---------------------------------------------------------------------------
# 收摊双通道（2026-11-15）：一次 E 只能推进一次
#
# 静态形状由 tests/architecture/test_quest_vendor_single_channel.py 守；
# 这里跑运行时探针：真实模板 + 真实 nodeInteract 处理器 + 真实 bridge close 分支。
# ---------------------------------------------------------------------------

HOTDOG_TEMPLATE = BASE / "resources/[custom]/custom-quest/config/quests/quest_hotdog.lua"
MAIN_CLIENT = BASE / "resources/[custom]/custom-quest/client/main.lua"
SINGLE_CHANNEL_PROBE = (
    Path(__file__).resolve().parent / "fixtures" / "vendor_single_channel_probe.lua"
)


def _run_single_channel_probe(*extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(SINGLE_CHANNEL_PROBE), str(MAIN_CLIENT), str(BRIDGE),
         str(HOTDOG_TEMPLATE), *extra],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_single_action_advances_vendor_step_exactly_once():
    """通用交互对 vendor 步骤不发 nodeComplete；一次 close 只推进一次。"""
    proc = _run_single_channel_probe()
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 6/6" in proc.stdout, proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_probe_goes_red_when_vendor_step_regains_interaction_data():
    """反向校验：把 coords/radius/duration 塞回 vendor 步骤，探针必须变红。

    这正是事故形状：模板里只要还挂着通用交互数据，客户端就会画点并上报
    nodeComplete，与收摊的服务端推进各算一次。
    """
    proc = _run_single_channel_probe("--mutate")
    assert proc.returncode != 0, "vendor 步骤重新带上交互数据后探针仍然通过"
    assert "FAIL vendor_does_not_start_interact_thread" in proc.stdout, (
        f"期望通用交互线程被启动而变红，实际输出：\n{proc.stdout}"
    )