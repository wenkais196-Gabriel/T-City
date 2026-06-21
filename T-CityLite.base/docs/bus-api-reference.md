# T-City Lite — Bus API 插件开发手册

> **版本**: v1.0  
> **更新日期**: 2026  
> **前提**: `core-framework` 资源已启动

---

## 概述

`core-framework` 是 T-City Lite 的**统一数据访问层**，通过 `Bus` 全局总线暴露所有核心服务。第三方插件应通过 Bus API 与核心数据交互，**而非直接操作 QBCore.Players 或 qb-core exports**。

### 架构图

```
第三方插件 (custom-*, qb-*, ...)
         │
         ▼
    Bus API (core-framework/bus.lua)
         │
    ┌────┼────────────────────────────┐
    ▼    ▼         ▼          ▼       ▼
 Economy JobService Security Persistence Metadata
 Service          Service   Manager   Service
```

---

## 1. Bus.Economy — 经济服务

**位置**: `services/economy_service.lua`

### 方法

#### `Bus.Economy.GetBalance(source, accountType?)`
获取玩家余额（内存优先，不查库）。

```lua
local cash = Bus.Economy.GetBalance(source, 'cash')  -- → number
local all = Bus.Economy.GetBalance(source)             -- → { cash=500, bank=5000, crypto=0 }
```

#### `Bus.Economy.AddScaled(source, accountType, amount, reason)`
带经济倍率缩放的加钱（统一出口）。自动应用 `economy_wage_multiplier` Convar。

```lua
local finalAmount, scale = Bus.Economy.AddScaled(source, 'bank', 5000, 'paycheck')
-- scale = 1.0 (无缩放) 或 1.2 (20% 加成)
-- finalAmount = 5000 或 6000
```

#### `Bus.Economy.Transfer(fromSource, toCitizenId, amount, reason)`
玩家间转账（带安全校验）。

```lua
local ok, msg = Bus.Economy.Transfer(source, 'ABC123XYZ', 10000, 'loan repayment')
-- ok = true|false, msg = 'Transferred to online player' | 'Recipient not found, rollback triggered'
```

---

## 2. Bus.JobService — 职业/帮派服务

**位置**: `services/job_service.lua`

### 方法

#### `Bus.JobService.GetJob(source)`
获取玩家职业（内存优先 O(1)）。

```lua
local job = Bus.JobService.GetJob(source)
-- → { name='police', label='Police', grade={level=3, name='Sergeant'}, onduty=true, ... }
```

#### `Bus.JobService.SetJob(source, jobName, grade, reason)`
设置玩家职业（自动安全校验 + 审计日志）。

```lua
local ok, err = Bus.JobService.SetJob(source, 'ambulance', 2, 'hired by chief')
```

#### `Bus.JobService.RemoveJob(source, reason)`
移除职业（设为 unemployed）。

```lua
local ok, err = Bus.JobService.RemoveJob(source, 'fired')
```

#### `Bus.JobService.SetOnDuty(source, onDuty)`
设置执勤状态。

```lua
Bus.JobService.SetOnDuty(source, true)
```

#### `Bus.JobService.GetGang(source)`
获取帮派（内存优先）。

#### `Bus.JobService.SetGang(source, gangName, grade, reason)`
设置帮派（自动安全校验 + 审计日志）。

#### 统计查询

```lua
local policeCount = Bus.JobService.GetOnDutyCount('police')
local gangMembers = Bus.JobService.GetGangOnlineCount('ballas')
local sources = Bus.JobService.GetOnlinePlayersByJob('mechanic')
```

---

## 3. Bus.SecurityService — 安全防火墙

**位置**: `services/security_service.lua`

### 方法

#### `Bus.SecurityService.ValidateSource(source)`
校验 source 是否为有效在线玩家。

```lua
local ok, Player, err = Bus.SecurityService.ValidateSource(source)
if not ok then
    -- err = 'Invalid source: 0' | 'Player not found for source: 5'
end
```

#### `Bus.SecurityService.ValidateMoneyEvent(source, amount, accountType, reason)`
金钱事件全量校验（source + 金额清洗 + 单笔阈值 + 累计熔断）。

```lua
local ok, cleanedAmount, err = Bus.SecurityService.ValidateMoneyEvent(source, 50000, 'bank', 'salary')
if not ok then
    -- err = 'Single money change ($50000) exceeds max ($500000)'
end
```

#### `Bus.SecurityService.ValidateJobEvent(source, jobName, grade)`
职业变更事件校验。

```lua
local ok, cleanedJob, cleanedGrade, err = Bus.SecurityService.ValidateJobEvent(source, 'police', 3)
```

#### `Bus.SecurityService.ValidateGangEvent(source, gangName, grade)`
帮派变更事件校验。

#### `Bus.SecurityService.ValidateItemEvent(source, itemName, count)`
物品变动事件校验。

#### 清洗器

```lua
local num, err = Bus.SecurityService.SanitizeNumber('50000', { min=1, max=500000, integer=true })
local str, err = Bus.SecurityService.SanitizeString('  hello  ', { maxLength=10, trim=true })
```

---

## 4. Bus.PersistenceService — 持久化管理器

**位置**: `services/persistence_manager.lua`

### 方法

#### `Bus.PersistenceService.FlushAll()`
全量刷盘所有脏玩家。

```lua
Bus.PersistenceService.FlushAll()
```

#### `Bus.PersistenceService.ForceFlushPlayer(citizenid)`
强制刷盘单个玩家（用于断线/下线）。

```lua
Bus.PersistenceService.ForceFlushPlayer('ABC123XYZ')
```

#### `Bus.PersistenceService.Stats()`
获取持久化统计。

```lua
local stats = Bus.PersistenceService.Stats()
-- → { dirty_pool_size=12, flush_count=45, force_count=23, total_players_flushed=890, ... }
```

---

## 5. DirtyFlush — 脏数据管道（底层）

**位置**: `cache/dirty_flush.lua`

### 方法

#### `DirtyFlush.MarkDirty(citizenid, dataType)`
标记玩家为脏数据。`dataType`: `'money'` | `'metadata'` | `'all'`

```lua
DirtyFlush.MarkDirty('ABC123XYZ', 'money')
```

#### `DirtyFlush.ForceFlush(citizenid)`
强制刷盘指定玩家（直接 SQL，不经过 Save 循环）。

#### `DirtyFlush.FlushAll()`
全量刷盘所有脏玩家。

#### `DirtyFlush.Stats()`
获取脏玩家池统计。

---

## 6. Bus.Notify — 通知服务

**位置**: `services/notify_service.lua`  
**新增**: v2.1 — 双轨制通知 (原生 GTA The Feed + NUI 高级通知)

### 架构

```
QBCore.Functions.Notify(text, type, length, icon)
  │
  ├─ type=nil / 'primary' → NUI 原生风格 (黑底白字 + 左侧色条)
  ├─ type=success/error/warning/police/ambulance → NUI 高级通知
  └─ type=custom (插件注册) → Bus.Plugin 事件总线
```

### 方法

#### `Bus.Notify.Send(source, text, texttype?, length?, icon?)`
服务端发送通知 (含 Source 校验 + 200ms 限流 + 内容清洗)。

```lua
Bus.Notify.Send(source, '转账成功 $5,000', 'success', 5000)
```

#### `Bus.Notify.Broadcast(text, texttype?, length?)`
全服广播。

```lua
Bus.Notify.Broadcast('📢 服务器将在 5 分钟后重启', 'warning', 10000)
```

#### `Bus.Notify.SendAdvanced(source, title, subject, text, icon, length?)`
发送高级原生通知 (GTA The Feed 带角色头像)。

```lua
Bus.Notify.SendAdvanced(source,
    '银行系统', '转账通知',
    '您收到 $50,000', 'CHAR_BANK_MAZE', 5000)
```

#### `Bus.Notify.RegisterType(pluginName, typeDef)`
注册自定义通知类型 (插件扩展)。

```lua
-- 注册任务通知类型
Bus.Notify.RegisterType('custom-quest', {
    type = 'mission_pass',
    channel = 'native',       -- 'native' | 'nui'
    icon = 'CHAR_LESTER',     -- GTA 内建图标
})

-- 之后任何地方调用 Notify(text, 'mission_pass') 自动路由到指定通道
QBCore.Functions.Notify(source, '任务完成！', 'mission_pass')
```

#### `Bus.Notify.UnregisterType(typeName)`
注销自定义通知类型。

#### `Bus.Notify.GetRegisteredTypes()`
获取所有已注册的自定义通知类型。

#### `Bus.Notify.Subscribe(callback)`
订阅通知事件 (供日志/审计系统)。

```lua
Bus.Notify.Subscribe(function(source, text, texttype, timestamp)
    print(('📋 [审计] %s → %s (%s)'):format(source, text, texttype))
end)
```

### 安全

| 校验层 | 说明 |
|:---|:---|
| Source 有效 | `type(source) == 'number' and source > 0` |
| 玩家存活 | `GetPlayerPing(source) > 0` |
| 内容清洗 | 截断 300 字符 + 移除控制字符 + 去除 HTML 标签 |
| 限流 | 200ms 窗口内每玩家最多 1 条 |

### GTA 内建图标常量

注册自定义类型时可用的图标：

```
CHAR_BANK_MAZE, CHAR_LESTER, CHAR_MICHAEL, CHAR_FRANKLIN, CHAR_TREVOR,
CHAR_SIMEON, CHAR_MARTIN, CHAR_LAMAR, CHAR_MERRYWEATHER, CHAR_LS_CUSTOMS,
CHAR_CALL911, CHAR_CARSITE, CHAR_CREW, CHAR_SOCIAL_CLUB, CHAR_MULTIPLAYER,
... (完整列表见 native_notify.lua NOTIFY_ICONS)
```

---

## 7. Exports 快速参考

| Export | 来源 | 说明 |
|--------|------|------|
| `exports['custom-main']:AddScaledMoney(src, type, amount, reason)` | custom-main | 带倍率加钱 |
| `exports['custom-career']:GetPlayerIdentity(src)` | custom-career | 多标签身份 |
| `exports['custom-career']:PlayerMatchesTags(src, tags)` | custom-career | 标签比对 |
| `exports['custom-career']:AddPlayerCert(src, certId)` | custom-career | 授予资质 |
| `exports['custom-quest']:TriggerQuest(src, questId)` | custom-quest | 接取任务 |
| `exports['custom-quest']:GetQuestCatalog()` | custom-quest | 任务目录 |
| `exports['custom-security']:CheckRateLimit(src, action, ms)` | custom-security | 频率限制 |
| `exports['custom-logs']:LogEconomy(title, msg, color)` | custom-logs | 经济审计日志 |
| `exports['custom-logs']:LogSecurity(title, msg, color)` | custom-logs | 安全审计日志 |
| `exports['qb-core']:NativeNotifyReady()` | qb-core | 原生通知模块心跳 |
| `exports['qb-core']:NativeNotifyShow(text)` | qb-core | 原生 Feed 通知 |
| `exports['qb-core']:NativeNotifyShowHelpText(text, dur)` | qb-core | 原生 Help Text |
| `exports['core-framework']:service_notify_Send(src, text, type, len)` | core-framework | 服务端通知 |
| `exports['core-framework']:service_notify_Broadcast(text, type, len)` | core-framework | 全服广播 |
| `exports['core-framework']:service_notify_SendAdvanced(src, title, sub, text, icon, len)` | core-framework | 高级原生通知 |
| `exports['core-framework']:service_notify_RegisterType(plugin, def)` | core-framework | 注册自定义通知类型 |
| `exports['core-framework']:service_notify_GetRegisteredTypes()` | core-framework | 获取已注册类型 |

---

## 向后兼容保证

所有对 `Player.Functions.AddMoney`、`Player.Functions.SetJob` 的旧版调用**语法不变**，底层自动路由到新服务：

```lua
-- ✅ 旧代码无需任何修改，自动享受安全校验 + 脏数据管道
local Player = QBCore.Functions.GetPlayer(source)
Player.Functions.AddMoney('bank', 5000, 'legacy_code_reward')
Player.Functions.SetJob('police', 3)
```

兼容层（`compat.lua`）负责桥接，新服务不可用时自动 fallback 到原始逻辑。
