"""L2 后勤·拖车（蓝图 §6.2，方案 A：只拖 NPC 残骸）的闸门。

这一片最怕的是**把玩家的车拖走或删掉**，其次是赖着不走。
所以闸门盯三件事：归属校验在服务端、生命周期在服务端、生成复用路网规则。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
SERVER = RES / "server/tow.lua"
CLIENT = RES / "client/tow.lua"
BUDGET = RES / "shared/npc_budget.lua"


def test_tow_refuses_player_owned_cars_server_side() -> None:
    src = SERVER.read_text(encoding="utf-8")

    # 归属查库，不信客户端：plate 必须回查 player_vehicles
    assert "player_vehicles" in src, "必须查归属表"
    assert "LIMIT 1" in src, "查询要带 LIMIT"
    assert "plateBelongsToPlayer" in src
    assert "TriggerClientEvent('police:client:TowDenied', src, 'player_owned')" in src

    # 生命周期与名额
    assert "NPCBudget" in src and "Acquire('tow'" in src
    assert "tow" in BUDGET.read_text(encoding="utf-8"), "tow 必须在 SLOT_COST 里"
    assert "TOW_TTL_SECONDS" in src and "TOW_COOLDOWN_SECONDS" in src
    assert "police:client:TowEnd" in src
    assert "playerDropped" in src
    for event in ("tow.request", "tow.ended", "tow.rejected"):
        assert event in src, "缺少审计事件 " + event
    # 后门默认关、只接受控制台
    assert "GetConvar('police_tow_dev_enabled', '0')" in src
    assert "if source ~= 0 then return end" in src


def test_tow_drags_and_removes_the_wreck() -> None:
    src = CLIENT.read_text(encoding="utf-8")

    # 复用同一套路网取点；取不到就干净失败
    assert "BackupFindRoadNode" in src
    assert "no_road" in src
    # 只挂 NPC 残骸：目标必须"没人 + 报废"
    assert "GetVehicleEngineHealth(veh) <= 350.0" in src
    assert "GetPedInVehicleSeat" in src
    # 挂上、拖走、回收
    assert "AttachEntityToEntity" in src
    assert "DetachEntity" in src
    assert "TaskVehicleDriveWander" in src
    assert "RegisterNetEvent('police:client:TowEnd'" in src
    # 调试入口只造场景
    at = src.find("police:client:TowDevWreck")
    block = src[at:at + 1200]
    assert "towRequest" not in block, "调试入口不该替玩家按 /tow"
