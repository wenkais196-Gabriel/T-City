"""P1-3 批 17：qb-adminmenu / custom-justice / qb-hud / qb-scoreboard。

- `qb-admin:server:GetPlayersForBlips` 原本**没有任何权限校验**：谁发谁拿。它下发的
  `qb-admin:client:Show` 是**全服玩家的名字 + 实时坐标**，等于把 wallhack 发给所有人
  （客户端那边是轮询的，所以拿到手就是持续跟踪）。客户端只在管理员打开 blips 开关时才轮询，
  所以服务端按 admin 权限对齐不会堵死任何职能。
- `custom-justice` 的 `justice:server:imprison` **本来就是**警察/法官限定，只是写成正分支
  `if job ~= 'police' and job ~= 'judge' then ... return end`，闸门认不出形状。抽成
  `IsLawEnforcement(Player)` 并登记，行为零变化（探针对旧版跑同样通过）。
- `hud:server:GainStress/RelieveStress(amount)` 的 `amount` 全来自客户端：表/字符串会让
  `currentStress + amount` 直接抛错打断事件线程，超大数字可以一键把压力拉满/清零。
- `qb-scoreboard:server:SetActivityBusy(activity, bool)` 全仓**没有任何客户端调用点**，
  却对客户端开放：任何玩家能用坏 key 让 `Config.IllegalActions[activity].busy` 抛错，
  或者直接改全服"非法活动占用"状态（等于全服抢劫开关）。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource_path: str, *extra: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / resource_path).as_posix(), *extra],
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
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


def test_player_blip_data_is_admin_only():
    """全服玩家位置是 wallhack 级信息，只能给管理员。"""
    data = _run("adminmenu_probe.lua", "[qb]/qb-adminmenu")
    assert data["BLIPS_CIVILIAN_BLOCKED"] == "true", "普通玩家一发就能拿到全服玩家坐标（旧版就是这样）"
    assert data["BLIPS_ADMIN_ALLOWED"] == "true", "管理员拿不到 blips 数据（过度收紧）"
    assert data["BLIPS_ACE_ALLOWED"] == "true", "有 ACE command 权限的拿不到（过度收紧）"


def test_stress_events_ignore_bad_amounts_and_clamp():
    data = _run("hud_scoreboard_probe.lua", "[qb]/qb-hud", "hud")
    assert data["STRESS_GAIN_APPLIED"] == "true", "正常加压力被拒（过度收紧）"
    assert data["STRESS_BAD_STEP_BLOCKED"] == "true", "表/字符串/非正数没挡住（旧版直接抛错打断线程）"
    assert data["STRESS_GAIN_CLAMPED"] == "true", "超大增量没被夹住"
    assert data["STRESS_RELIEVE_APPLIED"] == "true", "正常减压力被拒（qb-ambulancejob 治伤发 100）"
    assert data["STRESS_RELIEVE_BAD_STEP_BLOCKED"] == "true", "减压力也接受坏参数"


def test_activity_busy_flag_is_server_only():
    data = _run("hud_scoreboard_probe.lua", "[qb]/qb-scoreboard", "scoreboard")
    assert data["BUSY_CLIENT_BLOCKED"] == "true", "任何玩家都能改全服抢劫占用状态（旧版就是这样）"
    assert data["BUSY_BAD_ARGS_SAFE"] == "true", "坏 key / 非 bool 会打断事件线程"
    assert data["BUSY_SERVER_ALLOWED"] == "true", "服务端自己也翻不动（过度收紧）"
