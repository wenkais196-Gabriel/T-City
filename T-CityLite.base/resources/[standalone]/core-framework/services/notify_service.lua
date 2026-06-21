-- notify_service.lua — 统一通知服务
-- 注册到 Bus，提供:
--   1. 服务端→客户端通知路由
--   2. 自定义通知类型插件注册
--   3. 通知事件发布/订阅
--   4. 防刷限流 + source 安全校验
--
-- 第三方模组对接示例:
--   Bus.notify.Send(source, '任务完成! $5,000', 'mission_pass')
--   Bus.notify.RegisterType('my_job', { type='mission_pass', channel='native', icon='CHAR_LESTER' })

-- ═══════════════════════════════════════════════════════════
-- 防刷限流: 每 source 每 windowMs 内最多 maxRequests 条通知
-- ═══════════════════════════════════════════════════════════
local rateLimiter = {}
local RATE_WINDOW_MS = 200        -- 限流窗口 200ms
local RATE_MAX_REQUESTS = 1       -- 窗口内最多 1 条

---@param source number
---@return boolean allowed
local function checkRateLimit(source)
    local now = GetGameTimer and GetGameTimer() or os.time() * 1000
    local entry = rateLimiter[source]

    if not entry then
        rateLimiter[source] = { count = 1, windowStart = now }
        return true
    end

    if now - entry.windowStart > RATE_WINDOW_MS then
        -- 窗口过期，重置
        entry.count = 1
        entry.windowStart = now
        return true
    end

    if entry.count >= RATE_MAX_REQUESTS then
        return false  -- 限流拒绝
    end

    entry.count = entry.count + 1
    return true
end

-- 定时清理过期限流记录
CreateThread(function()
    while true do
        Wait(60000)  -- 每分钟清理一次
        local now = GetGameTimer and GetGameTimer() or os.time() * 1000
        for source, entry in pairs(rateLimiter) do
            if now - entry.windowStart > 60000 then
                rateLimiter[source] = nil
            end
        end
    end
end)

-- ═══════════════════════════════════════════════════════════
-- 自定义通知类型注册表
-- ═══════════════════════════════════════════════════════════
local customTypes = {}

-- 从 qb-core 配置同步自定义类型
local function syncPluginTypesFromConfig()
    if not QBCore or not QBCore.Config or not QBCore.Config.Notify then return end
    local pluginTypes = QBCore.Config.Notify.PluginTypes
    if not pluginTypes then return end
    for _, def in ipairs(pluginTypes) do
        if def.type and not customTypes[def.type] then
            customTypes[def.type] = {
                plugin = 'qb-core-config',
                icon = def.icon,
                channel = def.channel or 'native',
                label = def.label or def.type,
            }
        end
    end
end

-- ═══════════════════════════════════════════════════════════
-- Service API
-- ═══════════════════════════════════════════════════════════
local NotifyService = {}

--- 注册自定义通知类型 (第三方模组扩展)
---@param pluginName string  插件名 (如 'custom-crime', 'police_job')
---@param typeDef table       { type: string, channel: 'native'|'nui', icon?: string, label?: string }
---@return boolean success
---@return string|nil error
function NotifyService.RegisterType(pluginName, typeDef)
    if not pluginName or type(pluginName) ~= 'string' then
        return false, 'pluginName required'
    end
    if not typeDef or not typeDef.type then
        return false, 'typeDef.type required'
    end
    if customTypes[typeDef.type] then
        return false, ('Notification type "%s" already registered by "%s"'):format(
            typeDef.type, customTypes[typeDef.type].plugin)
    end

    customTypes[typeDef.type] = {
        plugin = pluginName,
        icon = typeDef.icon,
        channel = typeDef.channel or 'native',
        label = typeDef.label or typeDef.type,
    }

    print(('[notify_service] 🔔 Plugin "%s" registered notification type: %s (channel=%s)')
        :format(pluginName, typeDef.type, typeDef.channel))
    return true
end

--- 注销自定义通知类型
---@param typeName string
function NotifyService.UnregisterType(typeName)
    if customTypes[typeName] then
        local plugin = customTypes[typeName].plugin
        customTypes[typeName] = nil
        print(('[notify_service] 🔕 Plugin "%s" unregistered type: %s'):format(plugin, typeName))
    end
end

--- 获取所有已注册的通知类型
---@return table { [typeName] = { plugin, icon, channel, label } }
function NotifyService.GetRegisteredTypes()
    return customTypes
end

--- 服务端发送通知 (核心方法)
---@param source number     目标玩家 source
---@param text string|table 通知文本
---@param texttype? string  通知类型: nil→原生, success/error...→NUI, 自定义→插件通道
---@param length? number    显示时长 (ms)
---@param icon? string      图标
function NotifyService.Send(source, text, texttype, length, icon)
    -- 安全校验: source 必须有效
    if not source or type(source) ~= 'number' or source <= 0 then
        print('[notify_service] ⚠️ Send rejected: invalid source')
        return
    end

    -- 安全校验: 玩家必须在线
    if GetPlayerPing and GetPlayerPing(source) == 0 then
        -- ping=0 通常意味着玩家不存在或离线
        return
    end

    -- 防刷限流
    if not checkRateLimit(source) then
        -- 超过限流阈值，静默丢弃
        return
    end

    -- 文本安全: 截断过长内容，移除控制字符
    local safeText = text
    if type(text) == 'string' then
        safeText = text:sub(1, 300)               -- 最大 300 字符
            :gsub('[\0\1\2\3]', '')               -- 移除控制字符
            :gsub('<[^>]*>', '')                   -- 去除 HTML 标签
    end

    -- 路由到客户端
    TriggerClientEvent('QBCore:Notify', source, safeText, texttype, length, icon)
end

--- 服务端广播通知 (所有玩家)
---@param text string|table
---@param texttype? string
---@param length? number
---@param icon? string
function NotifyService.Broadcast(text, texttype, length, icon)
    TriggerClientEvent('QBCore:Notify', -1, text, texttype, length, icon)
end

--- 服务端发送高级原生通知 (带头像/标题)
---@param source number
---@param title string   标题
---@param subject string 副标题
---@param text string    正文
---@param icon string    GTA 内建图标 (CHAR_*)
---@param length? number
function NotifyService.SendAdvanced(source, title, subject, text, icon, length)
    TriggerClientEvent('QBCore:Notify:Advanced', source, {
        title = title,
        subject = subject,
        text = text,
        icon = icon or 'CHAR_MULTIPLAYER',
        length = length or 5000,
    })
end

--- 订阅通知事件 (供日志/审计系统使用)
---@param callback function 回调: function(source, text, texttype, timestamp)
function NotifyService.Subscribe(callback)
    if not Bus or not Bus.Plugin then
        print('[notify_service] ⚠️ Bus.Plugin unavailable, cannot subscribe')
        return false
    end
    return Bus.Plugin.Subscribe('notify:sent', callback, 'notify_service')
end

-- ═══════════════════════════════════════════════════════════
-- 启动初始化
-- ═══════════════════════════════════════════════════════════

-- 同步 qb-core 配置中的插件类型
syncPluginTypesFromConfig()

-- 监听通知发送事件 (用于日志/审计)
AddEventHandler('QBCore:Notify:OnSend', function(source, text, texttype, timestamp)
    -- 发布到 Bus 事件总线，供插件订阅
    if Bus and Bus.Plugin then
        Bus.Plugin.Publish('notify:sent', source, text, texttype, timestamp)
    end
end)

-- ═══════════════════════════════════════════════════════════
-- 注册到 Bus (与其他服务一致的守卫模式)
-- ═══════════════════════════════════════════════════════════
if Bus and Bus.RegisterService then
    Bus.RegisterService('notify', {
    Send          = NotifyService.Send,
    Broadcast     = NotifyService.Broadcast,
    SendAdvanced  = NotifyService.SendAdvanced,
    RegisterType  = NotifyService.RegisterType,
    UnregisterType = NotifyService.UnregisterType,
    GetRegisteredTypes = NotifyService.GetRegisteredTypes,
    Subscribe     = NotifyService.Subscribe,
    })
    print('[notify_service] ✅ Service registered on Bus.notify (7 methods)')
else
    print('[notify_service] ⚠️ Bus not available — registration skipped (will retry via compat bridge)')
end
