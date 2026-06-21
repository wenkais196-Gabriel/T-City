# custom-vehicles — 统一车辆系统

> **路径**: `resources/[custom]/custom-vehicles/` | **状态**: ✅ ENABLED | **CFG 模块**: vehicles.cfg
> **依赖**: oxmysql, qb-core, core-framework, custom-quest | **替代**: qb-vehiclekeys (已删除), qb-mechanicjob (车辆状态部分)

---

## 文件清单

| 文件 | 角色 |
|:---|:---|
| `fxmanifest.lua` | 资源清单 |
| `config.lua` | 全局配置 |
| **服务端** | |
| `server/main.lua` | 入口：事件注册、exports、Bus 集成、dashboard 锁 |
| `server/key_manager.lua` | O(1) 内存钥匙缓存 — 发钥匙/收钥匙/查钥匙/临时钥匙 |
| `server/vehicle_state.lua` | 车辆状态管理 — 部件退化/里程/氮气/调校 |
| `server/dashboard_api.lua` | 中控屏 API — 喊话器/警笛/雷达/锚/物流签章 |
| `server/compat.lua` | qb-vehiclekeys 兼容桥 |
| **客户端** | |
| `client/main.lua` | 事件驱动引擎控制 — 启动/熄火/锁车/警报 |
| `client/dashboard.lua` | 中控屏 NUI — Vue 3 毛玻璃 UI |
| `client/indicators.lua` | 转向灯 |
| `client/cruise.lua` | 定速巡航 |
| `client/noshuff.lua` | 防座位乱序 |
| `client/vehiclepush.lua` | 推车 |
| `client/seatbelt.lua` | 安全带 |
| `client/vehicle_degradation.lua` | 部件退化模拟 |
| `client/vehicle_nitrous.lua` | 氮气加速 |

---

## 钥匙管理器 (`server/key_manager.lua`)

**数据结构**: `KeyManager._keys[plate] = { _owner = citizenid, [citizenid] = KeyType }`

纯内存 Lua 表 — O(1) 查找，不直接持久化钥匙（所有权验证回退到 `player_vehicles` DB 表）。

| 钥匙类型 | 说明 |
|:---|:---|
| `owner` | 车主 — 从 `player_vehicles` 加载或通过 AcquireVehicleKeys 获取 |
| `shared` | 共享钥匙 — 车主主动分享 |
| `temp` | 临时钥匙 — 撬锁成功或热线启动 |
| `hotwired` | 热线启动 — 概率成功 + 警报 |

### 钥匙 Exports (9 个)
| Export | 签名 |
|:---|:---|
| `GiveKeys` | `(plate, citizenid)` → bool |
| `RemoveKeys` | `(plate, citizenid)` |
| `HasKeys` | `(plate, citizenid)` → bool, type |
| `GiveTempKeys` | `(plate, citizenid)` → bool |
| `GetOwner` | `(plate)` → cid/nil |
| `SetOwner` | `(plate, citizenid)` |
| `GetKeyHolders` | `(plate)` → table |
| `ClearTempKeys` | `(citizenid)` → count |
| `KeyManagerStats` | `()` → { vehicles, total_holders } |

---

## 车辆状态 (`server/vehicle_state.lua`)

**追踪状态 (per plate，纯内存)**:
- `vehicleComponents[plate]` — `{ radiator, axle, brakes, clutch, fuel }` 各 0–100
- `drivingDistance[plate]` — 累计里程
- `tunedVehicles[plate]` — 调校芯片状态
- `nitrousVehicles[plate]` — `{ hasnitro, level }`

⚠️ **持久化模式**: 同步直写 — 每次变异（修理/退化/里程/氮气）立即 `MySQL.update` 到 `player_vehicles` 表。**未使用 DirtyFlush**，高频驾驶场景可能造成 DB 压力。

### DB 操作 (player_vehicles 表)
- `SELECT 1 FROM player_vehicles WHERE plate = ?` — 存在性检查
- `UPDATE player_vehicles SET status = ? WHERE plate = ?` — 部件 JSON
- `UPDATE player_vehicles SET drivingdistance = drivingdistance + ? WHERE plate = ?` — 里程累加
- `UPDATE player_vehicles SET mods = ? WHERE plate = ?` — 车辆改装 JSON

---

## Compat 兼容桥 (`server/compat.lua`)

| 旧 API | 桥接方式 |
|:---|:---|
| `exports['qb-vehiclekeys']:HasKeys` | → `KeyManager.HasKeys` |
| `exports['qb-vehiclekeys']:GiveKeys` | → `KeyManager.GiveKeys` |
| `exports['qb-vehiclekeys']:RemoveKeys` | → `KeyManager.RemoveKeys` |
| `qb-vehiclekeys:server:GiveKeys` | NetEvent → shared key + 推送更新 |
| `qb-vehiclekeys:server:RemoveKeys` | NetEvent → 移除调用者钥匙 |
| `qb-vehiclekeys:server:AcquireVehicleKeys` | NetEvent → 声明所有权（安全检查 + 审计） |
| `qb-vehiclekeys:server:ToggleEngine` | NetEvent → 服务端实体查找 + 钥匙验证 |
| `QBCore.Functions.OnGiveKeys` | 登录时批量加载 — `SELECT plate FROM player_vehicles WHERE citizenid = ?` |

---

## 中控屏 API (`server/dashboard_api.lua`)

| 功能 | 验证 |
|:---|:---|
| **喊话器** (Megaphone) | 职业检查 (police/ambulance/fire) + 驾驶座 + 速率限制 1s + 审计日志 |
| **警笛控制** (Siren) | 职业检查 + 驾驶座 |
| **锚控制** (Anchor) | 驾驶座 + 近距离 + 速率限制 |
| **物流签章** (LogisticsStamp) | 3-way e-stamp — 查找活跃物流任务 → 验证驾驶座 → 触发 quest |
| **物流快速装载** | → `custom-quest` dashboard_quick_load |

---

## 安全审计

| 事件 | 源验证 | 风险 | 说明 |
|:---|:---:|:---:|:---|
| `custom-vehicles:server:giveKeys` | ✅ 车主检查 + 目标在线 | LOW | |
| `custom-vehicles:server:removeKeys` | ✅ 不能移除车主钥匙 | LOW | |
| `custom-vehicles:server:hotwireAttempt` | ✅ 3s 冷却 + 5m 距离 + 已有钥匙守卫 | MEDIUM | 触发警察警报 |
| `custom-vehicles:server:lockpickAttempt` | ✅ 冷却 + 距离 + 背包检查 + 失败消耗 | MEDIUM | 消耗开锁器 + 警报 |
| `qb-vehiclekeys:server:AcquireVehicleKeys` | ✅ 现有车主检查 + 审计日志 | HIGH | 盗窃尝试记录 |
