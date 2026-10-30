"""S3/S4 的所有权闸门：寿命必须只有一个主人。

背景：支援单位原本有两套互不知道的计时（客户端 5 分钟、预算 10 分钟），
结果是"名额占着但没人收"。S3 把寿命交给服务端 sweep，S4 让客户端自计时退位。
这两条如果只是"约定"，下一次改客户端循环的人很容易把它们悄悄改回去——
所以这里用静态闸门钉住三个事实：

1. 客户端那处 `UNIT_LIFETIME_MS` 比较必须有 `serverOwnsLifetime()` 守卫；
2. 服务端 sweep 的寿命是 300s、宽限 5s，且必须挂在 `onResourceStart` 上起循环
   （加载期起循环会让 Lua harness 的 Drain 撞上 `Wait() is not supported`）；
3. 两端读的是同一个 convar `police_backup_v2`，默认值都是 1。
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
CLIENT = REPO / "resources" / "[custom]" / "custom-police" / "client" / "backup.lua"
SERVER = REPO / "resources" / "[custom]" / "custom-police" / "server" / "p2_system.lua"


@pytest.fixture(scope="module")
def client_source() -> str:
    return CLIENT.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def server_source() -> str:
    return SERVER.read_text(encoding="utf-8")


def test_client_lifetime_requires_the_server_owner_guard(client_source: str) -> None:
    lines = client_source.splitlines()
    unguarded = [
        (index, line.strip())
        for index, line in enumerate(lines, start=1)
        if "UNIT_LIFETIME_MS" in line and ">=" in line and "serverOwnsLifetime()" not in line
    ]
    assert not unguarded, (
        "客户端自计时必须在 serverOwnsLifetime() 守卫下（v2 时寿命归服务端）："
        + "; ".join(f"{line_no}: {text}" for line_no, text in unguarded)
    )
    assert "GetConvar('police_backup_v2', '1')" in client_source, (
        "客户端必须读 police_backup_v2 且默认 1，否则服务端开着扫、客户端还自己计时"
    )




def test_server_ttl_and_grace_are_the_documented_numbers(server_source: str) -> None:
    assert re.search(r"local BACKUP_TTL_SECONDS = 300\b", server_source), "寿命必须是 300s"
    assert re.search(r"local BACKUP_END_GRACE = 5\b", server_source), "宽限必须是 5s"
    assert re.search(r"local BACKUP_SWEEP_MS = 10000\b", server_source), "sweep 周期必须是 10s"
    assert re.search(r"BACKUP_ACK_TIMEOUT = \{ requested = 10, spawning = 15 \}", server_source), (
        "ack 超时必须是 requested 10s / spawning 15s"
    )


def test_sweep_loop_starts_on_resource_start(server_source: str) -> None:
    loop_at = server_source.find("pcall(BackupSweep)")
    assert loop_at != -1, "找不到 sweep 循环"
    window = server_source[max(0, loop_at - 800):loop_at]
    assert "onResourceStart" in window, (
        "sweep 循环必须挂在 onResourceStart 上：加载期起的 while/Wait 会让 harness 的 Drain 直接报错"
    )


def test_sweep_sends_backup_end_before_releasing(server_source: str) -> None:
    """先收再放：一轮只发 BackupEnd 并标记 endingAt，释放要等下一轮过了宽限。

    顺序在源码里是"发送 → 标记 endingAt"，释放分支由 `entry.endingAt` +
    `BACKUP_END_GRACE` 双重条件守着（golden 用例另外验证了宽限内 released == 0）。
    """
    sweep = server_source[server_source.find("function BackupSweep"):]
    assert sweep.count("police:client:BackupEnd") == 1, "一轮 sweep 只该发一次 BackupEnd"
    assert "if entry.endingAt then" in sweep, "释放分支必须以 endingAt 为条件"
    assert "if now - entry.endingAt >= BACKUP_END_GRACE then" in sweep, "释放必须等宽限"

    # 标记与发送必须在同一个 `if why then` 分支里：同一 tick 先记 endingAt 再发消息，
    # 否则会出现"发了消息但没记，下一轮又发一次"或"记了没发，客户端永远不清理"。
    branch_at = sweep.find("if why then")
    assert branch_at != -1, "sweep 必须有 `if why then` 收尾分支"
    branch = sweep[branch_at:branch_at + 600]
    assert "entry.endingAt = now" in branch, "收尾分支必须记 endingAt（否则下一轮会重复发）"
    assert "police:client:BackupEnd" in branch, "收尾分支必须下发 BackupEnd"
    assert "NPCBudget.Release" not in branch and "expireBackupUnit(" not in branch, (
        "到点那一轮不能直接放名额：释放要等下一轮过了 BACKUP_END_GRACE"
    )

def test_expiry_retreats_instead_of_deleting_in_place(client_source: str) -> None:
    """到点不许在玩家眼前原地删车（S8）。

    开源实现（Mooreiche/AIBackup 等）的通行做法是让单位开走再让引擎自然回收，
    而不是 `DeleteEntity` —— 后者在真机上就是"警车凭空消失"。这里钉住三件事：
    BackupEnd 必须走撤离、撤离必须用 wander + 交给引擎、撤离必须有硬上限
    （否则实体可能永远不消失）。
    """
    handler_at = client_source.find("RegisterNetEvent('police:client:BackupEnd'")
    assert handler_at != -1, "BackupEnd 处理器不见了"
    handler = client_source[handler_at:handler_at + 1400]
    assert "beginRetreat(state" in handler, "到点必须走撤离，而不是直接 cleanup"

    begin_at = client_source.find("local function beginRetreat")
    assert begin_at != -1, "找不到 beginRetreat"
    end_at = client_source.find("local function updateRetreat", begin_at)
    assert end_at != -1, "找不到 updateRetreat"
    body = client_source[begin_at:end_at]
    assert "TaskVehicleDriveWander" in body, "撤离必须真的把车开走"
    assert "SetEntityAsNoLongerNeeded" in body, "撤离要把实体交回引擎回收"

    update = client_source[end_at:client_source.find("local function createBlip", end_at)]
    assert "RETREAT_TIMEOUT_MS" in update, "撤离必须有硬超时，否则实体可能永远不消失"
    assert "RETREAT_DESPAWN_RADIUS" in update, "撤离要按距离判定（开远了才删）"
    assert "cleanup(" in update, "撤离结束（车没了/开远了/超时）必须真的清理"

def test_orders_only_touch_the_callers_own_units(client_source: str) -> None:
    """指挥（B2）：/backup follow|hold|dismiss 只能作用于自己名下的单位。

    钉住三件事：命令有白名单、只遍历本地 active 表（服务端名额不动）、
    dismiss 必须回报 dismissed 原因（否则服务端会当成 unknown）。
    """
    cmd_at = client_source.find("RegisterCommand('backup'")
    assert cmd_at != -1, "找不到 /backup 命令"
    block = client_source[cmd_at:cmd_at + 900]
    assert "BACKUP_ORDERS[order]" in block, "参数必须在白名单里"
    assert "follow = true, hold = true, dismiss = true" in client_source, "白名单缺项"

    order_at = client_source.find("local function applyOrder")
    order_block = client_source[order_at:client_source.find("RegisterCommand('backup'", order_at)]
    assert "for requestId, state in pairs(active)" in order_block, (
        "只能作用于本地 active 里的单位（服务端名额与寿命不归它管）"
    )
    assert "notifyServerEnded(requestId, 'dismissed')" in order_block, (
        "主动撤离必须回报 dismissed，否则审计里只剩 unknown"
    )
    assert "beginRetreat(state, 'dismissed')" in order_block, "主动撤离也要开走，不能原地消失"

def test_units_only_dismount_next_to_the_caller(client_source: str) -> None:
    """P3：不许在远处下车。

    以前的到场判定是 `距离 <= 20m OR 超过 30s`——30 秒一到，两百米外也把两名警官放下来
    跑步。这里钉住：下车必须同时满足"在 20m 内"和"车慢下来"，超时只能结束这一单。
    """
    drive_at = client_source.find("elseif #(vehicleCoords - playerCoords) <= ARRIVE_RADIUS")
    assert drive_at != -1, "找不到到场判定"
    block = client_source[drive_at:drive_at + 700]
    assert "and GetEntitySpeed(state.vehicle) < ARRIVE_SPEED then" in block, (
        "下车必须同时要求距离与车速"
    )
    assert "beginFoot(state, " in block, "beginFoot 必须带上距离，便于日志验收"
    assert "or now - state.createdAt >= ESCORT_TIMEOUT_MS" not in block, (
        "超时不许再触发下车"
    )
    assert "cleanup(requestId, true, 'escort_timeout')" in block, (
        "超时必须结束这一单并释放名额"
    )
    assert "local ESCORT_TIMEOUT_MS = 90000" in client_source, "硬上限应为 90s"

    contract = (REPO / "resources" / "[custom]" / "custom-police" / "shared" / "backup_contract.lua")
    text = contract.read_text(encoding="utf-8")
    assert "escort_timeout = true" in text, "escort_timeout 必须进客户端可上报白名单"

def test_dev_backup_command_is_gated_and_console_only(server_source: str) -> None:
    """开发期后门的两条底线：默认关（convar）、只接受控制台。

    真机迭代需要"一行命令叫一单"，但这条后门绝不能对玩家开放，也不能绕过
    权限/冷却/预算——它必须调用同一个 RequestBackup。
    """
    at = server_source.find("RegisterCommand('police_backup_dev'")
    assert at != -1, "找不到 police_backup_dev"
    block = server_source[at:at + 1400]
    assert "GetConvar('police_backup_dev_enabled', '0')" in block, "必须默认关闭"
    assert "if source ~= 0 then return end" in block, "只允许控制台/RCON"
    assert "RequestBackup(src, tier)" in block, "必须复用同一个入口，不能绕过权限与预算"
    assert "RequestBackup(src, tier)" in block and "NPCBudget" not in block, (
        "后门不得自己碰预算"
    )

def test_spawn_uses_reachable_road_nodes(client_source: str) -> None:
    """spawn v3 · P1/P2：在路网上取点、要求可达、能兜底，远距离走 longrange 且识别卡住。

    真机换来的三条教训都钉在这里：
    * 一条 nth 只给一个节点，可能是"背对玩家"那一侧 → 必须扫候选挑朝向最顺的；
    * 纯看直线距离会挑到高架/隧道另一侧，驾驶任务立刻 finished → 必须用路径距离过滤；
    * 挑不到合适节点要能干净回落到偏移生成。
    """
    at = client_source.find("local function findSpawnNode")
    assert at != -1, "找不到 findSpawnNode"
    body = client_source[at:client_source.find("local function spawnPoint", at)]
    assert "GetNthClosestVehicleNodeFavourDirection" in body, "必须在路网上取点"
    assert "SPAWN_NODE_CANDIDATES" in body, "必须扫多个 nth 候选"
    assert "CalculateTravelDistanceBetweenPoints" in body, "必须做路径可达性过滤"
    assert "SPAWN_MAX_TRAVEL_RATIO" in body, "可达性要有倍数上限"
    assert "IsSphereVisible" in body and "IsPointOnScreen" in body, "必须做可见性过滤"
    assert "police_backup_spawn_mode" in body, "需要回滚开关"

    spawn_at = client_source.find("local spawn, spawnHeading = findSpawnNode")
    assert spawn_at != -1, "生成必须优先用节点"
    spawn_block = client_source[spawn_at:spawn_at + 700]
    assert "spawnPoint(playerPed, lane)" in spawn_block, "取不到节点必须回落到偏移生成"
    assert "LoadAllPathNodes" in spawn_block, "生成后必须确保路网已加载"

    assert "LONG_RANGE_THRESHOLD" in client_source, "远距离要切 longrange"
    assert "TaskVehicleDriveToCoordLongrange(" in client_source
    assert "STUCK_WINDOW_MS" in client_source and "SPAWN_GRACE_MS" in client_source, (
        "卡住判定必须带生成宽限，否则正常掉头会被判失败"
    )
    assert "cleanup(requestId, true, 'vehicle_lost')" in client_source
