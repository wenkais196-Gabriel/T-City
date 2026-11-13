"""R1 · P3：bus 的站点谱配置。

与 garbage 同构（报到 → N 站 → 交回），所以这里钉的是 bus 自己的三件事：

1. **三档站数与金额**：6/8/10 站，$486/$648/$810（站×90×0.9，见 `02-design.md` §2.3）；
2. **职业与声望键是 bus**：写错会让校验器判 `wrong_job`，或声望记到别的职业上；
3. **配置 → 校验器载荷 → 校验器** 整条链接得上（coords 必须在 `validator_data` 里）。

准点率（punctuality ∈ [0.8, 1.1]）v1 不做：现有 `CalculateTimeBonus` 只覆盖物流追踪链，
bus 没有对应追踪器。记在 `03-plan.md` §7。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_probe import run_probe  # noqa: E402

RES = "[custom]/custom-quest"
CONFIG = "quest_bus.lua"

#: 站数 / 金额（站×90×0.9）
EXPECTED = {
    "bus_v1_city": (6, 486),
    "bus_v1_crosstown": (8, 648),
    "bus_v1_full": (10, 810),
}


def _tasks() -> dict[str, list[str]]:
    data = run_probe("route_config_probe.lua", RES, extra_args=[CONFIG])
    assert data["LOAD_OK"] == "true", f"{CONFIG} 加载失败"
    assert data["TASK_COUNT"] == str(len(EXPECTED)), f"任务数不对：{data['TASK_COUNT']}"
    return {f"TASK_{i}": data[f"TASK_{i}"].split("|") for i in (1, 2, 3)}


def test_three_lines_with_expected_stops_and_money():
    seen = set()
    for key, row in _tasks().items():
        quest_id, stations = row[0], int(row[1])
        money_min, money_max = int(row[2]), int(row[3])
        assert quest_id in EXPECTED, f"{key} 的 id 不在预期里：{quest_id}"
        want_stops, want_money = EXPECTED[quest_id]
        assert stations == want_stops, f"{quest_id}: 站点 {stations} 个，期望 {want_stops}"
        assert (money_min, money_max) == (want_money, want_money), (
            f"{quest_id}: 金额 {money_min}-{money_max}，期望固定 {want_money}"
        )
        assert row[4] == "bus", f"{quest_id}: 声望键是 {row[4]}，期望 bus"
        assert row[11] == "bus", f"{quest_id}: validator_data.job 是 {row[11]}，期望 bus（否则判 wrong_job）"
        seen.add(quest_id)
    assert seen == set(EXPECTED), f"缺少任务：{set(EXPECTED) - seen}"


def test_step_shape_is_sane():
    for key, row in _tasks().items():
        quest_id = row[0]
        assert row[7] == "true", f"{quest_id}: 站号不连续（跳号 → 玩家卡站）"
        assert row[8] == "true", f"{quest_id}: 站点缺 validator_id/require_duty/coords/radius，或坐标重复"
        assert row[9] == "interact", f"{quest_id}: 第一步不是签到"
        assert row[10] == "interact", f"{quest_id}: 最后一步不是交班（任务不会结算）"


def test_config_payload_reaches_the_validator():
    data = run_probe("route_integration_probe.lua", RES, extra_args=[CONFIG])
    assert data["CONFIG_JOB"] == "bus", f"集成 probe 取到的职业是 {data.get('CONFIG_JOB')}"
    assert data["PAYLOAD_HAS_COORDS"] == "true", "校验器载荷里没有服务端坐标（走到站按 E 会没反应）"
    assert data["PAYLOAD_HAS_INDEX"] == "true", "载荷里的站号不是 1"
    assert data["INTEGRATION_FIRST_STOP"] == "true|ok", (
        f"站在正确坐标上也过不了第一站：{data.get('INTEGRATION_FIRST_STOP')}"
    )
