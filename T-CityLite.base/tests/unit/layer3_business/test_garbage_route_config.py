"""R1 · P2：garbage 的站点谱配置（形状 + 数值 + id 唯一）。

三档任务共用一份 `buildSteps()`，所以最该钉住的不是"有几步"，而是：

1. **validator 步骤的站号必须连续且从 1 开始** —— 校验器按"只能完成下一站"判，
   配置里跳一个号，玩家就卡在那一站（真机上表现为"到了点没反应"）；
2. **每站带 job/require_duty/radius** —— 缺一个就等于放弃服务端校验；
3. **首尾是 interact（报到/交回）** —— 没有交回那一步，任务永远不会结算；
4. **金额 = 站数×30 + 袋数×25** —— 与 `02-design.md` §2.3 对得上；
5. **坐标不重复** —— 同一站写两遍会让两站都能过，等于白送一站的钱。

另外查一次跨文件的 id 冲突：quest id 撞了会让注册表后写覆盖先写。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_probe import BASE, run_probe  # noqa: E402

RES = "[custom]/custom-quest"
CONFIG_DIR = BASE / "resources/[custom]/custom-quest/config/quests"

#: 三档的期望值（站数 / 金额）—— 金额 = 站×30 + 袋×25，见 02-design.md §2.3
EXPECTED = {
    "garbage_v1_city": (4, 370),
    "garbage_v1_district": (6, 705),
    "garbage_v1_full": (8, 1140),
}


def _tasks() -> dict[str, list[str]]:
    data = run_probe("garbage_config_probe.lua", RES)
    assert data["LOAD_OK"] == "true", "quest_garbage.lua 加载失败（语法或返回形状不对）"
    assert data["TASK_COUNT"] == str(len(EXPECTED)), f"任务数不对：{data['TASK_COUNT']}"
    return {f"TASK_{i}": (data[f"TASK_{i}"].split("|") if f"TASK_{i}" in data else []) for i in (1, 2, 3)}


def test_three_tiers_with_expected_stops_and_money():
    tasks = _tasks()
    seen = {}
    for key, row in tasks.items():
        # id|stations|min|max|rep|level|orderOk|metaOk|firstType|lastType
        quest_id = row[0]
        stations = int(row[1])
        money_min, money_max = int(row[2]), int(row[3])
        assert quest_id in EXPECTED, f"{key} 的 id 不在预期里：{quest_id}"
        want_stops, want_money = EXPECTED[quest_id]
        assert stations == want_stops, f"{quest_id}: validator 步骤 {stations} 个，期望 {want_stops}"
        assert (money_min, money_max) == (want_money, want_money), (
            f"{quest_id}: 金额 {money_min}-{money_max}，期望固定 {want_money}（站×30 + 袋×25）"
        )
        seen[quest_id] = True
    assert set(seen) == set(EXPECTED), f"缺少任务：{set(EXPECTED) - set(seen)}"


def test_step_order_and_metadata_are_sane():
    tasks = _tasks()
    for key, row in tasks.items():
        quest_id = row[0]
        assert row[6] == "true", f"{quest_id}: validator 站号不连续（配置里跳了号 → 玩家会卡站）"
        assert row[7] == "true", (
            f"{quest_id}: 某个收运点缺 validator_id / job / require_duty / coords / radius，或坐标重复"
        )
        assert row[8] == "interact", f"{quest_id}: 第一步不是 interact（报到）"
        assert row[9] == "interact", f"{quest_id}: 最后一步不是 interact（交回），任务不会结算"


def test_quest_ids_are_globally_unique():
    """quest id 撞了会让注册表后写覆盖先写 —— 这类问题只会表现为"任务不见了"。"""
    pattern = re.compile(r"^\s{4,12}id\s*=\s*'((?:garbage|bus|taxi|trucker|tow|recycle|hotdog|reporter)_[a-z0-9_]+)'", re.M)
    owners: dict[str, list[str]] = {}
    for path in CONFIG_DIR.rglob("*.lua"):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in pattern.finditer(text):
            owners.setdefault(match.group(1), []).append(path.name)

    clashes = {qid: files for qid, files in owners.items() if len(files) > 1}
    assert not clashes, f"任务 id 重名：{clashes}"


def test_config_payload_reaches_the_validator():
    """配置 → ValidatorPayload → validate_route_stop 的整条链必须接得上。

    `ValidatorPayload` 只给 `validator_data` + 白名单 meta，而 `coords` 不在白名单里：
    坐标只写在顶层 `data.coords` 的话，校验器拿到 nil，每站都判 `no_coords`
    （真机表现：走到点、按 E 没反应）。这条是我第一版配置里的真 bug。
    """
    data = run_probe("route_integration_probe.lua", RES)
    assert data["HAS_VALIDATOR_STEP"] == "true", "第一档任务里没有 validator 步骤"
    assert data["REGISTERED"] == "true", "validate_route_stop 没注册"
    assert data["PAYLOAD_HAS_COORDS"] == "true", (
        "校验器载荷里没有服务端坐标 —— 配置只把 coords 写在顶层，没写进 validator_data"
    )
    assert data["PAYLOAD_HAS_INDEX"] == "true", "载荷里的站号不是 1（ValidatorPayload 没带 validator_data）"
    assert data["INTEGRATION_FIRST_STOP"] == "true|ok", (
        f"站着正确坐标上也过不了第一站：{data.get('INTEGRATION_FIRST_STOP')}"
    )
