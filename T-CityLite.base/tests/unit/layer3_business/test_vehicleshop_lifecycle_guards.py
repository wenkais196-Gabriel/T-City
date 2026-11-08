"""P1-3 批 10：qb-vehicleshop 的试驾/展车/分期生命周期。

批 3 已经把分期付款、代客售车这几个"钱"的面改成了服务端权威；这次剩下的 7 个事件（外加
一个同样来自客户端的试驾生成回调）集中在**实体与配置**这一层：

- `spawnvehicle(plate, vehicle, coords)` 回调：`vehicle` 直接进 `GetHashKey`、`coords` 直接进
  生成函数 —— 任何玩家能在任意坐标生成任意载具。
- `deleteVehicle(netId, plate)`：`netId` 直接进 `DeleteEntity` —— 任意 netId 就是任意实体
  （别人的车、NPC、玩家）。
- `swapVehicle(data)`：向**全服**广播客户端给的 `data` —— 改所有人的展车。
- `customTestDrive(vehicle, playerid)`：任何玩家给任意人发任意车型（含警车/飞机）。
- `addPlayer/removePlayer(citizenid)`：citizenid 由客户端传 —— 重置/结算**别人**的分期计时器。
- `checkFinance()`：`player` 为 nil 时直接索引 `player.PlayerData` 抛错；且 handler 里有
  `Wait(Config.PaymentWarning * 60000)`，连点会堆睡眠线程。

探针真加载 config + server/bus.lua + server/finance-lifecycle.lua。
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
            (FIXTURES / "vehicleshop_probe.lua").as_posix(),
            (BASE / "resources" / "[qb]" / "qb-vehicleshop").as_posix(),
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
        if key in data:
            continue
        data[key] = value
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


def test_test_drive_spawn_only_accepts_showroom_models():
    """试驾生成回调不能生成展台里没有的车型。"""
    data = _run()
    assert data["SPAWN_FOREIGN_MODEL_BLOCKED"] == "true", "展台里没有的车型也能生成"
    assert data["SPAWN_OK"] == "true", "展台上的车反而生成不了（过度收紧）"


def test_test_drive_spawn_coordinates_must_be_at_the_shop():
    """只在店里还不够：请求的生成点也必须在这家店的试驾点附近。

    否则站在店里就能把车刷到地图另一头（然后 warp 过去）。
    """
    data = _run()
    assert data["SPAWN_FAR_BLOCKED"] == "true", "5 公里外的生成点仍然被接受"


def test_delete_vehicle_only_deletes_your_own_test_drive():
    """`deleteVehicle(netId)` 不能删任意实体。"""
    data = _run()
    assert data["DELETE_FOREIGN_BLOCKED"] == "true", "别人能删掉你的试驾车"
    assert data["DELETE_OWN_ALLOWED"] == "true", "自己的试驾车反而删不掉（过度收紧）"
    assert data["DELETE_REPLAY_BLOCKED"] == "true", "同一个 netId 可以重复删除"


def test_showroom_swap_requires_an_on_duty_dealer():
    """换展车会向全服广播，只有在职店员能做。"""
    data = _run()
    assert data["SWAP_CIVILIAN_BLOCKED"] == "true", "平民能改全服展车"
    assert data["SWAP_OFFDUTY_BLOCKED"] == "true", "下班的店员也能改"
    assert data["SWAP_DEALER_ALLOWED"] == "true", "在职店员反而改不了（过度收紧）"


def test_staff_test_drive_requires_a_dealer_and_a_showroom_model():
    """员工发试驾：只有在职店员、且车型必须在展台上。"""
    data = _run()
    assert data["TESTDRIVE_CIVILIAN_BLOCKED"] == "true", "平民能给任意玩家发试驾"
    assert data["TESTDRIVE_FOREIGN_MODEL_BLOCKED"] == "true", "能给任意车型（警车/飞机）发试驾"


def test_finance_timer_is_bound_to_the_caller():
    """`addPlayer/removePlayer` 的 citizenid 必须取自调用者本人。"""
    data = _run()
    assert data["TIMER_VICTIM_UNTOUCHED"] == "true", "能重置别人的分期计时起点"
    assert data["TIMER_SELF_SET"] == "true", "自己的计时器反而没启动（过度收紧）"


def test_check_finance_survives_a_missing_player():
    """`checkFinance` 在 player 为 nil 时不能抛错（原来直接索引 `player.PlayerData`）。"""
    data = _run()
    assert data["CHECKFINANCE_MISSING_PLAYER_SAFE"] == "true", "player 不存在时 handler 抛错"
    assert data["CHECKFINANCE_NO_CRASH"] == "true", "正常玩家调用时抛错"
