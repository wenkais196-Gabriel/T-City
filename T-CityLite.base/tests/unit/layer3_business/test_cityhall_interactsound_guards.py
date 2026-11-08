"""P1-3 批 13：qb-cityhall 与 interact-sound。

**qb-cityhall**

- `getIDs` 直接绑到 `giveStarterItems()`：任何玩家可以反复触发，每次都给一份
  phone / id_card / driver_license —— 等于**无限刷新手三件套**。
- `requestId(item, hall)`：`hall` 来自客户端且直接索引 `Config.Cityhalls[hall].licenses[item]`
  （那是数组），坏下标就是一个 nil 索引，把事件线程打崩。
- `sendDriverTest(instructors)`：`instructors` 是客户端给的 citizenid 列表，长度不限，
  对离线玩家走 `sendNewMailToOffline` → 一次请求可以写 50 封邮件（探针实测 49 封）。
- `ApplyJob(job, cityhallCoords)`：距离校验用的是**客户端声称**的市政厅坐标 —— 玩家在
  任何地方把坐标报成自己脚下就能远程申请工作。

**interact-sound**（仓库内被警方与车辆资源大量调用）

- `PlayOnAll` / `PlayOnOne` 在仓库里**没有任何调用点**，却对客户端开放：任何人能给全服或指定
  玩家刷声。
- `PlayOnSource` / `PlayWithinDistance` 的声音文件名与音量完全不做校验（文件名会进客户端
  `PlaySoundFrontend` 路径），且没有限流。
- `PlayWithinDistance` 被注册了两次（后一个覆盖前一个，前一个是死代码）。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource_path: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / resource_path).as_posix()],
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


# ══════════════════════════════════════════════════════════════════
# qb-cityhall
# ══════════════════════════════════════════════════════════════════


def test_cityhall_starter_items_cannot_be_farmed():
    """`getIDs` 原来每次调用都发一份新手三件套。"""
    data = _run("cityhall_probe.lua", "[qb]/qb-cityhall")
    assert data["STARTER_REPEAT_NOTHING_ADDED"] == "true", "已经持有仍然重复发放"
    assert data["STARTER_FIRST_TIME_ADDED"] == "true", "第一次反而不发（过度收紧）"


def test_cityhall_id_request_survives_bad_hall_and_item():
    """`hall` / `item` 来自客户端，坏下标不能让 handler 抛错。"""
    data = _run("cityhall_probe.lua", "[qb]/qb-cityhall")
    assert data["ID_BAD_HALL_SAFE"] == "true", "坏 hall（字符串）抛错"
    assert data["ID_BAD_HALL_INDEX_SAFE"] == "true", "坏 hall（越界下标）抛错"
    assert data["ID_BAD_ITEM_SAFE"] == "true", "非字符串 item 抛错"


def test_cityhall_driver_test_request_is_capped_and_rate_limited():
    """`instructors` 是客户端给的 citizenid 列表，不能无限发离线邮件。"""
    data = _run("cityhall_probe.lua", "[qb]/qb-cityhall")
    sent = int(data["DRIVERTEST_MAIL_COUNT"])
    assert sent <= 10, f"一次请求发了 {sent} 封邮件（上限应为 10）"
    assert data["DRIVERTEST_COOLDOWN"] == "true", "没有冷却，可以连点继续刷邮件"


def test_cityhall_apply_job_distance_uses_server_config():
    """距离必须用服务端配置里的市政厅坐标，不能采信客户端传的坐标。"""
    data = _run("cityhall_probe.lua", "[qb]/qb-cityhall")
    assert data["APPLY_JOB_OK"] == "true", "在市政厅门口反而申请不了（过度收紧）"
    assert data["APPLY_JOB_NOT_IN_LIST_REJECTED"] == "true", "不在 AvailableJobs 里的职业也能申请"
    assert data["APPLY_JOB_REMOTE_REJECTED"] == "true", "远程谎报坐标仍能申请工作"


# ══════════════════════════════════════════════════════════════════
# interact-sound
# ══════════════════════════════════════════════════════════════════


def test_global_sound_events_are_server_only():
    """`PlayOnAll` / `PlayOnOne` 在仓库里没有客户端调用点，只能服务端触发。"""
    data = _run("interactsound_probe.lua", "[standalone]/interact-sound")
    assert data["ALL_FROM_CLIENT_BLOCKED"] == "true", "客户端能给全服刷声"
    assert data["ALL_FROM_SERVER_ALLOWED"] == "true", "服务端触发也被挡（功能的唯一合法用法失效）"
    assert data["ONE_FROM_CLIENT_BLOCKED"] == "true", "客户端能给任意玩家刷声"


def test_sound_parameters_are_whitelisted_and_rate_limited():
    """声音文件名/音量来自客户端，必须白名单 + 限流。"""
    data = _run("interactsound_probe.lua", "[standalone]/interact-sound")
    assert data["SOURCE_VALID_ALLOWED"] == "true", "合法声音反而播不了（过度收紧）"
    assert data["SOURCE_RATE_LIMITED"] == "true", "没有限流，可以高频刷"
    assert data["SOURCE_ALLOWED_AFTER_WINDOW"] == "true", "过了窗口仍然播不了（限流窗口过长）"
    assert data["SOURCE_BAD_FILENAME_BLOCKED"] == "true", "URL/非法文件名被接受"
    assert data["SOURCE_BAD_VOLUME_BLOCKED"] == "true", "越界音量被接受"
    assert data["DISTANCE_OVER_LIMIT_BLOCKED"] == "true", "超出 300 米的距离仍会广播"
    assert data["DISTANCE_VALID_ALLOWED"] == "true", "正常距离反而播不了（过度收紧）"
