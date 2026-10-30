-- server/coroner.lua — L2 后勤层的第一个服务：验尸官（蓝图 §6.2）。
--
-- 规则和支援单位一致：服务端持有名额、冷却、寿命与审计；客户端只负责把车开过来、
-- 把尸体抬走这两件事（服务端拿不到实体句柄）。
--
-- 三条边界：
--   1. 只有**在岗警察**能叫；一次只能有一单在跑（60 秒冷却）；
--   2. 名额走 NPCBudget（kind='coroner'，1 个 slot），满了就拒，不排队；
--   3. 180 秒没完成 → 服务端让客户端收车收人，名额照放，审计写 `coroner.expired`。

local CORONER_TTL_SECONDS = 180
local CORONER_COOLDOWN_SECONDS = 60
local CORONER_SWEEP_MS = 10000

local coronerRequests = {}   -- [requestId] = { cid, source, at }
local coronerCooldown = {}   -- [cid] = os.time()
local coronerSequence = 0

local function nextRequestId()
    coronerSequence = coronerSequence + 1
    return ('CR-%d-%d'):format(os.time(), coronerSequence)
end

local function audit(cid, event, requestId, detail)
    if type(PoliceAudit) ~= 'table' then return false end
    local ok, result = pcall(function()
        return PoliceAudit.Write(cid, event, requestId, detail)
    end)
    if not ok or not result then
        print(('[custom-police] coroner audit failed: %s (%s)'):format(tostring(event), tostring(requestId)))
        return false
    end
    return true
end

--- 放掉一单：名额回收 + 审计。`reason` 会出现在审计里，便于聚合。
local function releaseRequest(requestId, reason)
    local entry = coronerRequests[requestId]
    if not entry then return false end
    coronerRequests[requestId] = nil
    if type(NPCBudget) == 'table' and NPCBudget.Release then
        NPCBudget.Release(requestId, 'coroner_' .. tostring(reason))
    end
    if not audit(entry.cid, 'coroner.ended', requestId,
            ('reason=%s;live=%d'):format(tostring(reason), os.time() - (tonumber(entry.at) or os.time()))) then
        print(('[custom-police] coroner.ended audit failed: %s'):format(tostring(requestId)))
    end
    return true
end

--- 客户端上报完成（或失败）。只认自己名下的单号。
RegisterNetEvent('police:server:coronerDone', function(requestId, reason)
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'incident.update') then return end
    local entry = type(requestId) == 'string' and coronerRequests[requestId]
    if not entry or entry.source ~= src then return end
    local normalized = type(reason) == 'string' and #reason <= 24 and reason or 'done'
    releaseRequest(requestId, normalized)
end)

--- 玩家叫验尸官。`corpseNet` 由客户端提供（它才看得到那一具尸体是哪一个），
--- 服务端不复验实体归属：这是纯表现层动作，真正的权威是"谁在岗、有没有名额"。
RegisterNetEvent('police:server:coronerRequest', function(corpseNet)
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'incident.update') then return end
    if not data.job or data.job.onduty ~= true then return end
    local cid = type(data.citizenid) == 'string' and data.citizenid or ''
    if cid == '' then return end

    local last = coronerCooldown[cid] or 0
    if os.time() - last < CORONER_COOLDOWN_SECONDS then return end

    local requestId = nextRequestId()
    local admitted = NPCBudget and NPCBudget.Acquire and NPCBudget.Acquire('coroner', requestId, cid)
    if not admitted then
        if not audit(cid, 'coroner.rejected', requestId, 'budget') then
            print(('[custom-police] coroner.rejected audit failed: %s'):format(tostring(requestId)))
        end
        return
    end

    coronerCooldown[cid] = os.time()
    coronerRequests[requestId] = { cid = cid, source = src, at = os.time() }
    if not audit(cid, 'coroner.request', requestId, '') then
        print(('[custom-police] coroner.request audit failed: %s'):format(tostring(requestId)))
    end
    TriggerClientEvent('police:client:SpawnCoroner', src, requestId, tonumber(corpseNet) or 0)
end)

--- 寿命 sweep：到点先让客户端收车，再放名额（和支援单位同一套顺序）。
CreateThread(function()
    while true do
        Wait(CORONER_SWEEP_MS)
        local now = os.time()
        for requestId, entry in pairs(coronerRequests) do
            if now - (tonumber(entry.at) or now) >= CORONER_TTL_SECONDS then
                TriggerClientEvent('police:client:CoronerEnd', entry.source, requestId)
                releaseRequest(requestId, 'expired')
            end
        end
    end
end)

--- 玩家掉线：名额不能永远挂在死人身上。
AddEventHandler('playerDropped', function()
    local src = tonumber(source) or 0
    for requestId, entry in pairs(coronerRequests) do
        if entry.source == src then releaseRequest(requestId, 'dropped') end
    end
end)

--- 真机自测入口（默认关）：直接在玩家旁边摆一具尸体并叫一单。
---
--- 为什么需要它：验尸官的触发条件是"附近有尸体"，而造尸体要杀人——
--- 自动化测试没有这条路径，只能靠人工先死一次。这条命令把"造尸体 + 叫单"合成一步。
RegisterCommand('police_coroner_dev', function(source, args)
    if source ~= 0 then return end
    if GetConvar('police_coroner_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_coroner_dev 已关闭（setr police_coroner_dev_enabled 1 打开）')
        return
    end
    local target = tonumber(args and args[1])
    if not target then
        print('[custom-police] 用法: police_coroner_dev <serverId>')
        return
    end
    TriggerClientEvent('police:client:CoronerDevCorpse', target)
end, true)
