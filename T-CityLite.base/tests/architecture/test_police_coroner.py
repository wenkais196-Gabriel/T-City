"""L2 后勤层·验尸官（蓝图 §6.2）的闸门。

这一层的风险不是"好不好看"，而是三件事：
* 谁能叫（只能在岗警察，且要走名额）；
* 会不会赖着不走（服务端寿命 + 掉线回收）；
* 会不会自己发明一套生成逻辑（必须复用支援单位的路网取点）。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
SERVER = RES / "server/coroner.lua"
CLIENT = RES / "client/coroner.lua"
BUDGET = RES / "shared/npc_budget.lua"


def _read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def test_coroner_is_officer_only_budgeted_and_expires() -> None:
    src = _read(SERVER)

    # 只能在岗警察叫
    assert "PolicePolicy.Can(data, 'incident.update')" in src and "onduty ~= true" in src
    # 名额走统一预算表，不自己数
    assert "NPCBudget" in src and "Acquire('coroner'" in src
    assert "coroner" in _read(BUDGET), "coroner 必须在 SLOT_COST 里"
    # 寿命与冷却
    assert "CORONER_TTL_SECONDS" in src and "CORONER_COOLDOWN_SECONDS" in src
    assert "police:client:CoronerEnd" in src, "到点要先让客户端收车"
    # 掉线回收
    assert "playerDropped" in src and "releaseRequest(requestId, 'dropped')" in src
    # 审计四态
    for event in ("coroner.request", "coroner.ended", "coroner.rejected"):
        assert event in src, "缺少审计事件 " + event
    # 开发后门默认关、只接受控制台
    assert "GetConvar('police_coroner_dev_enabled', '0')" in src
    assert "if source ~= 0 then return end" in src


def test_coroner_reuses_the_road_spawn_and_removes_the_body() -> None:
    src = _read(CLIENT)

    # 复用支援单位的路网取点，不另造一套
    assert "BackupFindRoadNode" in src, "必须复用支援单位的路网取点"
    assert "GetNthClosestVehicleNodeFavourDirection" not in src, "不要自己写第二份取点逻辑"
    # 取不到路网就干净失败，而不是在沙滩上生成
    assert "no road node for the van" in src
    assert "TriggerServerEvent('police:server:coronerDone', requestId, 'no_road')" in src
    # 抬尸体的可见证据：尸体必须被删掉
    assert "deleteEntity(corpse)" in src
    # 抬完要走，不留人
    assert "TaskVehicleDriveWander" in src
    # 兜底的清理入口
    assert "RegisterNetEvent('police:client:CoronerEnd'" in src


def test_backup_exposes_the_road_spawn_helper() -> None:
    src = _read(RES / "client/backup.lua")
    assert "BackupFindRoadNode = findSpawnNode" in src, (
        "验尸官要复用同一套取点规则，必须把它挂成全局"
    )

def test_coroner_has_a_real_entry_point() -> None:
    """除了调试后门，必须有一条玩家能按的正式入口。

    调试后门（`police_coroner_dev`）默认关，不能当作玩法入口；
    `/coroner` 自己只负责"找到那具尸体"，在岗与名额仍由服务端复验。
    """
    src = _read(CLIENT)
    assert "RegisterCommand('coroner'" in src, "缺少 /coroner 命令"
    assert "police:server:coronerRequest" in src, "命令必须走服务端那条事件"
    assert "no_body" in src, "附近没尸体要给明确反馈"
    # 调试事件只许造场景，不许替玩家叫单
    at = src.find("police:client:CoronerDevCorpse")
    block = src[at:at + 1200]
    assert "coronerRequest" not in block, "调试入口不该代替玩家按 /coroner"
