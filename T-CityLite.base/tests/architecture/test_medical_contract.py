"""医疗模块的契约闸门（M-3：复活规则）。"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base" / "resources"
CONS = RES / "[custom]" / "custom-consumables" / "server" / "main.lua"
AMB_CL = RES / "[qb]" / "qb-ambulancejob" / "client" / "main.lua"
AMB_JOB = RES / "[qb]" / "qb-ambulancejob" / "client" / "job.lua"
AMB_DEAD = RES / "[qb]" / "qb-ambulancejob" / "client" / "dead.lua"
NL = chr(10)


def test_revive_resets_armor_and_raises_needs_detects_old_behaviour():
    """D3=甲：救起来是"裸装起来" —— 护甲 0、饥渴抬到 50，且饥渴只由 consumables 写。"""
    cons = CONS.read_text(encoding="utf-8")
    amb = AMB_CL.read_text(encoding="utf-8")

    assert "RestoreAfterRevive" in cons, "consumables 没有提供抬饥渴的入口"
    assert "math.max(status.hunger" in cons, "只抬不压的语义丢了（救人反而变饿）"
    assert "SetPedArmour(player, 0)" in amb, "复活后护甲没有归零"
    assert "custom-consumables:server:RestoreAfterRevive" in amb, "复活流程没有接饥渴入口"
    # 反向：救护车不许直接写 metadata.hunger（那会破坏"单一写者"）
    assert "SetMetaData('hunger'" not in amb, "ambulance 直接写了 hunger（应走 consumables）"

    # 反向：把护甲归零删掉，规则必须红
    broken = amb.replace("SetPedArmour(player, 0)", "SetPedArmour(player, 50)")
    assert "SetPedArmour(player, 0)" not in broken


def test_revive_prompt_uses_e_detects_alt_and_missing_statebag():
    """M-1：施救是"面前唯一动作" → 必须 [E]，且要能判断对方是否倒地（靠 statebag）。"""
    job = AMB_JOB.read_text(encoding="utf-8")
    server = (RES / "[qb]" / "qb-ambulancejob" / "server" / "main.lua").read_text(encoding="utf-8")

    assert "custom-prompt" in job, "施救没有走统一提示组件"
    assert "state.isdead" in job or "state.inlaststand" in job, "客户端判断不了谁倒地"
    assert "state:set('isdead'" in server, "服务端没有把 isdead 放进 statebag"

    # 反向：把提示摘掉，规则必须红
    broken = job.replace("exports['custom-prompt']:Show", "noop(")
    assert "exports['custom-prompt']:Show" not in broken


def test_hospital_zones_use_e_not_alt_detects_regression():
    """M-4：医院 4 类区域（值班/储物/上楼/下楼）都是单动作 → 不许再注册 qb-target 区域。"""
    job = AMB_JOB.read_text(encoding="utf-8")
    for zone in ("duty", "stash", "roof", "main"):
        assert f"AddBoxZone('{zone}' .. i" not in job, f"{zone} 还在注册 qb-target 热区"
    assert "EMS_ZONES" in job, "没有统一的医院区域表"
    assert "EMS_ZONE_RANGE" in job, "没有提示半径"

    # 反向：塞回一个热区，规则必须红
    broken = job + chr(10) + "exports['qb-target']:AddBoxZone('duty' .. i, v, 1, 1, {}, {}, 1.5)"
    assert "AddBoxZone('duty' .. i" in broken


def test_laststand_and_revive_copy_are_chinese_detects_english():
    """M-2/M-5：濒死倒计时与施救回执必须是中文（qb_locale 对这套 locale 不生效）。"""
    dead = AMB_DEAD.read_text(encoding="utf-8")
    job = AMB_JOB.read_text(encoding="utf-8")

    assert "秒后失去意识" in dead, "濒死倒计时没有中文文案"
    assert "%d~s~ 秒" in dead or "%d" in dead, "濒死倒计时没带秒数"
    assert "Lanf:t('info.bleed_out'" not in dead
    assert "Lang:t('info.bleed_out'" not in dead, "濒死文案还在用英文 locale"
    assert "已救起" in job, "施救成功没有中文回执"
    assert "PushLocal('feed'" in job, "施救回执没走 feed"
    assert "PushLocal('error'" in job, "施救失败没走 error"

    # 反向：把英文塞回去，规则必须红
    broken = dead + chr(10) + "DrawTxt(0.5, 1.3, 1, 1, 0.6, Lang:t('info.bleed_out', { time = 1 }))"
    assert "Lang:t('info.bleed_out'" in broken
