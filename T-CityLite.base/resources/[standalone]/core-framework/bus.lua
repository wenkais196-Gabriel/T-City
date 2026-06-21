-- bus.lua — 统一导出总线 + i18n 安全兜底
-- 所有 Service 通过这里暴露接口，第三方模组通过这里对接
--
-- 使用示例:
--   local balance = Bus.Economy.GetBalance(source)
--   Bus.Economy.AddScaled(source, 'bank', 5000, '工资')

-- ═══════════════════════════════════════════════════════════
-- _L i18n 由 production-freeze 独家提供 (fxmanifest dependencies 保证先加载)
-- bus.lua 不再设置 fallback — 避免误触发 shared/i18n_shared.lua 的 skip guard
-- ═══════════════════════════════════════════════════════════

_G.Bus = _G.Bus or {}
Bus = _G.Bus  -- lua54: 显式 _G 确保跨资源可见

-- 已注册的 Service 列表
Bus._services = {}

--- 注册 Service
---@param name string Service 名称 (economy, job, player, etc.)
---@param methods table { methodName = function, ... }
function Bus.RegisterService(name, methods)
    Bus._services[name] = methods
    Bus[name] = {}

    for methodName, fn in pairs(methods) do
        -- 1. 注册到 Bus 命名空间
        Bus[name][methodName] = fn

        -- 2. 作为 export 暴露
        local exportName = ('service_%s_%s'):format(name, methodName)
        exports(exportName, fn)
    end

    local count = 0; for _ in pairs(methods) do count = count + 1 end
    print(('[bus] 📦 Service registered: %s (%d methods)'):format(name, count))
end

--- 获取 Service 引用
---@param name string
---@return table|nil
function Bus.GetService(name)
    return Bus._services[name]
end

--- 安全调用 Service 方法（带 pcall 保护）
---@param serviceName string
---@param methodName string
---@param ... any
---@return boolean success, any result
function Bus.SafeCall(serviceName, methodName, ...)
    local service = Bus._services[serviceName]
    if not service then
        print(('[bus] ⚠️ Service %s not found'):format(serviceName))
        return false, nil
    end
    local fn = service[methodName]
    if not fn then
        print(('[bus] ⚠️ Method %s/%s not found'):format(serviceName, methodName))
        return false, nil
    end
    local ok, result = pcall(fn, ...)
    if not ok then
        print(('[bus] ❌ Error in %s/%s: %s'):format(serviceName, methodName, tostring(result)))
        return false, nil
    end
    return true, result
end

-- ═══════════════════════════════════════════════════════════
-- Plugin Contract — 第三方模组统一接口
-- ═══════════════════════════════════════════════════════════
-- 第三方模组通过此 API 安全、标准地与核心数据交互:
--   1. Bus.Plugin.Register(name, schema)       — 注册模组
--   2. Bus.Plugin.GetSchema(name)              — 获取模组数据声明
--   3. Bus.Plugin.Subscribe(event, handler)    — 订阅跨资源事件
--   4. Bus.Plugin.GetEconomy()                 — 获取经济服务引用
--   5. Bus.Plugin.GetSecurity()                — 获取安全服务引用
--   6. Bus.Plugin.GetPersistence()             — 获取持久化服务引用
-- ═══════════════════════════════════════════════════════════

Bus.Plugin = {
    _plugins = {},
    _subscribers = {},
}

--- 注册第三方模组
---@param name string 模组名称 (如 'housing_system', 'money_laundering')
---@param schema table { version, author, description, dependencies?, dataSchema? }
---  dataSchema: { tables: { name, fields[] }, events: { name, params[] } }
---@return boolean success
---@return string|nil error
function Bus.Plugin.Register(name, schema)
    if not name or type(name) ~= 'string' or #name == 0 then
        return false, 'Plugin name required'
    end
    if Bus.Plugin._plugins[name] then
        return false, ('Plugin "%s" already registered'):format(name)
    end

    schema = schema or {}
    schema.version = schema.version or '1.0.0'
    schema.author = schema.author or 'unknown'
    schema.registered_at = os.time()

    Bus.Plugin._plugins[name] = schema
    print(('[bus] 🔌 Plugin registered: %s v%s by %s'):format(name, schema.version, schema.author))
    return true
end

--- 获取模组 Schema
---@param name string
---@return table|nil
function Bus.Plugin.GetSchema(name)
    return Bus.Plugin._plugins[name]
end

--- 注销模组
---@param name string
function Bus.Plugin.Unregister(name)
    Bus.Plugin._plugins[name] = nil
    Bus.Plugin._subscribers[name] = nil
    print(('[bus] 🔌 Plugin unregistered: %s'):format(name))
end

--- 订阅跨资源事件
---@param eventName string 事件名 (如 'economy:money_change', 'job:on_duty')
---@param handler function 回调函数
---@param pluginName string 订阅者模组名
---@return boolean success
function Bus.Plugin.Subscribe(eventName, handler, pluginName)
    if not eventName or not handler then return false end
    if not Bus.Plugin._subscribers[eventName] then
        Bus.Plugin._subscribers[eventName] = {}
    end
    table.insert(Bus.Plugin._subscribers[eventName], {
        plugin = pluginName or 'anonymous',
        handler = handler,
    })
    return true
end

--- 发布事件到所有订阅者
---@param eventName string
---@param ... any 事件参数
function Bus.Plugin.Publish(eventName, ...)
    local subs = Bus.Plugin._subscribers[eventName]
    if not subs then return end
    for _, sub in ipairs(subs) do
        local ok, err = pcall(sub.handler, ...)
        if not ok then
            print(('[bus] ⚠️ Plugin event "%s" handler error (%s): %s'):format(eventName, sub.plugin, tostring(err)))
        end
    end
end

--- 获取经济服务引用 (安全桥接)
---@return table|nil
function Bus.Plugin.GetEconomy()
    return Bus.economy or Bus.EconomyService or _G.EconomyService
end

--- 获取安全服务引用 (安全桥接)
---@return table|nil
function Bus.Plugin.GetSecurity()
    return Bus.security or Bus.SecurityService or _G.Bus and _G.Bus.SecurityService
end

--- 获取持久化服务引用 (安全桥接)
---@return table|nil
function Bus.Plugin.GetPersistence()
    return Bus.persistence or _G.Bus and _G.Bus.PersistenceManager
end

--- 列出所有已注册的插件
---@return table { name, version, author }
function Bus.Plugin.List()
    local list = {}
    for name, schema in pairs(Bus.Plugin._plugins) do
        table.insert(list, {
            name = name,
            version = schema.version,
            author = schema.author,
        })
    end
    return list
end

-- Export for cross-resource Bus status check
exports('BusStatus', function()
    local services = {}
    for name, _ in pairs(Bus._services) do
        table.insert(services, name)
    end
    return { loaded = true, services = services }
end)

-- DirtyFlush exports — 注册到 shared_scripts 以确保跨资源可访问
-- （server_scripts 中的 exports() 在 FiveM 中存在跨资源可见性问题）
exports('DirtyFlushMarkDirty', function(citizenid, dataType)
    if DirtyFlush then DirtyFlush.MarkDirty(citizenid, dataType) end
end)
exports('DirtyFlushStats', function()
    if DirtyFlush then return DirtyFlush.Stats() end
    return { dirty_count = 0 }
end)
exports('DirtyFlushFlushAll', function()
    if DirtyFlush then DirtyFlush.FlushAll() end
end)
exports('DirtyFlushFlushAllAsync', function()
    if DirtyFlush and DirtyFlush.FlushAllAsync then DirtyFlush.FlushAllAsync() end
end)
exports('DirtyFlushForceFlush', function(citizenid)
    if DirtyFlush then DirtyFlush.ForceFlush(citizenid) end
end)
exports('DirtyFlushForceFlushAsync', function(citizenid)
    if DirtyFlush and DirtyFlush.ForceFlushAsync then DirtyFlush.ForceFlushAsync(citizenid) end
end)

-- [bus] startup print removed (production mode)
