local QBCore = exports['qb-core']:GetCoreObject()

local function DebugPrint(msg)
    if QBConfig
        and QBConfig.Custom
        and QBConfig.Custom.General
        and QBConfig.Custom.General.EnableDebug
    then
        print(msg)
    end
end

-- 客户端自用频率限制冷却状态
local ClientCooldowns = {}

-- ==========================================
--            手 动 冷 却 校 验 (Client-Side)
-- ==========================================

-- 辅助客户端脚本判定操作冷却
-- @param action string 操作标识名
-- @param cooldownMs number 冷却毫秒数
-- @return boolean 是否允许操作 (true: 允许; false: 被限制)
local function CheckClientRateLimit(action, cooldownMs)
    local now = GetGameTimer()
    local lastTrigger = ClientCooldowns[action] or 0
    local diff = now - lastTrigger

    if diff < cooldownMs then
        return false
    end

    ClientCooldowns[action] = now
    return true
end

exports('CheckClientRateLimit', CheckClientRateLimit)

-- ==========================================
--              线 程 测 试 与 提 示
-- ==========================================

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    -- 玩家加载完成后输出系统防护启动提示
    TriggerEvent('chat:addMessage', {
        color = { 113, 111, 206 },
        multiline = true,
        args = { "System", "🛡️ T-City Lite 安全卫士与防刷模块已为您加载就绪。" }
    })
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    DebugPrint("[custom-main][security] Client-side anti-exploit module loaded successfully.")
end)
