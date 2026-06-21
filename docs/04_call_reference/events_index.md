# Cross-Resource Events Index

> **生成日期**: 2026-06-05 | **覆盖**: 所有启用资源的关键事件

---

## 1. 核心框架事件 (qb-core 触发)

这些事件是**框架内部触发**的，不由客户端直接调用 — **source 可信**。

| 事件 | 触发位置 | 监听者 | 数据 |
|:---|:---|:---|:---|
| `QBCore:Server:PlayerLoaded` | qb-core/player.lua | core-framework/compat, custom-vehicles, custom-main | Player 数据 |
| `QBCore:Server:OnMoneyChange` | qb-core/services/economy | economy-dashboard, custom-security, custom-logs | source, moneytype, amount, isRemove |
| `QBCore:Server:OnJobUpdate` | qb-core (SetJob) | custom-security, custom-main | source, job, grade |
| `QBCore:Server:OnGangUpdate` | qb-core (SetGang) | custom-security, custom-main | source, gang, grade |
| `QBCore:Client:OnJobUpdate` | qb-core → client | 客户端 HUD | job data |
| `QBCore:Client:OnMoneyChange` | qb-core → client | 客户端 HUD | moneytype, amount |

---

## 2. 安全敏感事件 (需源验证)

### 高优先级 — 涉及金钱/物品/职业变更

| 事件 | 资源 | 验证链 | 风险 |
|:---|:---|:---|:---|
| `qb-inventory:server:SetInventoryData` | qb-inventory | Player 存在，`shop-` 禁止 | 🟠 otherplayer 无距离检查 |
| `police:server:BillPlayer` | qb-policejob | 距离 + job.type + 50K 上限 | 🟢 |
| `police:server:SeizeCash` | qb-policejob | 距离 + job.type | 🟢 |
| `police:server:SeizeDriverLicense` | qb-policejob | 距离 → custom-certificates | 🟢 |
| `police:server:RobPlayer` | qb-policejob | 距离 2.5m | 🟢 |
| `police:server:Impound` | qb-policejob | job.type + onduty (T-City 加固) | 🟢 |
| `cartel:server:startProduction` | custom-cartel | source → Player → 成员 → 等级 → 冷却 → has-item → SecurityService | 🟢 |
| `cartel:server:finishProduction` | custom-cartel | 重新验证成员 + has-item | 🟢 |
| `cartel:server:buyFromSupplier` | custom-cartel | 成员 → NPC 配置 → 物品配置 → 数量截断 | 🟢 |
| `cartel:server:sellToDealer` | custom-cartel | 成员 → NPC → 价格 → 数量截断 → has-item | 🟢 |
| `mining:server:mineOre` | custom-mining | job=miner → 冷却 → 工具 → ⚠️ 无 SecurityService | 🟡 |
| `mining:server:smeltOre` | custom-mining | job=miner → 配方配置 → ⚠️ 无 SecurityService | 🟡 |
| `custom-vehicles:server:hotwireAttempt` | custom-vehicles | 3s冷却 + 5m距离 + 已有钥匙守卫 | 🟡 |
| `custom-vehicles:server:lockpickAttempt` | custom-vehicles | 冷却 + 距离 + 背包 + 失败消耗 | 🟡 |
| `qb-vehiclekeys:server:AcquireVehicleKeys` | custom-vehicles/compat | 现有车主检查 + 审计 | 🔴 |

### 中优先级 — 状态/元数据变更

| 事件 | 资源 | 验证 |
|:---|:---|:---|
| `police:server:JailPlayer` | qb-policejob | 距离 + job.type |
| `police:server:SetHandcuffStatus` | qb-policejob | 仅 LEO/EMS 可解铐 |
| `police:server:SetTracker` | qb-policejob | 距离 2.5m + DropPlayer |
| `custom-main:server:ResetDeathStatus` | custom-main | GetPlayer(src) |
| `custom-main:server:policeHandoverAlert` | custom-main | GetPlayer(src) + citizenid/charName |
| `QBCore:UpdatePlayer` | qb-core | source 验证 |

---

## 3. 客户端事件 (从服务端推送)

| 事件 | 推送者 | 接收者 |
|:---|:---|:---|
| `QBCore:Notify` | qb-core (Notify) | 目标客户端 |
| `QBCore:Client:OnMoneyChange` | qb-core EconomyService | 目标客户端 |
| `QBCore:Client:OnJobUpdate` | qb-core JobService | 目标客户端 |
| `hud:client:OnMoneyChange` | qb-core EconomyService | 目标客户端 |
| `qb-phone:client:RemoveBankMoney` | qb-core EconomyService | 目标客户端 |
| `custom-vehicles:client:keysUpdated` | custom-vehicles | 目标客户端 |
| `custom-vehicles:client:engineToggle` | custom-vehicles | 目标客户端 |
| `custom-vehicles:client:sirenMode` | custom-vehicles Dashboard API | 全局 |
| `custom-main:client:updateSuspectBlip` | custom-main Dispatch | 所有执勤警察 |
| `custom-main:client:clearSuspectBlip` | custom-main Dispatch | 所有执勤警察 |
| `custom-main:client:clearLocalWanted` | custom-main Dispatch | 目标玩家 |

---

## 4. 跨资源协调事件

| 事件 | 触发者 | 监听者 | 用途 |
|:---|:---|:---|:---|
| `quest:server:onQuestCompleted` | custom-quest | custom-career, 外部资源 | 任务完成通知 |
| `quest:server:onStepCompleted` | custom-quest | custom-vehicles (logistics) | 步骤完成通知 |
| `quest:server:dashboardStampDelivery` | custom-vehicles | custom-quest | 物流签章 |
| `core_economy:rewardGranted` | core_economy | 外部资源 | 奖励发放通知 |
| `police:server:policeAlert` | qb-policejob | qb-ambulancejob, 其他资源 | 警情调度 |
| `police:server:autoAlert` | custom-vehicles | qb-policejob | 热线/撬锁警报 |
| `qb-log:server:CreateLog` | qb-inventory | custom-logs | 物品操作审计 |
| `custom-logs:LogEconomy/Security/Generic` | core-framework | custom-logs | 审计日志分发 |

---

## 5. 事件命名规范建议

- `server:` → 服务端 `RegisterNetEvent`
- `client:` → 客户端事件
- `qb-*:server:*` → 旧 QBCore 命名（兼容保留）
- `custom-*:server:*` → 新 T-City 命名
- `Bus.*` → 通过 core-framework Bus 而非 NetEvent

---

## 6. 事件注入风险汇总

| 风险等级 | 数量 | 主要问题 |
|:---|:---:|:---|
| 🔴 HIGH | 1 | `AcquireVehicleKeys` — 可声明车辆所有权 |
| 🟠 MEDIUM | 4 | SetInventoryData (无距离), hotwireAttempt, lockpickAttempt, mineOre/smeltOre (无 SecurityService) |
| 🟡 LOW | ~15 | 有基础验证但有改进空间 |
| 🟢 SAFE | ~30+ | 完整验证链 |

> **建议**: 对 marked 🟡 及以上的事件添加 `SecurityService.ValidateItemEvent` 调用，并补全物理距离校验。
