"""医疗模块的契约闸门（M-3：复活规则）。"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base" / "resources"
CONS = RES / "[custom]" / "custom-consumables" / "server" / "main.lua"
AMB_CL = RES / "[qb]" / "qb-ambulancejob" / "client" / "main.lua"
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
