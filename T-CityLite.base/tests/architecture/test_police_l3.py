"""L3 反应层的两件新东西：扩音器喊话（/pa）与包围（/backup surround）。

这一层最容易越界的两个方向：
* 喊话变成刷屏/广播工具 → 必须限定在岗、半径、冷却，且审计不落正文；
* 包围变成"接管 AI" → 只能动自己名下的单位，且不碰战斗逻辑。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
PA_SERVER = RES / "server/pa.lua"
PA_CLIENT = RES / "client/pa.lua"
BACKUP = RES / "client/backup.lua"


def test_pa_is_scoped_and_audits_without_the_text() -> None:
    src = PA_SERVER.read_text(encoding="utf-8")

    # 在岗 + 能力
    assert "PolicePolicy.Can(data, 'incident.update')" in src
    assert "onduty ~= true" in src
    # 半径与冷却
    assert "PA_RADIUS" in src and "PA_COOLDOWN_SECONDS" in src
    # 长度与清洗
    assert "PA_MAX_LEN" in src and "gsub('%c'" in src
    # 只有附近玩家能听见（按距离广播，不是全服）
    assert "#(GetEntityCoords(targetPed) - origin) <= PA_RADIUS" in src
    # 审计只记长度与人数，不记正文
    assert "len=%d;heard=%d" in src
    assert "body)" not in src.split("audit(cid")[-1][:200]
    # 可一键关
    assert "GetConvar('police_pa', '1')" in src


def test_surround_only_moves_the_callers_own_units() -> None:
    src = BACKUP.read_text(encoding="utf-8")

    assert "surround = true" in src, "包围必须进命令白名单"
    assert "local function surroundPeds" in src
    assert "TaskGoToCoordAnyMeans" in src
    # 站位用请求者做锚点，且只在 active（自己名下）里遍历
    at = src.find("local function surroundPeds")
    block = src[at:at + 1200]
    assert "GetEntityCoords(anchorPed)" in block
    # 不碰战斗：包围里不出现 TaskCombat
    assert "TaskCombatPed" not in block
    # 回执文案带上新命令
    assert "follow|hold|dismiss|surround" in src
