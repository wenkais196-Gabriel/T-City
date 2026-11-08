"""P1-3 批 8：qb-weathersync / qb-garages 的越权守卫。

两个资源的问题性质不同：

- qb-weathersync 本来就有 `isAllowedToChange`（控制台 / admin ACE），但写成了
  `if isAllowedToChange(src) then ...` 的正分支，闸门只认 deny-early 形状 → 6 个事件在基线上被
  记为"未登记"。真正缺的是另外两处：`RequestStateSync` 没有冷却（任何玩家连点就能让服务端
  向全服刷同步包），`QBCore:Server:OnPlayerLoaded` 没有来源校验（客户端可以自己触发）。
- qb-garages 是货真价实的洞：取车回调 `spawnvehicle(plate, vehicle, coords)` 三个参数全来自
  客户端，服务端只查"在外车辆数"和"驾照等级" —— 别人的车牌、随便什么车型、全图任意坐标都能
  生成；`syncGarage` 任何玩家都能用一张自造的表覆盖全服车库配置；`PayDepotPrice` 按车牌查价
  不查归属。

探针真加载资源的 `config.lua` + 服务端脚本，mock FiveM 运行时后直接调用 handler / callback。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
LUA = "lua5.4"


def _run(probe: str, resource: str) -> dict[str, list[str]]:
    proc = subprocess.run(
        [LUA, (FIXTURES / probe).as_posix(), (BASE / "resources" / "[qb]" / resource).as_posix()],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, list[str]] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, []).append(value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


def _flag(data: dict[str, list[str]], key: str) -> bool:
    return data[key][0] == "true"


# ══════════════════════════════════════════════════════════════════
# qb-garages
# ══════════════════════════════════════════════════════════════════


def test_spawnvehicle_rejects_plate_that_is_not_yours():
    """取车回调不能拿别人的车牌生成载具。

    旧版只看"在外车辆数 + 驾照等级"，`plate` 从不校验归属 —— 拿别人的车牌就能把别人的车
    生成在自己脚下（同时把对方那台车标记为"在外"）。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "SPAWN_OK"), "自己的车 + 合法坐标反而被拒（过度收紧）"
    assert _flag(data, "SPAWN_OTHERS"), "别人的车牌仍然能生成"


def test_spawnvehicle_rejects_model_that_does_not_match_the_row():
    """车型必须与 player_vehicles 里登记的一致。

    旧版 `vehicle` 完全采信客户端：用自己的车牌 + 任意模型（喷气机、装甲车）就能生成，
    只要 `QBCore.Shared.Vehicles[model]` 存在。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "SPAWN_MISMATCH"), "车型不符仍然放行"


def test_spawnvehicle_rejects_spawn_point_far_from_the_player():
    """生成点必须在玩家附近。

    旧版 `coords` 直接透传，等于"全图任意点刷车"（可以刷进别人家、刷到地图边缘）。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "SPAWN_FAR"), "5000 米外的坐标仍然能生成"


def test_spawnvehicle_accepts_fivem_vector_types():
    """取车回调的坐标是 `GetSpawnPoint()` 的返回值 —— 真机上是 **vector4**，不是 table。

    第一版只认 `type(coords) == 'table'`，会把所有正常取车（公共车库 / 房车 / 赎车）全拒掉。
    纯 Lua 造不出 FiveM 的 vector4，所以这里分两段：
    - 运行时：table 形状必须被接受，缺 z / 非坐标类型必须被拒；
    - 静态：守卫必须显式列出 vector3 / vector4（否则又会退化成只认 table）。
    """
    source = (BASE / "resources" / "[qb]" / "qb-garages" / "server" / "main.lua").read_text(encoding="utf-8")
    assert "vector4" in source and "vector3" in source, "坐标守卫没有接受 vector3/vector4"
    assert "ctype ~= 'vector4'" in source, "守卫没有把 vector4 当成合法坐标类型"
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "SPAWN_OK"), "table 形状的合法坐标被拒"
    assert _flag(data, "SPAWN_BAD_COORDS"), "非坐标类型仍然放行"
    assert _flag(data, "SPAWN_MISSING_Z"), "缺 z 的坐标仍然放行"


def test_sync_garage_merges_house_entries_without_letting_players_rewrite_public_ones():
    """`syncGarage` 不能"全挡"，也不能"全收"。

    客户端在 qb-houses 建房/加载房车时会把**整张** `Config.Garages` 发给服务端（含 `type='house'`）。
    全挡：服务端缺房车条目 → `canDeposit` 里 `Config.Garages[garage].houseName` 索引 nil 崩掉，
    房车存不了车。全收：任何玩家都能改公共车库的点位与开关。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "SYNC_PUBLIC_UNTOUCHED"), "玩家仍然改写了公共车库条目"
    assert _flag(data, "SYNC_HOUSE_MERGED"), "玩家的房车条目没有被合并（房车存车会崩）"
    assert _flag(data, "SYNC_FOREIGN_HOUSE_REJECTED"), "houselocations 里没有的房车条目被接受"
    assert _flag(data, "SYNC_FAR_HOUSE_POINT_REJECTED"), (
        "房车点位与 houselocations.garage 相差 5 公里也被接受（等于任意坐标刷车）"
    )


def test_sync_garage_requires_admin():
    """`syncGarage` 会整表覆盖 `Config.Garages`。

    旧版无任何鉴权：任何玩家发一张自造的表，就能改掉全服所有车库的点数、位置、开关。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "SYNC_BLOCKED_FOR_PLAYER"), "普通玩家仍能覆盖全服车库配置"
    assert _flag(data, "SYNC_ALLOWED_FOR_ADMIN"), "管理员反而改不了（过度收紧）"


def test_depot_payment_requires_ownership_and_impound_state():
    """赎车只能赎自己名下、且处于扣押状态的车。

    旧版 `PayDepotPrice(data)` 只按 `data.plate` 查价，不查 citizenid、不查 state：
    别人的车（价格合适时）也能被"赎"出来，停在库里的车也能直接召唤。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "DEPOT_OTHERS"), "别人的车仍然能赎"
    assert _flag(data, "DEPOT_NOT_IMPOUNDED"), "没被扣押的车仍能通过赎车通道取车"
    assert _flag(data, "DEPOT_IMPOUNDED"), "自己的扣押车反而赎不出来（过度收紧）"
    assert _flag(data, "DEPOT_PRICE_ONLY"), (
        "只有 depotprice 而 state=0 的车赎不出来（AutoRespawn=false 的服务器会整体失效）"
    )


def test_outside_vehicle_registry_is_owner_scoped_and_clearable():
    """`UpdateOutsideVehicle` 由"谁的车"和"存车时清空"两个语义组成。

    旧版两处都不对：任何玩家都能把别人的车牌登记成"在外"（同时污染 `trackVehicle` 的坐标），
    而存车时客户端传的 `nil` 会被写成 `{netID = nil, entity = 0}` —— 条目仍在表里，
    `IsSpawnOk` 会一直认为车在外面，玩家存车后再也取不出来。
    """
    data = _run("garages_probe.lua", "qb-garages")
    assert _flag(data, "OUTSIDE_SET"), "自己的车登记不进 OutsideVehicles"
    assert _flag(data, "OUTSIDE_CLEARED"), "存车后条目没被清掉（会卡住 IsSpawnOk）"
    assert _flag(data, "OUTSIDE_OTHERS_BLOCKED"), "别人的车牌仍能登记成「在外」"


# ══════════════════════════════════════════════════════════════════
# qb-weathersync
# ══════════════════════════════════════════════════════════════════


def test_weather_changes_stay_admin_only():
    """改天气仍然只允许控制台 / admin —— 重构不能把这条放宽。"""
    data = _run("weathersync_probe.lua", "qb-weathersync")
    assert _flag(data, "WEATHER_UNCHANGED"), "普通玩家改动了天气"
    assert _flag(data, "WEATHER_CHANGED"), "管理员改不动天气（过度收紧）"


def test_state_sync_is_rate_limited_per_player():
    """`RequestStateSync` 会向全服广播两条同步包 → 每玩家 5 秒一次。

    旧版无冷却：一个人连点 N 次就是 2N 条全服广播。
    """
    data = _run("weathersync_probe.lua", "qb-weathersync")
    assert data["BROADCASTS_FROM_TWO_CALLS"][0] == "2", (
        "连续两次 RequestStateSync 产生了 "
        f"{data['BROADCASTS_FROM_TWO_CALLS'][0]} 条广播（期望 2 = 只有第一次生效）"
    )


def test_client_cannot_trigger_onplayerloaded():
    """`QBCore:Server:OnPlayerLoaded` 是服务端内部事件，客户端不该能触发。"""
    data = _run("weathersync_probe.lua", "qb-weathersync")
    assert data["BROADCASTS_FROM_CLIENT_TRIGGER"][0] == "0", "客户端触发了 OnPlayerLoaded 并产生了全服广播"
