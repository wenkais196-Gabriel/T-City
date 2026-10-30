# 计划：支援单位的生成点与到场（spawn v3）

> 触发：2026-10-29 真机手感反馈——"生成点在目视范围内、不从路上来、会朝反方向开很远再掉头、
> 30 秒不到就下车跑过来"。三条都能在代码里对上，本文先把事实与调研钉死，再分三片改。

## 1. 代码事实（改动前）

| 现象 | 代码位置与取值 | 判定 |
|---|---|---|
| 固定偏移生成 | `client/backup.lua` 的 `spawnPoint()`：`SPAWN_SIDE = 6.0`、`SPAWN_FORWARD = 50.0`，`GetOffsetFromEntityInWorldCoords` 直接取点，只用 `GetGroundZFor_3dCoord` 落地 | 与路网无关、与可见性无关 |
| 车头朝向与道路无关 | `heading = (GetEntityHeading(playerPed) + 180.0) % 360.0`——朝玩家，不是朝路面 | 单行道/隔离带会立刻违逆 |
| 反向开车再掉头 | 每 5s 心跳用 `TaskVehicleDriveToCoord`（**非** longrange）重发；driving style `786603`（官方口径 = Normal：遇车/遇人停、**红灯停**） | 每次重发都从当前位置重启局部寻路，方向错就一路绕 |
| 30 秒必下车 | `ESCORT_TIMEOUT_MS = 30000` 与距离判定是 `or`：`距离 ≤ 20m` **或** `超 30s` → `beginFoot()` | 20m 之外也下车，两名警官穿过车流跑回来 |

## 2. 调研结论（带出处）

1. **`GET_CLOSEST_VEHICLE_NODE_WITH_HEADING(x, y, z, &pos, &heading, nodeType, p6, p7)` 返回的是道路朝向**；
   `nodeType = 1` 表示"任意道路"，12/8/0 偏向主路；p6 惯例 3.0、p7 惯例 0。官方文档还提示
   p6/p7 与"同一条路、同一个方向"有关。
   出处：docs.fivem.net natives `0xFF071FB798B803B0`。
2. **`GetNthClosestVehicleNodeFavourDirection` 是"按你要去的方向挑节点"**，开源实现 Mooreiche/AIBackup 的
   生成逻辑就是这一条（原文）：`offset = GetOffsetFromEntityInWorldCoords(player, 50, 50, 0)` →
   `GetNthClosestVehicleNodeFavourDirection(offset, playerCoords, 20, 1, 3.0, 0)` → `CreateVehicle(..., heading)` →
   `LoadAllPathNodes(true)` → `TaskVehicleDriveToCoordLongrange(driver, veh, pc, 15.0, style, 15.0)`。
   出处：github.com/Mooreiche/AIBackup `AIBackup/client.lua`。
3. **driving style `786603` = Normal**（1 停车让车、2 让行人、128 红灯停）；`2883621` = Ignore Lights；
   `1074528293` = Rushed。出处：gtaforums《[Guide] Driving Styles》。
   结论：我们要的是"闪警灯出警"，红灯停是浪费，但**不该**用 Ignore roads（那会让车横穿人行道）。
4. PATHFIND 全部 59 个 native 都是客户端独占（早前调研已确认），所以生成点选择**只能在客户端**——
   这与"客户端生成"的既有取舍一致，不需要动服务端。

## 3. 三片设计

### P3 下车规则（先做，最小改动）

| 项 | 改后 |
|---|---|
| 下车条件 | `距离 ≤ ARRIVE_RADIUS(20m)` **且** `GetEntitySpeed(vehicle) < 5.0`（避免擦身而过时下车） |
| 硬上限 | `ESCORT_TIMEOUT_MS` 30s → **90s**；到点仍未到 → `cleanup(..., 'escort_timeout')` 结束并释放名额 |
| 新原因 | `escort_timeout` 进 `BackupContract.CLIENT_REASONS`（审计里可聚合） |
| 不再发生 | 20m 之外下车、两名警官从远处穿过车流跑过来 |

### P1 生成点（路网 + 视锥外 + 顺向）

1. 目标点：玩家前方 50m、侧偏 50m（沿用 AIBackup 的"斜前方"取点），用
   `GetNthClosestVehicleNodeFavourDirection(目标点, 玩家坐标, 20, 1, 3.0, 0)` 取节点与**道路朝向**；
2. 筛"看不见"：`IsSphereVisible(x,y,z, 8.0)` 为假 且 `IsPointOnScreen` 为假；
3. 筛"顺向"：节点朝向与"节点→玩家"方向夹角 < 90°（AIBackup 的 FavourDirection 已隐式做到，双保险）；
4. 生成：`CreateVehicle(..., heading)` 用节点朝向；`LoadAllPathNodes(true)` 保证路径已加载；
5. 兜底：node 查询失败 → 回落现在的偏移生成并打日志（`police_backup_spawn_mode=offset` 可强制回滚）。

### P2 行驶（长距离规划 + 无进展看门狗）

| 项 | 改后 |
|---|---|
| 下发 | 距玩家 > 150m 用 `TaskVehicleDriveToCoordLongrange`；≤150m 用 `TaskVehicleDriveToCoord` |
| 驾驶风格 | `786603` → `2883621`（Ignore Lights，仍是"遇车让行 + 让行人"） |
| 看门狗 | 每 2s 采样到玩家距离；连续 8s 没有减少 5m → 清任务、按当前节点重发一次；连续两轮无进展 → `vehicle_lost` 结束 |
| 心跳 | 5s → 只在"任务不在执行"或看门狗触发时重发（沿用 S5 的 `ShouldRetask`） |

## 4. 验收（每片都要真机）

| 片 | 验收 |
|---|---|
| P3 | 客户端日志 `dismount at Nm`，**N ≤ 25**；日志不再出现 30s 内下车；`escort_timeout` 只在 90s 到点出现 |
| P1 | 日志 `spawn node=... dist=..m visible=..`：节点距离 40–120m、`visible=false`、朝向与玩家夹角 < 90°；连续 5 次请求无一次回落到 offset |
| P2 | 日志 `enroute dist=..` 单调下降；无"距离先增后减超过 30s"；`backup.spawned` 的 `took` 仍是 0（生成不受影响） |

## 5. 风险与回滚

| 风险 | 处置 |
|---|---|
| 玩家附近没有合法节点（荒郊/机场） | 回落到偏移生成并记日志；`police_backup_spawn_mode=offset` 整体回滚 |
| 节点在视野内（城市窄巷） | 允许降级为"不在屏幕内"即可（`IsPointOnScreen` 为假） |
| 90s 上限让"慢慢堵车"变成直接结束 | 90s 是硬上限，P2 的看门狗会把明显失败更早识别出来 |
| Ignore Lights 让 NPC 闯红灯撞真玩家 | 保留"遇车让行/让行人"两个位；真机观察一周再决定是否收紧 |

## 6. 任务清单

| # | 任务 | 文件 | 状态 |
|---|---|---|---|
| 1 | P3：下车规则 + `escort_timeout` | `client/backup.lua`、`shared/backup_contract.lua` | ☐ |
| 2 | P1：节点生成 + 视锥外 + 顺向 + 兜底 | `client/backup.lua` | ☑ 2026-10-30 |
| 3 | P2：longrange + 驾驶风格 + 看门狗 | `client/backup.lua` | ☑ 2026-10-30 |
| 4 | 文档与指标：`10-backup-v2.md`、CHANGELOG、metrics 的 `escort_timeout` 归类 | 文档 + `tools/dev/police_backup_metrics.py` | ☐ |
