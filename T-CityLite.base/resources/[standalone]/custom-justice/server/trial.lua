-- trial.lua — 审判系统: 法官开庭 → 律师辩护 → 量刑

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 事件: 法官开庭审判
-- ==============================================================

RegisterNetEvent('justice:server:startTrial', function(caseId)
    local src = source
    local Judge = QBCore.Functions.GetPlayer(src)
    if not Judge or Judge.PlayerData.job.name ~= 'judge' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_judge_only'), 'error')
        return
    end

    local case = JusticeService.GetCase(caseId)
    if not case then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_case_not_found'), 'error')
        return
    end

    if case.status == 'sentenced' or case.status == 'closed' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_case_closed'), 'error')
        return
    end

    -- 是否有律师
    local hasLawyer = #case.lawyers > 0

    -- 计算基础刑期
    local baseMinutes = 0
    for _, crimeId in ipairs(case.crimes) do
        local crime = Config.Justice.Crimes[crimeId]
        if crime then baseMinutes = baseMinutes + crime.baseMinutes end
    end

    -- 计算罚款
    local baseFine = 0
    for _, crimeId in ipairs(case.crimes) do
        local crime = Config.Justice.Crimes[crimeId]
        if crime then baseFine = baseFine + crime.fine end
    end

    -- 律师辩护减刑
    local lawyerReduction = 0
    if hasLawyer then
        lawyerReduction = math.floor(baseMinutes * Config.Justice.Reductions.lawyer_defense.rate)
    end

    -- 初犯减免 (简化: 目前一律适用)
    local firstOffenseReduction = math.floor(baseMinutes * Config.Justice.Reductions.first_offense.rate)

    -- 最终刑期
    local finalMinutes = math.max(5, baseMinutes - lawyerReduction - firstOffenseReduction)

    -- 通知所有相关方
    local verdict = {
        caseId = caseId,
        suspectName = case.suspect.name,
        judgeName = GetPlayerName(src),
        crimeLabels = {},
        baseMinutes = baseMinutes,
        lawyerReduction = lawyerReduction,
        firstOffenseReduction = firstOffenseReduction,
        finalMinutes = finalMinutes,
        fine = baseFine,
        hasLawyer = hasLawyer,
    }

    for _, crimeId in ipairs(case.crimes) do
        local crime = Config.Justice.Crimes[crimeId]
        if crime then verdict.crimeLabels[#verdict.crimeLabels + 1] = crime.label end
    end

    -- 记录判决
    JusticeService.SetVerdict(caseId, verdict)

    -- 通知嫌疑人 → 入狱
    if case.suspect.src and GetPlayerPing(case.suspect.src) >= 0 then
        TriggerClientEvent('justice:client:verdictReceived', case.suspect.src, verdict)
    end

    -- 通知律师
    for _, lawyer in ipairs(case.lawyers) do
        if GetPlayerPing(lawyer.src) >= 0 then
            TriggerClientEvent('QBCore:Notify', lawyer.src,
                _L(lawyer.src, 'justice_verdict_lawyer', caseId, finalMinutes, baseMinutes, lawyerReduction + firstOffenseReduction),
                'primary')
        end
    end

    -- 通知法官
    TriggerClientEvent('QBCore:Notify', src,
        _L(src, 'justice_verdict_judge', case.suspect.name, finalMinutes, baseFine),
        'success')

    -- 日志
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('审判判决',
            ('案件 %s | %s → %d分钟 (原始%d) | 法官: %s | 律师: %s'):format(
                caseId, case.suspect.name, finalMinutes, baseMinutes,
                GetPlayerName(src), hasLawyer and '是' or '否'))
    end

    -- 关闭案件
    case.status = 'closed'
end)

-- ==============================================================
-- 命令: 法官查看案件列表
-- ==============================================================
QBCore.Commands.Add('cases', '查看待审案件 (法官/律师)', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local job = Player.PlayerData.job.name
    if job ~= 'judge' and job ~= 'lawyer' then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_lawyer_judge_only'), 'error')
        return
    end

    local cases = JusticeService.GetActiveCases()
    local pendingCount = 0
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 215, 0 },
        args = { _L(source, 'justice_pending_cases'), '' }
    })

    for caseId, case in pairs(cases) do
        if case.status ~= 'closed' then
            pendingCount = pendingCount + 1
            local crimeLabels = {}
            for _, cid in ipairs(case.crimes) do
                local crime = Config.Justice.Crimes[cid]
                if crime then crimeLabels[#crimeLabels + 1] = crime.label end
            end
            TriggerClientEvent('chat:addMessage', source, {
                color = { 200, 200, 200 },
                args = { '  ', ('%s | %s | Charges: %s | Lawyer: %s'):format(
                    caseId, case.suspect.name,
                    table.concat(crimeLabels, ','),
                    #case.lawyers > 0 and _L(source, 'justice_assigned') or _L(source, 'justice_pending')) }
            })
        end
    end

    if pendingCount == 0 then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_no_pending'), 'primary')
    end
end, 'user')

print('[justice-trial] 👨‍⚖️  审判系统已加载')
