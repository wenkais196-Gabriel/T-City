-- server/main.lua — 服务端入口 (v2.0)
--
-- 职责:
--   1. 注册到 core-framework Bus
--   2. playerDropped 清理
--   3. 导出查询接口
--
-- 注意: 中控屏排他锁/警笛/PA喊话/锚定等由 custom-vehicles 的 dashboard_api.lua 处理。
--       本资源客户端直接调用 custom-vehicles:server:* 事件，无需在本文件重复注册。

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- playerDropped: 清理排他锁（custom-vehicles 已处理，此处做冗余兜底）
-- ==============================================================

AddEventHandler('playerDropped', function(reason)
    local src = source
    -- 清理本地缓存（如有）
    if Security and Security.Cleanup then
        Security.Cleanup(src)
    end
end)

-- ==============================================================
-- 注册到 core-framework Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('dashboard', {
        GetTemplate = DashboardConfig.GetTemplate,
        HasFeature  = DashboardConfig.HasFeature,
        GetTheme    = DashboardThemes.Get,
    })
end

-- ==============================================================
-- Exports
-- ==============================================================

exports('GetRegisteredApps', function()
    return _registeredApps
end)

print('[tcity-dashboard] 🖥️ 服务端已就绪 (v2.0)')
print('[tcity-dashboard]   中控屏排他锁/警笛/PA/锚定 → 复用 custom-vehicles')
print('[tcity-dashboard]   Bus: service_dashboard_* 可用')
