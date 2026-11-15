-- server/broadcast.lua — 受众感知广播的唯一入口（S7）。
--
-- 为什么需要它：`TriggerClientEvent(event, -1, ...)` 把消息发给**所有在线玩家**。证据类
-- 事件（血滴 / 指纹 / 弹壳）带着 DNA、血型、指纹与枪号，平民不该收到；每个业务点自己
-- 写一遍"遍历谁"又会分出十几种边界行为（在岗判定、离线、source 合法性）。
--
-- 用法（server-side include，不是 export）：
--   Broadcast.Scope(event, { all = true }, ...)                 -- 仍然全服，需在登记表说明
--   Broadcast.Scope(event, { job = 'police', onduty = true }, ...)
--   Broadcast.Scope(event, { source = src }, ...)
--   Broadcast.Scope(event, { coords = vec3(...), radius = 50 }, ...)
--
-- 未知/空受众返回 0，**不抛错、不重试**：广播是尽力而为，调用方不该为了"没人收"崩掉。

Broadcast = Broadcast or {}

--- 按受众发客户端事件；未知/空受众返回 0，不抛错。
--- audience: { all = true } | { job = 'police', onduty = true } |
---           { source = src } | { coords = vec3, radius = 50 }
---@return number recipients
function Broadcast.Scope(eventName, audience, ...)
    if type(eventName) ~= 'string' or eventName == '' then return 0 end
    if type(audience) ~= 'table' then return 0 end

    if audience.all == true then
        TriggerClientEvent(eventName, -1, ...)
        return GetNumPlayerIndices and GetNumPlayerIndices() or 0
    end

    local targets = {}
    if audience.job then
        -- GetPlayersByJob(job, checkOnDuty) 是 qb-core 的既有实现（server/functions.lua）：
        -- 同时匹配 job.name 与 job.type，checkOnDuty=true 时只返回在岗的人。
        local QBCore = exports['qb-core']:GetCoreObject()
        targets = QBCore.Functions.GetPlayersByJob(audience.job, audience.onduty == true) or {}
    elseif audience.source then
        targets = { tonumber(audience.source) }
    elseif audience.coords and audience.radius then
        local origin = audience.coords
        local radius = tonumber(audience.radius) or 0
        for _, src in ipairs(GetPlayers()) do
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 and #(GetEntityCoords(ped) - origin) <= radius then
                targets[#targets + 1] = tonumber(src)
            end
        end
    end

    local sent = 0
    for _, src in ipairs(targets) do
        if src and src > 0 then
            TriggerClientEvent(eventName, src, ...)
            sent = sent + 1
        end
    end
    return sent
end
