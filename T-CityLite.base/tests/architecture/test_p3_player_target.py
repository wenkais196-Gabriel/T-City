"""P3-1：对玩家的盘查入口（查证件 / 搜身 / 铐起 / 押送）。

P3 核对（docs/police/plans/2026-10-31-p3-audit.md）的结论：逮捕/报告/罚单/证据、
BOLO、搜身与押送事件都已存在，缺的是"对准一个真人"的入口。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICE = REPO / "T-CityLite.base/resources/[custom]/custom-police"
TARGET = POLICE / "client/player_target.lua"
INTERACTIONS = POLICE / "server/interactions.lua"
MANIFEST = POLICE / "fxmanifest.lua"


def test_player_target_exposes_the_four_verbs() -> None:
    src = TARGET.read_text(encoding="utf-8")
    assert "AddGlobalPlayer" in src, "要挂在玩家身上，不是世界实体"
    for label in ("查证件", "搜身", "铐起", "押送"):
        assert label in src, f"缺动作：{label}"
    assert "canInteract" in src and "onduty" in src, "只有在岗警察才看得到选项"


def test_id_check_is_verified_on_the_server() -> None:
    src = INTERACTIONS.read_text(encoding="utf-8")
    at = src.find("police:server:showId")
    assert at != -1
    block = src[at:at + 1600]
    assert "onduty ~= true" in block, "离岗要拒绝"
    assert "too_far" in block and "GetEntityCoords" in block, "距离必须服务端复算"
    assert "PoliceAudit.Write" in block, "查证件要留审计"
    # 只回公开资料：钱包/背包/案底不该出现在这里
    for leak in ("money", "inventory", "phone"):
        assert leak not in block, f"查证件回包里混进了 {leak}"


def test_manifest_loads_the_target_panel() -> None:
    src = MANIFEST.read_text(encoding="utf-8")
    assert "client/player_target.lua" in src


def test_field_tests_have_a_real_data_source_and_server_gates() -> None:
    """酒测/药检（P3-2）。

    本服没有 qb-smallresources，也就没有任何"喝醉"状态：酒测如果没有数据源，
    只能编随机数——那比没有更糟。所以补一个最小 Sobriety（喝酒 → 读数 → 随时间衰减）。
    """
    sob = (POLICE / "server/sobriety.lua").read_text(encoding="utf-8")
    assert "DECAY_PER_SECOND" in sob, "读数必须会衰减"
    assert "beer" in sob and "vodka" in sob, "数据源接在真实物品上"
    assert "qb-inventory:server:UseItem" in sob, "要用既有物品使用事件"

    src = INTERACTIONS.read_text(encoding="utf-8")
    at = src.find("police:server:fieldTest")
    assert at != -1
    block = src[at:at + 3000]
    assert "onduty ~= true" in block and "too_far" in block
    assert "RateLimitCooldown" in block, "同类读数要冷却"
    assert "PoliceAudit.Write" in block
    # evidence 表要求挂 case/incident，盘查阶段没有 → 不该假装写了
    assert "evidence = false" in block


def test_player_target_has_six_verbs() -> None:
    src = TARGET.read_text(encoding="utf-8")
    for label in ("查证件", "搜身", "铐起", "押送", "酒测", "药检"):
        assert label in src, f"缺动作：{label}"


def test_last_inspection_feeds_the_arrest_form() -> None:
    """P3-3：盘查 → 立案的桥。

    盘查结果按**警员**记在内存里（不需要历史），MDT 用一个 `last_inspection` 查询带走；
    该 export 属于敏感读取（谁被盘过、读数多少），必须带策略门与审计失败关闭。
    """
    src = INTERACTIONS.read_text(encoding="utf-8")
    at = src.find("exports('GetLastInspection'")
    assert at != -1
    block = src[at:at + 900]
    assert "PolicePolicy.Can" in block
    assert "'audit_unavailable'" in block, "审计写不进去要失败关闭"

    mdt = (REPO / "T-CityLite.base/resources/[custom]/custom-phone/server/apps/police_mdt.lua").read_text(encoding="utf-8")
    assert "last_inspection = function" in mdt, "查询名必须 snake_case（注册表只认小写）"
    assert "GetLastInspection" in mdt

    vue = (REPO / "T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/PoliceMDT.svelte").read_text(encoding="utf-8")
    assert "fillFromInspection" in vue
    assert "从最近盘查带入" in vue


def test_bolo_is_pushed_to_on_duty_officers() -> None:
    """P3-4：BOLO 以前只是 reports 表上的一个标记，发布完街上没别人知道。"""
    src = (POLICE / "server/p2_system.lua").read_text(encoding="utf-8")
    assert "local function broadcastBolo" in src
    at = src.find("local function broadcastBolo")
    block = src[at:at + 1400]
    assert "job.name == 'police'" in block and "onduty == true" in block
    assert "Outbox.Enqueue" in src, "通知必须走 custom-phone 的 outbox（FIT-02）"
    # 两条 BOLO 路径都要推：逮捕提交 + 报告提交
    assert src.count("broadcastBolo(actor.citizenid") == 2
