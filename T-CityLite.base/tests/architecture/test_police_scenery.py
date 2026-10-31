"""L1 布景层（蓝图 §6.2）：站点守卫 + 巡逻车 + 封锁线。

布景的风险不在功能，在"悄悄多出一堆 NPC 和物件"：
所以闸门盯 上限、观感专用（不战斗）、可一键关、以及授权走服务端。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
SCENERY = RES / "client/scenery.lua"
LOCKDOWN = RES / "client/lockdown.lua"
PA = RES / "server/pa.lua"


def test_scenery_is_capped_cosmetic_and_killable() -> None:
    src = SCENERY.read_text(encoding="utf-8")

    # 一键关 + 硬上限
    assert "GetConvar('police_scenery', '1')" in src
    assert "MAX_GUARDS" in src, "守卫数量必须封顶"
    # 观感专用：无敌、不参战、不放武器
    assert "SetEntityInvincible(ped, true)" in src
    assert "DoesEntityExist" in src, "布景要有回收判断"
    assert "TaskCombatPed" not in src, "布景不得进入战斗"
    assert "GiveWeaponToPed" not in src, "守卫不配武器"
    # 只在站点附近生成、离远自动收（客户端布景的正确姿势）
    assert "SPAWN_DISTANCE" in src and "DESPAWN_DISTANCE" in src
    assert "onResourceStop" in src and "despawn()" in src
    # 巡逻车不追人
    assert "TaskVehicleDriveToCoordLongrange" in src
    assert "TaskVehicleChase" not in src


def test_lockdown_is_server_authorised_and_self_clearing() -> None:
    client = LOCKDOWN.read_text(encoding="utf-8")
    server = PA.read_text(encoding="utf-8")

    # 客户端命令只发请求；真正的摆放由服务端授权的回调触发
    assert "TriggerServerEvent('police:server:lockdownRequest')" in client
    assert "police:client:LockdownPlace" in client
    at = client.find("RegisterCommand('lockdown'")
    block = client[at:client.find("police:client:LockdownPlace", at)]
    assert "CreateObject" not in block, "命令本身不许直接摆物件（要先过服务端）"

    # 服务端授权：在岗 + 能力
    assert "police:server:lockdownRequest" in server
    assert "PolicePolicy.Can(data, 'incident.update')" in server
    # 自动收 + 手动收
    assert "LIFETIME_MS" in client and "auto-cleared" in client
    assert "mode == 'clear'" in client
