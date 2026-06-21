# 维护与排障手册

---

## 1. 启动顺序问题

### 症状: 资源启动失败 / 依赖缺失

| 问题 | 原因 | 解决 |
|:---|:---|:---|
| qb-inventory 加载失败 | qb-weapons 未在前加载 (硬依赖) | 确保 player.cfg 中 qb-weapons 在 qb-inventory 之前 |
| qb-apartments 加载失败 | qb-interior / qb-clothing / qb-weathersync 未加载 | 保持 player.cfg 现有顺序 |
| pma-voice 无声 | `onesync` 未开启 | 在 txAdmin 设置页面开启 |
| 所有资源 DB 报错 | oxmysql 未启动或连接失败 | 检查 `mysql_connection_string`；确认 MySQL 服务运行中 |
| core-framework Bus 报错 | qb-core 未加载（core-framework 依赖它） | 确保 `core.cfg` 中 qb-core 在 `custom.cfg` 之前 |

---

## 2. 数据库性能

### 症状: 服务器卡顿 / DB 查询超时

| 可能原因 | 诊断 | 解决 |
|:---|:---|:---|
| custom-vehicles 同步写 `player_vehicles` 过于频繁 | 高玩家数时每个驾驶事件触发 UPDATE | 迁移到 DirtyFlush 批处理 |
| qb-inventory 每次关闭写 `inventories` | 高频开关背包 | 考虑内存缓存 + 定时批量写 |
| DirtyFlush tick 间隔过短 | `dirty_flush_tick_interval` < 30s | 恢复默认 900s |
| 离线转账竞态 | 异步 `MySQL.update` 不等待结果 | 检查 `core-framework/services/economy_service.lua:92` |

---

## 3. 数据一致性

### 症状: 玩家数据丢失 / 回档

| 可能原因 | 诊断 | 解决 |
|:---|:---|:---|
| DirtyFlush 未正常触发 | `_dirty` 表为空或不含该玩家 | 检查 `PlayerDropped` 事件是否正常；手动 `DirtyFlushForceFlush(citizenid)` |
| 服务器非正常关机 | `txAdmin-stop-type` 检测未命中 | 确认 txAdmin 版本兼容；添加 `server_shutting_down` fallback |
| 双写冲突 | qb-core 和 core-framework 同时写同一字段 | 合并两套 EconomyService |

---

## 4. 事件调试

### 追踪事件流

```lua
-- 在需要调试的资源中临时添加
AddEventHandler('QBCore:Server:OnMoneyChange', function(source, moneytype, amount, isRemove)
    print(string.format('[DEBUG] Money change: src=%s type=%s amount=%s remove=%s', 
        tostring(source), moneytype, amount, tostring(isRemove)))
end)
```

### 常见事件问题

| 问题 | 原因 | 解决 |
|:---|:---|:---|
| HUD 不更新金钱 | `QBCore:Client:OnMoneyChange` 未被正确触发 | 确认 EconomyService 中 `TriggerClientEvent` 目标正确 |
| 警察通缉不显示 Blip | `custom-main:server:policeHandoverAlert` 未处理 | 确认 custom-main dispatch 资源已加载；检查 `WantedPlayers` 缓存 |
| 任务完成不发奖励 | `quest:server:onQuestCompleted` 未被监听 | 确认 core_economy 已加载且在 custom-quest 之前 |

---

## 5. 常见崩溃与修复

### 症状: 玩家选角后黑屏

| 步骤 | 操作 |
|:---|:---|
| 1 | 检查 qb-spawn 是否加载 |
| 2 | 检查 qb-multicharacter 是否正常（多角色选择 UI 是否弹出） |
| 3 | 使用 `custom-debug` 的黑屏诊断工具 |
| 4 | 检查 `server.cfg` 中 `sv_enforceGameBuild 3258` 是否匹配客户端 |

### 症状: 玩家无法与 NPC/物体交互

| 步骤 | 操作 |
|:---|:---|
| 1 | 检查 qb-target 是否加载 |
| 2 | 检查 PolyZone 是否加载（qb-target 硬依赖） |
| 3 | 确认 `UseTarget` Convar 为 true |
| 4 | 检查目标资源的 client 脚本是否注册了 target 交互 |

### 症状: 手机打不开

| 步骤 | 操作 |
|:---|:---|
| 1 | 确认 custom-phone 加载（非 qb-phone） |
| 2 | 检查 NUI 是否被其他资源覆盖 |
| 3 | 在 F8 控制台检查 `custom-phone` NUI 消息 |

---

## 6. 性能调优

| 调优项 | 操作 | 预期效果 |
|:---|:---|:---|
| 增大 DirtyFlush 间隔 | `set dirty_flush_tick_interval 1800` | 30min 刷盘，降低 DB 负载 50% |
| 调整自适应经济 | `set economy_scale_step 0.03` | 更平缓的经济自动调整 |
| 关闭未使用的犯罪模块 | `set crime_enable_houserobbery false` | 减少警察检查开销 |
| 降低渲染负载 | 禁用 qb-hud 中不需要的指标 | 客户端 FPS 提升 |

---

## 7. 备份与恢复

### 数据库备份

```bash
mysqldump -u root -p QBCore_CDB34E > backup_$(date +%Y%m%d).sql
```

### 仅备份关键表

```sql
-- players (最重要)
SELECT * FROM players INTO OUTFILE '/tmp/players_backup.csv';
-- player_vehicles
SELECT * FROM player_vehicles INTO OUTFILE '/tmp/vehicles_backup.csv';
```

### 回滚后恢复 DirtyFlush

```lua
-- 如果从备份恢复后内存数据与 DB 不同步：
-- 1. 停止服务器
-- 2. 恢复 DB 备份
-- 3. 重新启动 — DirtyFlush 清空所有脏标记
```
