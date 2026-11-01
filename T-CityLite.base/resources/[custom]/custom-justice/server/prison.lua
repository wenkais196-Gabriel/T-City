-- prison.lua — 监狱管理: 服刑计时、减刑、探视、出狱

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 入狱处理
-- ==============================================================

--- Server-side incarceration. Only call from a trusted server path (trial
--- verdict, judge command); the net event below is a compatibility wrapper
--- that validates the caller first.
---
--- The durable row in `justice_sentences` is authoritative. `metadata.injail`
--- is only the qb-prison projection; it is written here (online) or on the
--- next PlayerLoaded (offline sentencing), never trusted as input.
---
--- @param citizenid string
--- @param sentenceMinutes number
--- @param crimes string[]|nil
--- @param opts table|nil { replace=boolean, caseId=string, reason=string, createdBy=string }
--- @return boolean ok, string|nil error
function JusticeService.Imprison(citizenid, sentenceMinutes, crimes, opts)
    citizenid = tostring(citizenid or '')
    if #citizenid == 0 or #citizenid > 50 then return false, 'invalid_citizen' end
    sentenceMinutes = math.floor(tonumber(sentenceMinutes) or 0)
    if sentenceMinutes <= 0 then return false, 'invalid_sentence' end
    local maxSentence = (Config.Justice and Config.Justice.MaxSentence) or 120
    if sentenceMinutes > maxSentence then sentenceMinutes = maxSentence end
    crimes = type(crimes) == 'table' and crimes or {}
    opts = type(opts) == 'table' and opts or {}

    local labels = {}
    for _, crimeId in ipairs(crimes) do
        local crime = Config.Justice.Crimes[crimeId]
        if crime then labels[#labels + 1] = crime.label end
    end
    local caseId = opts.caseId or opts.case_id
    local reason = opts.reason or ('罪名: ' .. table.concat(labels, ','))
    local mode = opts.replace and 'set' or 'add'

    -- Server-authoritative timer. A failed write must not be reported as a
    -- successful jailing, otherwise the caller's rollback path is misled.
    local called, remaining, applyErr = pcall(
        JusticeSentences.Apply, citizenid, sentenceMinutes, caseId, reason, mode, opts.createdBy)
    if not called or type(remaining) ~= 'number' or remaining <= 0 then
        print(('[justice-prison] ⚠️ sentence write failed for %s: %s'):format(
            citizenid, tostring(applyErr or remaining)))
        return false, 'sentence_failed'
    end
    remaining = math.floor(remaining)

    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    local useQbPrison = GetResourceState('qb-prison') == 'started'

    if not Player then
        -- Offline sentencing: the DB row already runs. PlayerLoaded projects it
        -- into metadata and enters the cell; do not try to teleport nobody.
        JusticeService.Inmates[citizenid] = {
            sentenceMinutes = remaining, startTime = os.time(),
            crimes = crimes, reductions = {}, offline = true,
            caseId = caseId, reason = reason,
        }
        return true
    end

    local src = Player.PlayerData.source
    JusticeService.Inmates[citizenid] = {
        sentenceMinutes = remaining, startTime = os.time(),
        crimes = crimes, reductions = {}, src = src,
        qbPrison = useQbPrison, caseId = caseId, reason = reason,
    }

    -- Hand the sentence to qb-prison when available: it owns the cell, item
    -- seizure and release. Fall back to the justice prison only if qb-prison
    -- is not running.
    if useQbPrison then
        Player.Functions.SetMetaData('injail', remaining)
        TriggerClientEvent('prison:client:Enter', src, remaining)
    else
        TriggerClientEvent('justice:client:enterPrison', src, {
            sentenceMinutes = remaining, startTime = os.time(),
            crimes = crimes, reductions = {},
        })
    end
    TriggerClientEvent('QBCore:Notify', src,
        _L(src, 'justice_imprisoned', remaining), 'error', 15000)
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('入狱', ('%s (%s) | 刑期: %d分钟 | 罪名: %s'):format(
            GetPlayerName(src), citizenid, remaining, table.concat(labels, ',')))
    end
    return true
end

RegisterNetEvent('justice:server:imprison', function(citizenid, sentenceMinutes, crimes)
    local callerSrc = source
    local Caller = QBCore.Functions.GetPlayer(callerSrc)
    if not Caller then return end
    local callerJob = Caller.PlayerData.job.name
    if callerJob ~= 'police' and callerJob ~= 'judge' then
        print(('[SECURITY] justice:server:imprison blocked — unauthorized caller %s (job=%s)'):format(GetPlayerName(callerSrc), callerJob))
        return
    end
    JusticeService.Imprison(citizenid, sentenceMinutes, crimes)
end)

--- Project an active DB sentence onto a player who just loaded.
---
--- Offline sentencing cannot write metadata at verdict time, so this is the
--- login hand-off: set metadata to the DB remaining minutes and, when there was
--- no projection before login, enter the cell explicitly (qb-prison's own
--- OnPlayerLoaded only enters when metadata was already > 0).
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local data = Player and Player.PlayerData
    if not data then return end
    local cid = data.citizenid
    if not cid or not JusticeSentences then return end

    local ok, seconds = pcall(JusticeSentences.RemainingSeconds, cid)
    if not ok then
        -- DB unavailable: leave the existing projection untouched. qb-prison's
        -- SetJailStatus will also fail its export lookup and use its clamped
        -- fallback rather than silently freeing the player.
        print(('[justice-prison] ⚠️ login sentence lookup failed for %s: %s'):format(
            tostring(cid), tostring(seconds)))
        return
    end

    local metadata = data.metadata or {}
    local wasInJail = (tonumber(metadata.injail) or 0) > 0
    local remainingSeconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local remainingMinutes = math.ceil(remainingSeconds / 60)
    print(('[justice-prison] PlayerLoaded %s remaining=%s wasInJail=%s'):format(
        tostring(cid), tostring(remainingSeconds), tostring(wasInJail)))

    if remainingMinutes <= 0 then
        JusticeService.Inmates[cid] = nil
        if wasInJail then
            Player.Functions.SetMetaData('injail', 0)
            if GetResourceState('qb-prison') == 'started' then
                TriggerClientEvent('prison:client:UnjailPerson', data.source)
            else
                TriggerClientEvent('justice:client:released', data.source)
            end
        end
        return
    end

    local sentenceOk, sentence = pcall(JusticeSentences.Get, cid)
    if not sentenceOk then sentence = nil end
    local totalMinutes = sentence and tonumber(sentence.minutes) or remainingMinutes
    totalMinutes = math.max(remainingMinutes, math.floor(totalMinutes))
    local startedAt = os.time() - math.max(0, totalMinutes * 60 - remainingSeconds)

    JusticeService.Inmates[cid] = {
        sentenceMinutes = totalMinutes,
        startTime = startedAt,
        crimes = {},
        reductions = {},
        src = data.source,
        qbPrison = GetResourceState('qb-prison') == 'started',
        offline = false,
    }
    Player.Functions.SetMetaData('injail', remainingMinutes)

    if GetResourceState('qb-prison') == 'started' then
        -- A pre-existing projection is restored by qb-prison's own
        -- OnPlayerLoaded using the metadata just refreshed above. An offline
        -- verdict has no projection yet, so the server must enter the cell.
        if not wasInJail then
            TriggerClientEvent('prison:client:Enter', data.source, remainingMinutes)
        end
    else
        TriggerClientEvent('justice:client:enterPrison', data.source, {
            sentenceMinutes = remainingMinutes,
            startTime = startedAt,
            crimes = {},
            reductions = {},
        })
    end
end)


-- ==============================================================
-- 减刑请求 (良好表现自动触发或律师申请)
-- ==============================================================

RegisterNetEvent('justice:server:requestReduction', function(reductionType)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local cid = Player.PlayerData.citizenid
    local inmate = JusticeService.GetOwnInmate(Player)
    if not inmate then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_not_in_prison'), 'error')
        return
    end

    local reduction = Config.Justice.Reductions[reductionType]
    if not reduction then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_invalid_reduction'), 'error')
        return
    end

    -- Cannot reuse same reduction
    for _, r in ipairs(inmate.reductions) do
        if r.type == reductionType then
            TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_already_used'), 'error')
            return
        end
    end

    local reducedMinutes = math.floor(inmate.sentenceMinutes * reduction.rate)
    inmate.sentenceMinutes = inmate.sentenceMinutes - reducedMinutes
    inmate.reductions[#inmate.reductions + 1] = { type = reductionType, minutes = reducedMinutes }

    TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_reduction_ok', reducedMinutes, reduction.label), 'success')

    -- 减到0直接释放
    if inmate.sentenceMinutes <= 0 then
        JusticeService.ReleaseInmate(cid)
    end
end)

-- ==============================================================
-- 服刑完成 → 释放
-- ==============================================================

RegisterNetEvent('justice:server:sentenceComplete', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local cid = Player.PlayerData.citizenid
    local inmate = JusticeService.GetOwnInmate(Player)
    if not inmate then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_not_inmate') or 'You are not in prison', 'error')
        return
    end

    -- 🔒 刑期校验：客户端不能自报"服刑完毕"
    local elapsedMin = math.floor((os.time() - (inmate.startTime or os.time())) / 60)
    if elapsedMin < (inmate.sentenceMinutes or 0) then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_not_done') or 'Sentence not served yet', 'error')
        return
    end

    JusticeService.ReleaseInmate(cid)

    -- 🌐 Atmosphere: complete scene on sentence served
    if GetResourceState('tcity-atmosphere') == 'started' then
        pcall(function()
            exports['tcity-atmosphere']:service_atmosphere_PlayScene(src, 'complete')
        end)
    end

    TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_sentence_done'), 'success', 10000)

    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('出狱', ('%s (%s) | 刑满释放'):format(GetPlayerName(src), cid))
    end
end)

-- ==============================================================
-- 探视请求
-- ==============================================================

-- 探视请求会给**另一个玩家**推通知：必须限频，否则任何人可以对囚犯刷屏
local VISIT_REQUEST_COOLDOWN_MS = 5000
local visitRequestAt = {}   -- [src] = GetGameTimer()

RegisterNetEvent('justice:server:requestVisit', function(inmateCitizenid)
    local src = source
    local Visitor = QBCore.Functions.GetPlayer(src)
    if not Visitor then return end

    local now = GetGameTimer() or 0
    if now - (visitRequestAt[src] or 0) < VISIT_REQUEST_COOLDOWN_MS then return end
    visitRequestAt[src] = now
    if type(inmateCitizenid) ~= 'string' or #inmateCitizenid > 50 then return end

    local inmate = JusticeService.GetInmate(inmateCitizenid)
    if not inmate then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_not_inmate'), 'error')
        return
    end

    local InmatePlayer = QBCore.Functions.GetPlayerByCitizenId(inmateCitizenid)
    if not InmatePlayer then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_inmate_offline'), 'error')
        return
    end

    -- 通知囚犯有探视请求
    TriggerClientEvent('QBCore:Notify', InmatePlayer.PlayerData.source,
        _L(InmatePlayer.PlayerData.source, 'justice_visit_request', GetPlayerName(src)), 'primary')
    TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_visit_sent', InmatePlayer.PlayerData.charinfo.firstname), 'success')
end)

-- ==============================================================
-- 定时检查刑期 (每分钟)
-- ==============================================================

CreateThread(function()
    while true do
        Wait(60000)  -- 每分钟检查一次

        local now = os.time()
        for cid, inmate in pairs(JusticeService.Inmates or {}) do
            if not inmate.offline then
                -- 良好表现自动减刑 (每分钟自动减 15%/总刑期 的速率)
                -- 不重复应用，此处简化处理
            end
        end
    end
end)

-- ==============================================================
-- 命令
-- ==============================================================

QBCore.Commands.Add('inmates', '查看在押囚犯 (警察/法官)', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local job = Player.PlayerData.job.name
    if job ~= 'police' and job ~= 'judge' then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_police_only'), 'error')
        return
    end

    local inmates = JusticeService.GetInmates()
    local count = 0
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 100, 50 }, args = { _L(source, 'justice_inmates_title'), '' }
    })
    for cid, inmate in pairs(inmates) do
        count = count + 1
        local remaining = inmate.sentenceMinutes
        if not inmate.offline then
            local elapsed = math.floor((os.time() - inmate.startTime) / 60)
            remaining = math.max(0, inmate.sentenceMinutes - elapsed)
        end
        local PlayerName = _L(source, 'justice_offline')
        if not inmate.offline then
            local p = QBCore.Functions.GetPlayerByCitizenId(cid)
            if p then PlayerName = GetPlayerName(p.PlayerData.source) end
        end
        TriggerClientEvent('chat:addMessage', source, {
            color = { 200, 200, 200 },
            args = { '  ', _L(source, 'justice_inmate_row', PlayerName, remaining, inmate.offline and _L(source, 'justice_offline') or _L(source, 'justice_online')) }
        })
    end
    if count == 0 then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_no_inmates'), 'primary')
    end
end, 'user')

print('[justice-prison] 🔒 监狱管理已加载')
