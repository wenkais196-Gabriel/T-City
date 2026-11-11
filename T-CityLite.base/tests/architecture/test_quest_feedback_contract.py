"""任务反馈契约闸门（J-3 / J-3b / J-3c）。

锁三件事，都来自 CC 实测出来的重复发送：

1. **完成 / 失败 / 步骤各只发一条**：`client/main.lua` 不得再发 `Quest completed` /
   `Quest failed` / `Step:`，否则同一次任务玩家会看到 2–3 条同样的话。
2. **逐秒倒计时不许再出现**：`remaining <= 10` 会让 10/9/8…1 每秒一条，必须只在固定秒数提醒。
3. **结算进手机留档**：`quest_rewards.lua` 不得再用屏上通知发"任务结算"，
   否则与"任务完成"重复；也不得把 `player_death` 这类内部词直接给玩家看。

每条规则都在同一个用例里**自己构造错误形状并断言会红**（gate_coverage 认 `detects` 记号）。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BASE = REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-quest"
CLIENT = BASE / "client" / "main.lua"
MANAGER = BASE / "server" / "quest_manager.lua"
REWARDS = BASE / "server" / "quest_rewards.lua"

NL = chr(10)


def _text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _screen_notify_lines(text: str) -> list[str]:
    """取出所有"发到屏幕"的通知行（Notify / TriggerClientEvent('QBCore:Notify'）。"""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        if "QBCore.Functions.Notify" in stripped or "'QBCore:Notify'" in stripped:
            out.append(stripped)
    return out


def test_client_duplicate_terminal_events_detects_injected_insert():
    client = _text(CLIENT)
    joined = NL.join(_screen_notify_lines(client))
    for forbidden in ("Quest completed", "Quest failed", "('Step: %s')"):
        assert forbidden not in joined, (
            "client/main.lua 仍在发 " + forbidden +
            " —— 服务端已经发过一条，同一次任务玩家会看到两条（J-3）")

    # 反向：把重复的完成回执加回去，闸门必须认出来
    anchor = "    activeQuest = nil" + NL + "    -- J-3：完成回执由服务端发，客户端只清理状态"
    injected = ("    activeQuest = nil" + NL +
                "    QBCore.Functions.Notify(('Quest completed: %s!'):format(data.title), 'success')")
    broken = client.replace(anchor, injected, 1)
    assert broken != client, "反向校验的注入点失效了（客户端那段注释被改动）"
    assert "Quest completed" in NL.join(_screen_notify_lines(broken)), (
        "闸门没认出重复的完成回执")


def test_server_single_source_detects_missing_receipt():
    manager = _text(MANAGER)
    assert "任务完成：" in manager, "服务的完成回执不见了（J-3 要求唯一一条在这里）"
    assert "任务失败：" in manager, "服务的失败回执不见了（J-3 要求唯一一条在这里）"

    # 反向：把唯一一条完成回执删掉，这条规则必须红
    broken = manager.replace("('✅ 任务完成：%s'):format(template.title)",
                             "('done'):format(template.title)")
    assert "任务完成：" not in broken, "闸门没认出被删掉的完成回执"


def test_per_second_countdown_detects_le_shape():
    client = _text(CLIENT)
    assert "remaining <= 10 then" not in client, (
        "remaining <= 10 会让 10/9/8…1 每秒一条通知（J-3b）；改成固定秒数（== 10 / == 5）")
    assert re.search(r"remaining\s*==\s*10", client), "倒计时提醒的固定秒数不见了"

    # 反向：改回 <= 写法，闸门必须红
    broken = client.replace("elseif remaining == 10 or remaining == 5 then",
                            "elseif remaining <= 10 then", 1)
    assert "remaining <= 10 then" in broken, "倒计时闸门没咬住逐秒写法"


def test_reward_on_screen_detects_regression():
    rewards = _text(REWARDS)
    assert "'phone'" in rewards, "任务结算应走手机留档（J-3）"
    assert "任务结算" not in NL.join(_screen_notify_lines(rewards)), (
        "任务结算又回到屏幕上了 —— 会和'任务完成'重复")

    # 反向：改回屏上通知，闸门必须红
    broken = rewards.replace(
        "exports['custom-notify']:Push(source, 'phone', '任务结算',",
        "TriggerClientEvent('QBCore:Notify', source, ('任务结算'), 'success'); "
        "exports['custom-notify']:Push(source, 'phone', '任务结算',",
        1,
    )
    assert broken != rewards
    assert "任务结算" in NL.join(_screen_notify_lines(broken)), (
        "闸门没认出回到屏幕上的结算")


def test_raw_failure_reason_detects_leak():
    manager = _text(MANAGER)
    assert "REASON_ZH" in manager, "失败原因翻译表不见了"
    for raw in ("player_death", "entity_timeout", "validation_exhausted"):
        assert raw + " =" in manager, "原因 " + raw + " 没有中文映射，玩家会看到内部词"
    assert "任务失败：%s'):format(reason)" not in manager, (
        "失败通知直接拼了原始 reason，应该走 reasonZh()")

    # 反向：直接把 reason 拼进玩家文案，规则必须认出来
    broken = manager.replace("('❌ 任务失败：%s'):format(reasonZh(reason))",
                             "('❌ 任务失败：%s'):format(reason)")
    assert "任务失败：%s'):format(reason)" in broken, "闸门没认出裸 reason"
