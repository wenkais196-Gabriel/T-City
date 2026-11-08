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

    # 入口：未开放不能加入（断言 racer 真的没进去）、没开赛不能报成绩、开赛后能加入
    assert data["JOINED_WHEN_CLOSED"][0] == "0", "未开放的赛道仍然把车手加进去了"
    assert data["RECORD_WRITES_WITHOUT_START"][0] == "0", "没 StartRace 也能写成绩"
    assert data["JOIN_WORKS_AFTER_START"][0] == "true", "开赛后车手加不进去"

    # 伪造成绩：0.001 / 最佳圈大于平均圈 / 圈数不符，全部拒绝
    assert data["RECORD_WRITES_CHEAT"][0] == "0", "BestLap=0.001 仍能写纪录"
    assert data["RECORD_WRITES_BESTLAP_OVER_AVERAGE"][0] == "0", "最佳圈比平均圈还慢也能写纪录"
    assert data["RECORD_WRITES_LAPS_MISMATCH"][0] == "0", "客户端少报圈数能绕过均值校验"

    # 合法成绩（10 圈 / 200 秒 / 最佳圈 18 秒）：写一次、原样保留、不可重放
    assert data["RECORD_WRITES_NORMAL"][0] == "1", "合法完赛没有结算"
    assert data["RECORD_TIME"][0] == "18", "合法最佳圈被改写"
    assert data["RECORD_WRITES_REPLAY"][0] == "0", "重复 FinishPlayer 二次结算"

    # 清理（直接读 handler 闭包里的私有表，不靠"还能不能 Join"这种弱信号）
    assert data["AFTER_SETTLE_RACERS"][0] == "0", "全员完赛后 Racers 没清空"
    assert data["AFTER_SETTLE_STARTEDAT"][0] == "nil", "全员完赛后 StartedAt 没清（下一场会沿用旧计时）"
    assert data["AFTER_SETTLE_AVAILABLE"][0] == "0", "全员完赛后比赛还挂在开放列表里"
    assert data["AFTER_LEAVE_RACERS"][0] == "0", "反序离开后 Racers 没清空"
    assert data["AFTER_LEAVE_STARTED"][0] == "false", "反序离开后 Started 没复位"
    assert data["AFTER_LEAVE_WAITING"][0] == "false", "反序离开后 Waiting 没复位"
    assert data["AFTER_LEAVE_STARTEDAT"][0] == "nil", "反序离开后 StartedAt 没清"
    assert data["AFTER_LEAVE_AVAILABLE"][0] == "0", "反序离开后比赛还挂在开放列表里"
    assert data["AFTER_LEAVE_NOTFINISHED"][0] == "0", "反序离开后 NotFinished 残留（下次会被并进新比赛）"
    assert data["AFTER_LEAVE_LASTRACES"][0] == "0", "反序离开后 LastRaces 残留"
    assert data["REOPEN_AFTER_LEAVE"][0] == "true", "清理后作者无法重新开放同一条赛道"
    assert data["AFTER_REOPEN_LEADERBOARD"][0] == "0", "重开赛道后 LastLeaderboard 还挂着上一场的成绩"
