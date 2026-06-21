# 📦 T-City Lite 脚本模板规范 (script_templates.md)

> **修订日期**: 2026-06-04  
> **适用语言**: Lua (FiveM Server/Client)  
> **核心作用**: 为新建资源或扩展业务提供**开箱即用、安全加固、性能最优**的最小脚本样板骨架。

---

## 1. 服务端标准脚本模板 (`sv_template.lua`)

服务端模板内置了：
1.  **分级日志包装器** (受 Convar `log_level` 控制)。
2.  **安全事件过滤机制** (使用 `custom-security` 和 `Bus.SecurityService` 进行防频刷校验与距离审计)。

```lua
-- =========================================================================
-- T-City Lite 服务端标准模板 (sv_template.lua)
-- =========================================================================

local RESOURCE_NAME = GetCurrentResourceName()
local Logger = {}
local LOG_LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local CURRENT_LEVEL = LOG_LEVELS[GetConvar("log_level", "INFO")] or 2

-- 内部日志函数
local function formatLog(level, color, msg, ...)
    local formatted = ... and string.format(msg, ...) or msg
    return string.format("%s [%s] %s", color, RESOURCE_NAME, formatted)
end

function Logger.debug(msg, ...) if CURRENT_LEVEL <= 1 then print(formatLog("DEBUG", "^5[DEBUG]^7", msg, ...)) end end
function Logger.info(msg, ...)  if CURRENT_LEVEL <= 2 then print(formatLog("INFO",  "^2[INFO] ^7", msg, ...)) end end
function Logger.warn(msg, ...)  if CURRENT_LEVEL <= 3 then print(formatLog("WARN",  "^3[WARN] ^7", msg, ...)) end end
function Logger.error(msg, ...) if CURRENT_LEVEL <= 4 then print(formatLog("ERROR", "^1[ERROR]^7", msg, ...)) end end

-- 交互防区物理坐标定义（如某个商店收银台）
local Config = {
    InteractCoords = vector3(120.0, -1500.0, 30.0),
    MaxDistance = 10.0,        -- 安全交互最大距离门槛 (米)
    CooldownMs = 3000          -- 防刷限流冷却 (毫秒)
}

-- 统一的安全过滤网络事件入口
RegisterNetEvent('my-resource:server:doSensitiveAction', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 限频拦截 (Rate Limit Check)
    local isRateLimited = exports['custom-security']:CheckRateLimit(src, "sensitive_action", Config.CooldownMs)
    if isRateLimited then
        Logger.warn("玩家 %s (%s) 发送敏感事件过于频繁，操作已被拦截", Player.PlayerData.charinfo.firstname, src)
        return
    end

    -- 2. 空间拓扑校验 (Physical Distance Check)
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    
    -- 高性能平方距离计算 (无开方开销)
    local dx = playerCoords.x - Config.InteractCoords.x
    local dy = playerCoords.y - Config.InteractCoords.y
    local dz = playerCoords.z - Config.InteractCoords.z
    local distSq = dx*dx + dy*dy + dz*dz

    if distSq > (Config.MaxDistance * Config.MaxDistance) then
        -- 触发安全警报并拒绝
        Logger.error("🚨 安全警报: 玩家 %s 距离过远 (实际 %.2f米, 上限 %d米)，疑似进行伪造封包攻击!", 
            Player.PlayerData.citizenid, math.sqrt(distSq), Config.MaxDistance)
        
        -- 调用日志 Service 记录 Discord
        exports['custom-logs']:LogSecurity(src, "检测到伪造坐标封包交互")
        return
    end

    -- 3. 玩家执勤状态/职业门槛校验 (Job State Check)
    if not Player.PlayerData.job.onduty then
        Logger.warn("玩家 %s 尝试在下班状态下执行操作，请求已被拒绝", Player.PlayerData.citizenid)
        return
    end

    -- 4. 通过全部拦截链，执行核心业务
    Logger.info("玩家 %s 通过安全校验，执行敏感交互操作", Player.PlayerData.citizenid)
    
    -- 结算资金统一经过自适应缩放出口
    exports['custom-economy']:AddScaledMoney(src, 'cash', 500, "测试模块安全结算")
end)
```

---

### 1.1 安全事件四层校验链（Server 端强制模式）

> [!WARNING]
> 所有涉及**金钱、道具、职位、帮派变更**的 `RegisterNetEvent` 必须按以下四层顺序校验，缺一不可。

```
┌─────────────────────────────────────────────┐
│  Layer 1: Source 权威校验                    │
│  local src = source                         │
│  local Player = QBCore.Functions.GetPlayer(src) │
│  if not Player then return end              │
├─────────────────────────────────────────────┤
│  Layer 2: 类型/数值校验                      │
│  if type(amount) ~= 'number' then return end │
│  if amount < 0 or amount > MAX then return end │
│  if type(isBool) ~= 'boolean' then return end │
├─────────────────────────────────────────────┤
│  Layer 3: 权限/职业/身份校验                  │
│  if Player.PlayerData.job.type ~= 'leo' ...  │
│  if not Player.PlayerData.job.isboss ...     │
│  if not Player.PlayerData.job.onduty ...     │
├─────────────────────────────────────────────┤
│  Layer 4: 物理距离校验 (平方距离)             │
│  local dx,dy,dz = ...                       │
│  if dx*dx+dy*dy+dz*dz > MAX_SQ then return end │
├─────────────────────────────────────────────┤
│  Layer 5: 限流/冷却 (可选，高频事件必加)       │
│  local now = os.time()                      │
│  if last[src] and (now-last[src]) < CD ...   │
└─────────────────────────────────────────────┘
```

**Boss 菜单点多坐标距离校验模式**（职业/帮派管理事件专用）：

```lua
-- Boss 菜单点通常在 Config.BossMenus / Config.GangMenus 中定义多个坐标
-- 校验操作者是否在任一 Boss 菜单点 5 米范围内
if not Config.BossMenus[Player.PlayerData.job.name] then return end
local bossCoords = Config.BossMenus[Player.PlayerData.job.name]
local playerPed = GetPlayerPed(src)
local playerCoords = GetEntityCoords(playerPed)
local nearBoss = false
for i = 1, #bossCoords do
    if #(playerCoords - bossCoords[i]) < 5.0 then nearBoss = true; break end
end
if not nearBoss then
    SecurityAuditLog(src, 'ActionName', '非 Boss 菜单点操作 — 疑似远程发包')
    return
end
```

**简易限流模式**（不依赖 custom-security 的独立模块可用）：

```lua
-- 模块级冷却表
if _cooldowns == nil then _cooldowns = {} end
local now = os.time()
local key = 'action_' .. src
if _cooldowns[key] and (now - _cooldowns[key]) < 3 then return end
_cooldowns[key] = now
-- ... 执行操作
```

### 1.2 并行异步查询模式（Callback 内多查询场景）

> [!TIP]
> 当 Callback 中需要执行 2+ 个独立数据库查询时，**禁止串行 `.await`**。使用并行 `MySQL.Async.fetchAll` + 计数器合并结果。

```lua
-- ❌ 禁止：串行同步阻塞（每个 .await 阻塞主线程直到返回）
local contacts = MySQL.query.await('SELECT * FROM player_contacts WHERE citizenid = ?', {cid})
local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', {cid})
local messages = MySQL.query.await('SELECT * FROM phone_messages WHERE citizenid = ?', {cid})

-- ✅ 推荐：并行异步 + 计数器模式
local pending = 3  -- 需要等待完成的查询数
local function tryFinalize()
    pending = pending - 1
    if pending <= 0 then
        cb(resultData)  -- 所有查询完成后回调
    end
end

MySQL.Async.fetchAll('SELECT * FROM player_contacts WHERE citizenid = ?', {cid},
    function(result)
        if result[1] then resultData.PlayerContacts = result end
        tryFinalize()
    end)

MySQL.Async.fetchAll('SELECT * FROM player_vehicles WHERE citizenid = ?', {cid},
    function(result)
        if result[1] then resultData.Garage = result end
        tryFinalize()
    end)

MySQL.Async.fetchAll('SELECT * FROM phone_messages WHERE citizenid = ?', {cid},
    function(result)
        if result[1] then resultData.Chats = result end
        tryFinalize()
    end)
```

> [!NOTE]
> 计数器初始值 = 并行查询数量。每个回调调用 `tryFinalize()`。最后一个完成的回调触发 `cb()`。如果存在内存缓存（如 PhoneCache TTL），先查缓存再决定是否执行查询块。

---

## 2. 客户端标准脚本模板 (`cl_template.lua`)

客户端模板内置了：
1.  **编译级调试日志开关**，保护 F8 隐私。
2.  **高性能动态 Tick 降频引擎** (依据距离判定，非交互期降为低频挂起，消除常驻 CPU 损耗)。

```lua
-- =========================================================================
-- T-City Lite 客户端标准模板 (cl_template.lua)
-- =========================================================================

local QBCore = exports['qb-core']:GetCoreObject()
-- ⚠️ 生产环境必须使用 Convar 控制，杜绝硬编码漏关
local enableDebugLogs = GetConvar('debug_client', 'false') == 'true'

local function DebugPrint(msg, ...)
    if enableDebugLogs then
        print(string.format("^5[DEBUG:my-resource] %s^7", ... and string.format(msg, ...) or msg))
    end
end

-- 额外安全：严禁在客户端 F8 打印玩家坐标
-- 需要输出坐标时，仅允许在 enableDebugLogs 守卫内执行

local Config = {
    TargetCoords = vector3(120.0, -1500.0, 30.0),
    ActiveDistance = 50.0 -- 开始启动高频渲染的触发距离门槛
}

-- 高性能动态 Tick 降频引擎
CreateThread(function()
    while true do
        local sleep = 1000 -- 默认远离交互点时，CPU 线程以 1Hz 超低频休眠
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        -- 空间平方距离判定
        local dx = playerCoords.x - Config.TargetCoords.x
        local dy = playerCoords.y - Config.TargetCoords.y
        local dz = playerCoords.z - Config.TargetCoords.z
        local distSq = dx*dx + dy*dy + dz*dz

        -- 如果进入了接近感应边界 (50米内)
        if distSq < (Config.ActiveDistance * Config.ActiveDistance) then
            sleep = 200 -- 提升监控频率到 5Hz (200ms)
            
            -- 如果处于极近物理交互区 (3米内)
            if distSq < 9.0 then
                sleep = 0 -- 唤起 60Hz 满帧渲染 (0ms)，绘制 3D 悬浮提示字或渲染交互效果
                
                -- 显示屏幕 UI 交互提示
                DrawMarker(2, Config.TargetCoords.x, Config.TargetCoords.y, Config.TargetCoords.z + 0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.3, 0.3, 0, 255, 0, 100, false, true, 2, false, nil, nil, false)
                
                -- 玩家按下交互键 E (38)
                if IsControlJustReleased(0, 38) then
                    DebugPrint("玩家按 E 触发交互，实时物理坐标: %s", tostring(playerCoords))
                    
                    -- 向服务端安全过滤层发起请求
                    TriggerServerEvent('my-resource:server:doSensitiveAction')
                end
            end
        else
            DebugPrint("远离交互区域，当前 Tick 彻底休眠挂起 (1000ms)")
        end

        Wait(sleep)
    end
end)
```
