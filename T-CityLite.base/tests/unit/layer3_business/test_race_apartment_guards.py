"""qb-lapraces / qb-apartments：两个 Lua 沙箱探针的运行级断言。

为什么需要运行级测试：这两个资源的修复全是「handler 里加判空/加授权」，静态闸门
（net_event_scan）只能证明"调用形状对"，证明不了"事件触发时不崩、正常流程还能走通"。
CC 验收实测过反例：形参写成 `type` 遮蔽全局 `type()`，静态闸门全绿但事件一触发就
`attempt to call a string value`。

| 探针场景 | 旧实现（daa0dfb6） | 现在 |
|---|---|---|
| `JoinRace` 传"已保存但未开放"的 RaceId | `attempt to index a nil value` 崩，且把赛道卡成"运行中" | 直接返回，赛道仍可被作者开放 |
| 正常完赛（客户端顺序：UpdateRacerData(true) → FinishPlayer） | 崩在 `Races[RaceId]`，成绩永远不结算 | 写 1 条记录并结算 |
| `BestLap = 0.001` 刷纪录 | 崩 | 0 条记录写入 |
| 重复 `FinishPlayer` | 崩 | 0 条（独立 FinishHandled 防重放） |
| `CancelRace({})` | `attempt to concatenate a table value` | 无错误 |
| `CreateApartment('apartment1', ...)` | 建得出来，但**非法 type 也照建** | 合法 type 建 1 条，非法 0 条 |
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(resource: str, probe: str) -> dict[str, list[str]]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / "[qb]" / resource).as_posix()],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"probe 失败：\n{proc.stderr}\n{proc.stdout}"
    parsed: dict[str, list[str]] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        parsed.setdefault(key, []).append(value)
    return parsed


def test_apartment_create_and_update_still_work_and_reject_bad_types():
    data = _run("qb-apartments", "apartments_probe.lua")
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    assert data["INSERTED"][0] == "1", "合法类型的公寓建不出来（形参遮蔽 type 会直接崩在这里）"
    assert data["INSERTED_BAD"][0] == "0", "非法 apartmentType 被写进库"
    assert data["UPDATED"][0] == "1", "改公寓失败"
    assert data["UPDATED_BAD"][0] == "0", "非法类型也能改公寓"


def test_race_finish_settles_once_and_survives_bad_payloads():
    data = _run("qb-lapraces", "lapraces_probe.lua")
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    # 未开放的赛道：不回错、不把赛道卡成"运行中"
    assert data["JOIN_OK"][0] == "true", "JoinRace 对未开放的 RaceId 崩了"
    assert data["JOIN_WORKS_AFTER_SETUP"][0] == "true", "作者开放赛道后车手仍然加不进去"
    # 成绩：0.001 拒绝、正常结算 1 次、重复结算 0 次
    assert data["RECORD_WRITES_AFTER_CHEAT"][0] == "0", "BestLap=0.001 仍能写纪录"
    assert data["RECORD_WRITES_AFTER_NORMAL"][0] == "1", "正常完赛没有结算（racer.Finished 又把自己挡住了？）"
    assert data["RECORD_WRITES_AFTER_REPLAY"][0] == "0", "重复 FinishPlayer 二次结算"


# 变异证据（本机实测，改动 handler 才复现；不需要入闸门也要留档）：
#   * `racer.FinishHandled` → `racer.Finished`（回到 CC 抓到的 B2）：
#     RECORD_WRITES_AFTER_NORMAL 从 1 变 0 —— 这条断言真的在测"正常完赛能不能结算"。
#   * 把 `local startedAt = Races[raceId].StartedAt` 改成 `nil`（去掉服务端对账）：
#     RECORD_WRITES_AFTER_CHEAT 从 0 变 1 —— 这条断言真的在测 0.001 刷记录。
