-- prison.lua — 监狱管理: 服刑计时、减刑、探视、出狱

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 入狱处理
-- ==============================================================

RegisterNetEvent('justice:server:imprison', function(citizenid, sentenceMinutes, crimes)
    -- 🛡️ Security: source 权威校验 + 权限检查 (仅警察/法官可入狱)
    local callerSrc = source
    local Caller = QBCore.Functions.GetPlayer(callerSrc)
    if not Caller then
        print(('[SECURITY] justice:server:imprison blocked — invalid caller (source=%s)'):format(tostring(callerSrc)))
        return
    end
    local callerJob = Caller.PlayerData.job.name
    if callerJob ~= 'police' and callerJob ~= 'judge' then
        print(('[SECURITY] justice:server:imprison blocked — unauthorized caller %s (job=%s)'):format(GetPlayerName(callerSrc), callerJob))
        return
    end

    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if not Player then
        -- 离线囚犯: 仅记录, 上线时恢复
        JusticeService.Inmates[citizenid] = {
            sentenceMinutes = sentenceMinutes,
            startTime = os.time(),
            crimes = crimes or {},
            reductions = {},
            offline = true,
        }
        return
    end

    local src = Player.PlayerData.source

    -- 存入囚犯追踪
    JusticeService.Inmates[citizenid] = {
        sentenceMinutes = sentenceMinutes,
        startTime = os.time(),
        crimes = crimes or {},
        reductions = {},
        src = src,
    }

    -- 传送入狱
    TriggerClientEvent('justice:client:enterPrison', src, {
        sentenceMinutes = sentenceMinutes,
        startTime = os.time(),
        crimes = crimes,
        reductions = {},
    })

    -- 通知
    TriggerClientEvent('QBCore:Notify', src,
        _L(src, 'justice_imprisoned', sentenceMinutes), 'error', 15000)

    -- 日志
    if exports['custom-logs'] then
        local crimeLabels = {}
        for _, cid in ipairs(crimes or {}) do
            local c = Config.Justice.Crimes[cid]
            if c then crimeLabels[#crimeLabels + 1] = c.label end
        end
        exports['custom-logs']:LogGeneric('入狱', ('%s (%s) | 刑期: %d分钟 | 罪名: %s'):format(
            GetPlayerName(src), citizenid, sentenceMinutes, table.concat(crimeLabels, ',')))
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
    local inmate = JusticeService.GetInmate(cid)
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
    JusticeService.ReleaseInmate(cid)

    -- 🌐 Atmosphere: complete scene on sentence served
    if Bus and Bus.SafeCall then Bus.SafeCall('atmosphere', 'PlayScene', src, 'complete') end

    TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_sentence_done'), 'success', 10000)

    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('出狱', ('%s (%s) | 刑满释放'):format(GetPlayerName(src), cid))
    end
end)

-- ==============================================================
-- 探视请求
-- ==============================================================

RegisterNetEvent('justice:server:requestVisit', function(inmateCitizenid)
    local src = source
    local Visitor = QBCore.Functions.GetPlayer(src)
    if not Visitor then return end

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
