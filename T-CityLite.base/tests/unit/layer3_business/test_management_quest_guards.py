"""P1-3 批 15：qb-management 与 custom-quest。

**qb-management** 的三个 boss 仓库入口（职业 / 帮派 / 组织）其实早就写了「本人是 boss + 站在菜单点
2.5 米内」的判定，只是写成 `if not playerJob.isboss then return end` 这种闸门认不出来的形状。
本轮把它们抽成 `CanOpenBossStash(src, Player, orgType, orgName)` 并登记进
`net_event_guard_helpers.json` —— **行为不变**（探针对旧版跑也是全绿），换来的是闸门能按
deny-early 形状持续核对，而不是靠 allowlist 的承诺。顺带把 `personalStash` 补了 gang 字段的类型校验。

**custom-quest** 的四个事件是"客户端报告任务进度"，原来只判了 `Player` 存在：

- `aviationHeightMonitorComplete()`：任何玩家随手发一条就能把自己「低空飞行 45 秒」的步骤标记完成
  （handler 连参数都没有）。现在要求 questId 是字符串、该玩家确实在跑这单任务、且人**在飞行器
  里**（直升机/固定翼）、是驾驶员、离地高度 ≤150 米 —— 45 秒的持续时长仍由客户端计时，但
  "站在街上点一下"这条堵掉了。
- `registerTrailer(questId, netId, model)`：补「必须正在跑该任务」+ 申报模型与实体模型一致。
- `entityTrackingFail(questId, reason)`：补 questId 校验与「必须在跑该任务」，`reason` 会进安全
  审计日志所以截断到 100 字（原来可以往日志里塞任意长度内容）。
- `cargoDamageResult(data)`：`data` 为 nil 时直接抛错，四个数值也无界（可上报负数/天文数字影响
  结算评分）→ 类型校验 + 各自夹取到上限。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource_path: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / resource_path).as_posix()],
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
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


# ══════════════════════════════════════════════════════════════════
# qb-management
# ══════════════════════════════════════════════════════════════════


def test_boss_stash_requires_being_the_boss_and_standing_there():
    """三个仓库入口（职业/帮派/组织）都要「本人是 boss + 站在菜单点 2.5 米内」。"""
    data = _run("management_probe.lua", "[qb]/qb-management")
    assert data["BOSS_STASH_NON_BOSS_BLOCKED"] == "true", "同职业的普通员工能开 boss 仓库"
    assert data["BOSS_STASH_FAR_BLOCKED"] == "true", "boss 在地图另一头也能开仓库"
    assert data["BOSS_STASH_OK"] == "true", "真正的 boss 站在菜单点反而开不了（过度收紧）"

    assert data["ORG_STASH_BOSS_OK"] == "true", "组织菜单里 boss 开不了（过度收紧）"
    assert data["ORG_STASH_NON_BOSS_BLOCKED"] == "true", "组织菜单里非 boss 也能开"

    assert data["GANG_STASH_NON_BOSS_BLOCKED"] == "true", "帮派普通成员能开帮派仓库"
    assert data["GANG_STASH_BOSS_OK"] == "true", "帮派 boss 反而开不了（过度收紧）"


def test_personal_gang_stash_is_own_and_requires_a_gang():
    data = _run("management_probe.lua", "[qb]/qb-management")
    assert data["PERSONAL_STASH_OK"] == "true", "帮派成员开不了自己的个人仓库（过度收紧）"
    assert data["PERSONAL_STASH_NO_GANG_BLOCKED"] == "true", "没有帮派也能开个人仓库"


# ══════════════════════════════════════════════════════════════════
# custom-quest
# ══════════════════════════════════════════════════════════════════


def test_cargo_damage_report_survives_bad_payloads():
    """`cargoDamageResult(data)` 的 data 来自客户端，nil/非表/坏 questId 都不能打崩事件线程。"""
    data = _run("quest_probe.lua", "[custom]/custom-quest")
    assert data["DAMAGE_NIL_SAFE"] == "true", "缺参数时抛错（原来 `data.questId` 直接崩）"
    assert data["DAMAGE_NOT_TABLE_SAFE"] == "true", "非表参数时抛错"
    assert data["DAMAGE_BAD_QUESTID_SAFE"] == "true", "questId 非字符串时抛错"
    assert data["DAMAGE_RECORDED"] == "true", "正常上报没写进记录（过度收紧）"


def test_cargo_damage_values_are_clamped():
    """碰撞次数/损伤百分比/血量差值都会进入结算评分，必须夹取。"""
    data = _run("quest_probe.lua", "[custom]/custom-quest")
    assert data["DAMAGE_CLAMPED"] == "true", "越界数值没有被夹取（可上报负数或天文数字影响评分）"


def test_aviation_completion_requires_being_in_an_aircraft_but_fails_open():
    """`aviationHeightMonitorComplete(questId)`：客户端发完就 break，服务端拒绝没有重试路径。

    所以机型识别必须是 fail-open —— 原生不存在 / 返回 0 时放行；只有**明确**识别为陆上载具
    或人不在载具里才拒。旧版（master）后三条全是 false。
    """
    data = _run("quest_events_probe.lua", "[custom]/custom-quest")
    assert data["AVIATION_COPLANE_ALLOWED"] == "true", "正常玩家开飞机反而过不了（过度收紧）"
    assert data["AVIATION_NATIVE_MISSING_ALLOWED"] == "true", "拿不到机型就拒 = fail-closed，会卡死玩家"
    assert data["AVIATION_CLASS_ZERO_ALLOWED"] == "true", "机型返回 0（未知）时不应拒绝"
    assert data["AVIATION_CAR_BLOCKED"] == "true", "开轿车也能完成低空飞行步骤"
    assert data["AVIATION_ON_FOOT_BLOCKED"] == "true", "站在地上也能完成低空飞行步骤"
    assert data["AVIATION_WRONG_QUEST_BLOCKED"] == "true", "没接这单任务也能触发完成"


def test_register_trailer_requires_matching_model():
    """申报模型必须是字符串**且**与实体一致 —— opt-in 写法少传一个参数就绕过。"""
    data = _run("quest_events_probe.lua", "[custom]/custom-quest")
    assert data["TRAILER_VALID_MODEL_ALLOWED"] == "true", "正常登记挂车被拒（过度收紧）"
    assert data["TRAILER_MISSING_MODEL_BLOCKED"] == "true", "不传模型也能登记"
    assert data["TRAILER_BAD_MODEL_TYPE_BLOCKED"] == "true", "模型传数字也能登记"
    assert data["TRAILER_MODEL_MISMATCH_BLOCKED"] == "true", "申报模型与实体不一致也能登记"
