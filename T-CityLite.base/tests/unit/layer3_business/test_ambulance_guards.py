"""P1-3 批 9：qb-ambulancejob 的越权与自伤面。

这个资源之前的批次已经加过一些守卫（`CanRevive`、`SendToBed` 的索引校验与 30 秒限流、
`SetDeathStatus` 的"无伤不得自报死亡"），剩下的 14 个事件里有真有假：

- **真洞**：`stash` 只看客户端菜单里的 job 过滤条件（可绕过）→ 任何玩家都能开一个"救护队
  储物柜"；`LeaveBed` 任何人传任意床号就能把全服的床标成空闲；`resetHungerThirst` 等于免费
  把饥饿/口渴拉满；`ambulanceAlert` 的文案来自客户端且无冷却（一人刷爆所有在职 EMS）；
  `SendDoctorAlert` 只有一个全局开关，谁先按下谁就能把它锁 `Config.DocCooldown` 分钟；
  `CanHelp` 任何玩家都能替人回答"可以施救"；`RemoveDoctor` 用客户端传的 `job == 'ambulance'`
  减值（平民能把医生数刷到 0）。
- **自伤面**：`SyncInjuries` / `SetWeaponDamage` 写的是自己的 metadata，但内容仍需有界
  （`isBleeding = 1e9` 会把 HUD 和治疗判定写坏）。

探针真加载 `config.lua` + `server/main.lua`，mock 运行时后直接调用 handler。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run() -> dict[str, str]:
    proc = subprocess.run(
        [
            "lua5.4",
            (FIXTURES / "ambulance_probe.lua").as_posix(),
            (BASE / "resources" / "[qb]" / "qb-ambulancejob").as_posix(),
        ],
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data[key] = value
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


def test_ems_stash_requires_on_duty_ems():
    """`qb-ambulancejob:server:stash` 原来只看客户端 target 的 `job = 'ambulance'`。

    那只是菜单过滤条件：任何玩家发一次就能打开自己的「救护队储物柜」（`ambulancestash_<cid>`）。
    下班的 EMS 也不该能开。
    """
    data = _run()
    assert data["STASH_CIVILIAN_BLOCKED"] == "true", "平民打开了救护队储物柜"
    assert data["STASH_OFFDUTY_BLOCKED"] == "true", "下班的 EMS 也能开储物柜"
    assert data["STASH_EMS_ALLOWED"] == "true", "在班 EMS 反而打不开（过度收紧）"


def test_leave_bed_is_scoped_to_the_occupant():
    """`LeaveBed(id, hospitalIndex)` 的结果是向全服广播 `SetBed(..., false, ...)`。

    旧版没有任何归属校验：任何人传任意床号就能把全服的床标成空闲（也能用来"赶人"）。
    """
    data = _run()
    assert data["BED_OCCUPIED"] == "true", "SendToBed 没有登记床位占用"
    assert data["BED_RELEASED_BY_STRANGER"] == "0", "陌生人释放了别人的床位"
    assert data["BED_RELEASED_BY_OCCUPANT"] == "1", "占用者自己反而下不了床（过度收紧）"


def test_reset_hunger_thirst_only_inside_the_revive_window():
    """`resetHungerThirst` 把饥饿/口渴直接拉满 = 免费吃饭喝水。

    只允许"刚被服务端复活/送进院"的玩家调用（`markRevived` 在 RevivePlayer /
    RespawnAtHospital / txAdmin heal 三处写入，窗口 180 秒）。
    """
    data = _run()
    assert data["HUNGER_OUTSIDE_WINDOW_BLOCKED"] == "true", "窗口外仍能把饥饿/口渴拉满"
    assert data["HUNGER_AFTER_RESPAWN_ALLOWED"] == "true", "正常进院后反而重置不了（过度收紧）"


def test_ambulance_alert_validates_and_rate_limits():
    """`ambulanceAlert(text)` 的文案来自客户端，且会广播给所有在职 EMS。"""
    data = _run()
    assert data["ALERT_NON_STRING_IGNORED"] == "true", "非字符串文案仍被广播"
    assert data["ALERT_TO_ONDUTY_EMS"] == "true", "正常的 EMS 呼叫没送到（过度收紧）"
    assert data["ALERT_TEXT_TRUNCATED"] == "true", "文案没有截断（可以塞几十 KB 刷客户端）"
    assert data["ALERT_COOLDOWN_BLOCKED"] == "true", "没有冷却，一个人可以刷屏所有 EMS"


def test_doctor_alert_requires_a_real_hospital_name():
    """`SendDoctorAlert(hospitalName)` 的院名来自客户端，会拼进全服 EMS 通知。"""
    data = _run()
    assert data["DOCTOR_ALERT_FAKE_NAME_IGNORED"] == "true", "伪造的院名仍能广播"


def test_can_help_needs_a_pending_aid_receipt():
    """`CanHelp(helperId, canHelp)` 让服务端给 helper 发「可以施救」。

    旧版任何玩家都能凭空回答：配合客户端流程就能伪造一次治疗。
    现在要求 `PendingAid[src] == helperId`（由 `UseFirstAid` 写入的回执）。
    """
    data = _run()
    assert data["CANHELP_WITHOUT_PENDING"] == "true", "没有急救回执也能回答"
    assert data["CANHELP_WITH_PENDING"] == "true", "有回执的正常流程被挡住（过度收紧）"


def test_doctor_count_only_changes_for_registered_ems():
    """`RemoveDoctor` 旧版按客户端传的 `job == 'ambulance'` 减 `doctorCount`。

    平民发一次就能把医生数刷到 0（HUD 与呼叫医生都跟着失真）。
    """
    data = _run()
    assert data["DOCTOR_COUNT_AFTER_ADD"] == "1"
    assert data["DOCTOR_COUNT_AFTER_CIVILIAN"] == "1", "平民改动了医生计数"
    assert data["DOCTOR_COUNT_AFTER_EMS"] == "0", "在班 EMS 反而减不掉（过度收紧）"


def test_injury_sync_is_bounded():
    """伤情写的是自己的 metadata，但数值必须有界。"""
    data = _run()
    assert data["INJURIES_NON_TABLE_IGNORED"] == "true", "非表结构被写进 metadata"
    assert data["INJURIES_BLEEDING_CLAMPED"] == "true", "isBleeding 没有被夹到 0..100"
