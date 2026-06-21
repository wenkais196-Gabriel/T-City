-- arrest.lua — 逮捕处理 + 律师通知
--
-- 流程: 警察逮捕 → 登记案件 → 通知律师 → 律师接案(可选)

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 事件: 警察注册逮捕 (从 qb-policejob 调用)
-- ==============================================================

RegisterNetEvent('justice:server:registerArrest', function(suspectSrc, crimes, officerSrc)
    local src = officerSrc or source

    -- 1. 权限校验: 必须是警察
    local Officer = QBCore.Functions.GetPlayer(src)
    if not Officer or Officer.PlayerData.job.name ~= 'police' then return end

    -- 2. 嫌疑人校验
    local Suspect = QBCore.Functions.GetPlayer(suspectSrc)
    if not Suspect then return end

    -- 3. 罪名校验
    if not crimes or type(crimes) ~= 'table' or #crimes == 0 then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_no_charge'), 'error')
        return
    end

    -- 验证罪名合法性
    local validCrimes = {}
    for _, crimeId in ipairs(crimes) do
        if Config.Justice.Crimes[crimeId] then
            table.insert(validCrimes, crimeId)
        end
    end
    if #validCrimes == 0 then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_invalid_charge'), 'error')
        return
    end

    -- 4. 创建案件
    local caseId = JusticeService.CreateCase(suspectSrc, src, validCrimes)
    local case = JusticeService.GetCase(caseId)
    if not case then return end

    -- 5. 通知嫌疑人
    local crimeLabels = {}
    local totalMin = 0
    for _, cid in ipairs(validCrimes) do
        local crime = Config.Justice.Crimes[cid]
        crimeLabels[#crimeLabels + 1] = crime.label
        totalMin = totalMin + crime.baseMinutes
    end

    TriggerClientEvent('QBCore:Notify', suspectSrc,
        _L(suspectSrc, 'justice_arrested', table.concat(crimeLabels, ', '), totalMin),
        'error', 10000)

    -- 6. 通知在线律师
    local lawyerSources = {}
    if Bus and Bus.JobService then
        lawyerSources = Bus.JobService.GetOnlinePlayersByJob('lawyer')
    end

    local lawyerNotified = false
    if #lawyerSources >= Config.Justice.Lawyer.minOnlineForAssignment then
        for _, lawyerSrc in ipairs(lawyerSources) do
            TriggerClientEvent('justice:client:lawyerNotify', lawyerSrc, {
                caseId = caseId,
                suspectName = case.suspect.name,
                crimes = crimeLabels,
                baseMinutes = totalMin,
            })
            lawyerNotified = true
        end
    end

    -- 7. 通知警察
    TriggerClientEvent('QBCore:Notify', src,
        _L(src, 'justice_case_registered', caseId, case.suspect.name,
            lawyerNotified and _L(src, 'justice_lawyer_notified') or _L(src, 'justice_no_lawyer_online')
        ), 'primary')

    -- 日志
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('逮捕登记', ('案件 %s | 嫌疑人: %s | 罪名: %s | 警察: %s | 律师通知: %s'):format(
            caseId, case.suspect.name, table.concat(crimeLabels, ','),
            GetPlayerName(src), lawyerNotified and '是' or '否'))
    end
end)

-- ==============================================================
-- 事件: 律师接受案件
-- ==============================================================

RegisterNetEvent('justice:server:lawyerAcceptCase', function(caseId)
    local src = source
    local Lawyer = QBCore.Functions.GetPlayer(src)
    if not Lawyer or Lawyer.PlayerData.job.name ~= 'lawyer' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_lawyer_only'), 'error')
        return
    end

    local case = JusticeService.GetCase(caseId)
    if not case then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_case_not_found'), 'error')
        return
    end

    if case.status ~= 'pending' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_case_taken'), 'error')
        return
    end

    JusticeService.AssignLawyer(caseId, src)

    -- 通知嫌疑人
    if case.suspect.src and GetPlayerPing(case.suspect.src) >= 0 then
        TriggerClientEvent('QBCore:Notify', case.suspect.src,
            _L(case.suspect.src, 'justice_lawyer_assigned', GetPlayerName(src)),
            'success')
    end

    -- 通知其他律师案件已受理
    local allLawyers = {}
    if Bus and Bus.JobService then allLawyers = Bus.JobService.GetOnlinePlayersByJob('lawyer') end
    for _, ls in ipairs(allLawyers) do
        if ls ~= src then
            TriggerClientEvent('QBCore:Notify', ls,
                _L(ls, 'justice_case_taken_by', caseId, GetPlayerName(src)), 'primary')
        end
    end

    TriggerClientEvent('QBCore:Notify', src, _L(src, 'justice_case_accepted', caseId, case.suspect.name), 'success')
end)

-- ==============================================================
-- 命令: 警察快速登记
-- ==============================================================
QBCore.Commands.Add('arrest', '逮捕并登记案件 (警察)', {{name='id', help='嫌疑人ID'}, {name='crimes', help='罪名(逗号分隔)'}}, false, function(source, args)
    local suspectId = tonumber(args[1])
    local crimeStr = args[2] or 'assault'

    if not suspectId then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_arrest_usage'), 'error')
        return
    end

    local crimes = {}
    for c in crimeStr:gmatch('[^,]+') do
        crimes[#crimes + 1] = c:trim()
    end

    TriggerEvent('justice:server:registerArrest', suspectId, crimes, source)
end, 'user')

print('[justice-arrest] 🚔 逮捕处理已加载')
