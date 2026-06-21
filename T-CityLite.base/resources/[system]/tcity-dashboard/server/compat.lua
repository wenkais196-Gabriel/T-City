-- server/compat.lua — QBCore 向后兼容桥 (v2.0)
--
-- 新中控屏已直接使用 custom-vehicles 现有事件/export，无需桥接。
-- 此文件仅保留 RegisterDashboardApp export 供外部资源调用。

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 外部 App 注册 (兼容旧 RegisterDashboardApp export)
-- ==============================================================

local _registeredApps = {}

local function _RegisterDashboardApp(app)
    if not app or not app.id or not app.label then return false end
    for _, existing in ipairs(_registeredApps) do
        if existing.id == app.id then return false end
    end
    app.registered_at = os.time()
    _registeredApps[#_registeredApps + 1] = app
    for _, playerId in ipairs(GetPlayers()) do
        TriggerClientEvent('custom-vehicles:client:registerApp', tonumber(playerId), app)
    end
    return true
end

-- 玩家加载 → 推送已注册 App
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local src = Player.PlayerData.source
    for _, app in ipairs(_registeredApps) do
        TriggerClientEvent('custom-vehicles:client:registerApp', src, app)
    end
end)

-- 物流快捷装货桥接
RegisterNetEvent('custom-vehicles:server:logisticsQuickLoad', function()
    local src = source
    if exports['custom-quest'] then
        exports['custom-quest']:OnCustomEvent(src, 'dashboard_quick_load', {})
    end
end)

exports('RegisterDashboardApp', _RegisterDashboardApp)
