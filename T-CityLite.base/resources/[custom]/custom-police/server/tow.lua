-- server/tow.lua — L2 后勤层的第二个服务：拖车（蓝图 §6.2）。
--
-- 范围（方案 A，玩家确认）：**只拖 NPC 残骸**。
-- 玩家自己的车有归属（`player_vehicles`）和扣押流程，不属于这一片；
-- 这里宁可少做，也不要把玩家的车拖走或删掉。
--
-- 规则和验尸官一致：在岗警察、走 NPCBudget、60s 冷却、180s 寿命、审计三态。

local TOW_TTL_SECONDS = 180
local TOW_COOLDOWN_SECONDS = 60
local TOW_SWEEP_MS = 10000

local towRequests = {}   -- [requestId] = { cid, source, at }
local towCooldown = {}   -- [cid] = os.time()
local towSequence = 0

local function nextRequestId()
    towSequence = towSequence + 1
    return ('TW-%d-%d'):format(os.time(), towSequence)
end

local function audit(cid, event, requestId, detail)
    if type(PoliceAudit) ~= 'table' then return false end
    local ok, result = pcall(function()
        return PoliceAudit.Write(cid, event, requestId, detail)
    end)
    if not ok or not result then
        print(('[custom-police] tow audit failed: %s (%s)'):format(tostring(event), tostring(requestId)))
        return false
    end
    return true
end

local function releaseRequest(requestId, reason)
    local entry = towRequests[requestId]
    if not entry then return false end
    towRequests[requestId] = nil
    if type(NPCBudget) == 'table' and NPCBudget.Release then
        NPCBudget.Release(requestId, 'tow_' .. tostring(reason))
    end
    if not audit(entry.cid, 'tow.ended', requestId,
            ('reason=%s;live=%d'):format(tostring(reason), os.time() - (tonumber(entry.at) or os.time()))) then
        print(('[custom-police] tow.ended audit failed: %s'):format(tostring(requestId)))
    end
    return true
end

--- 这块车牌是不是玩家的车（`player_vehicles` 是归属的唯一事实源）。
---@param plate string|nil
---@return boolean owned
local function plateBelongsToPlayer(plate)
    if type(plate) ~= 'string' or plate == '' then return false end
    if type(MySQL) ~= 'table' or type(MySQL.single) ~= 'table' then return false end
    local ok, row = pcall(function()
        return MySQL.single.await('SELECT plate FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    end)
    if not ok then return false end
    return type(row) == 'table'
end

RegisterNetEvent('police:server:towRequest', function(plate, netId)
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'incident.update') then return end
    if not data.job or data.job.onduty ~= true then return end
    local cid = type(data.citizenid) == 'string' and data.citizenid or ''
    if cid == '' then return end

    -- 方案 A 的硬边界：玩家自己的车一律不拖（归属查库，不信客户端）。
    if plateBelongsToPlayer(plate) then
        if not audit(cid, 'tow.rejected', 'player_owned', tostring(plate)) then
            print('[custom-police] tow.rejected audit failed')
        end
        TriggerClientEvent('police:client:TowDenied', src, 'player_owned')
        return
    end

    local last = towCooldown[cid] or 0
    if os.time() - last < TOW_COOLDOWN_SECONDS then return end

    local requestId = nextRequestId()
    local admitted = NPCBudget and NPCBudget.Acquire and NPCBudget.Acquire('tow', requestId, cid)
    if not admitted then
        if not audit(cid, 'tow.rejected', requestId, 'budget') then
            print('[custom-police] tow.rejected audit failed')
        end
        return
    end

    towCooldown[cid] = os.time()
    towRequests[requestId] = { cid = cid, source = src, at = os.time() }
    if not audit(cid, 'tow.request', requestId, tostring(plate)) then
        print(('[custom-police] tow.request audit failed: %s'):format(requestId))
    end
    TriggerClientEvent('police:client:SpawnTow', src, requestId, tonumber(netId) or 0)
end)

RegisterNetEvent('police:server:towDone', function(requestId, reason)
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'incident.update') then return end
    local entry = type(requestId) == 'string' and towRequests[requestId]
    if not entry or entry.source ~= src then return end
    local normalized = type(reason) == 'string' and #reason <= 24 and reason or 'done'
    releaseRequest(requestId, normalized)
end)

CreateThread(function()
    while true do
        Wait(TOW_SWEEP_MS)
        local now = os.time()
        for requestId, entry in pairs(towRequests) do
            if now - (tonumber(entry.at) or now) >= TOW_TTL_SECONDS then
                TriggerClientEvent('police:client:TowEnd', entry.source, requestId)
                releaseRequest(requestId, 'expired')
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source) or 0
    for requestId, entry in pairs(towRequests) do
        if entry.source == src then releaseRequest(requestId, 'dropped') end
    end
end)

--- 真机自测：在玩家面前摆一辆报废的 NPC 车（不自动叫拖车）。
RegisterCommand('police_tow_dev', function(source, args)
    if source ~= 0 then return end
    if GetConvar('police_tow_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_tow_dev 已关闭（setr police_tow_dev_enabled 1 打开）')
        return
    end
    local target = tonumber(args and args[1])
    if not target then
        print('[custom-police] 用法: police_tow_dev <serverId>')
        return
    end
    TriggerClientEvent('police:client:TowDevWreck', target)
end, true)
