-- ==========================================
--  custom-admin 纯聊天框管理面板
--  不依赖 MenuV / NUI，用原生 chat 实现
-- ==========================================

local QBCore = exports['qb-core']:GetCoreObject()

-- A-2：/apanel 与 /menu 原来是**客户端** RegisterCommand(..., false)，
-- 任何玩家都能看到管理命令清单（信息泄露），而且客户端命令不经过服务端判权。
-- 现在由服务端注册（admin 权限），服务端把面板文本推回来。
RegisterNetEvent('custom-admin:client:printPanel', function(header, body)
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        multiline = true,
        args = { header, body },
    })
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
    end
end)

-- custom-admin startup print removed (production mode)
