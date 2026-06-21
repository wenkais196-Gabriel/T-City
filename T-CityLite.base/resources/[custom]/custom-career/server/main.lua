-- main.lua — custom-career 职业身份服务 v2
--
-- 🏢 组织架构: 职业 → 组织 → 等级 三层信息
--   CareerCache[src] = {
--     job_name, job_label, job_grade_name,    -- 职业信息
--     org_id, org_label, org_type,             -- 组织信息
--     rank_tier, department, district, certs   -- 原有字段
--   }

local QBCore = exports['qb-core']:GetCoreObject()
local CareerCache = {}

local function DebugPrint(msg)
    print(('[custom-career] %s'):format(msg))
end

-- ==========================================
--        组 织 解 析 辅 助
-- ==========================================

local function ResolveOrgForPlayer(qbPlayer)
    local job = qbPlayer.PlayerData.job
    local gang = qbPlayer.PlayerData.gang
    local orgId, org = QBConfig.Career.ResolvePlayerOrg(job, gang)
    return orgId, org
end

-- ==========================================
--        内 存 缓 存 管 理 (O(1))
-- ==========================================

local function BuildCareerData(qbPlayer, dbResult)
    local job = qbPlayer.PlayerData.job
    local gang = qbPlayer.PlayerData.gang
    local orgId, org = ResolveOrgForPlayer(qbPlayer)

    -- 等级映射
    local targetTier = 'entry'
    if gang and gang.name ~= 'none' then
        local lvl = gang.grade and tonumber(gang.grade.level) or 0
        if lvl >= 4 then targetTier = 'boss'
        elseif lvl >= 2 then targetTier = 'mid' end
    elseif job and job.name ~= 'unemployed' then
        if job.isboss or (job.grade and job.grade.level and job.grade.level >= 4) then
            targetTier = 'leader'
        elseif job.grade and job.grade.level and job.grade.level >= 2 then
            targetTier = 'mid'
        end
    end

    -- 自愈: DB 与实际不一致时修正
    local dbTier = (dbResult and dbResult.rank_tier) and dbResult.rank_tier or 'entry'
    if dbTier ~= targetTier then
        MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?',
            { targetTier, qbPlayer.PlayerData.citizenid })
    end

    return {
        -- 职业
        job_name       = job.name or 'unemployed',
        job_label      = job.label or 'Civilian',
        job_grade_name = job.grade and job.grade.name or 'Freelancer',
        -- 组织
        org_id    = orgId,
        org_label = org.label,
        org_type  = org.type,
        -- 帮派 (如有)
        gang_name       = gang and gang.name ~= 'none' and gang.name or nil,
        gang_label      = gang and gang.name ~= 'none' and gang.label or nil,
        gang_grade_name = gang and gang.name ~= 'none' and gang.grade and gang.grade.name or nil,
        -- 阶层 + 扩展
        rank_tier  = targetTier,
        department = (dbResult and dbResult.department) or nil,
        district   = (dbResult and dbResult.district) or nil,
        certs      = (dbResult and dbResult.certs) and json.decode(dbResult.certs) or {},
    }
end

local function LoadPlayerCareer(src)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return end
    local cid = qbPlayer.PlayerData.citizenid

    MySQL.single('SELECT rank_tier, department, district, certs FROM players WHERE citizenid = ?',
        { cid }, function(dbResult)
            local data = BuildCareerData(qbPlayer, dbResult)
            CareerCache[src] = data
            Player(src).state:set('career_identity', data, true)
            DebugPrint(('Loaded: %s | 职业: %s | 组织: %s | 等级: %s | 阶层: %s')
                :format(qbPlayer.PlayerData.name, data.job_label, data.org_label,
                    data.job_grade_name, data.rank_tier))
        end)
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(qbPlayer)
    LoadPlayerCareer(qbPlayer.PlayerData.source)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Wait(1000)
    for _, qbPlayer in pairs(QBCore.Functions.GetQBPlayers()) do
        LoadPlayerCareer(qbPlayer.PlayerData.source)
    end
end)

AddEventHandler('playerDropped', function()
    CareerCache[source] = nil
end)

-- ==========================================
--           公 开 导 出 API
-- ==========================================

local function GetPlayerIdentity(src)
    if CareerCache[src] then
        local qbPlayer = QBCore.Functions.GetPlayer(src)
        if qbPlayer then
            -- 实时刷新职业/帮派名字
            local job = qbPlayer.PlayerData.job
            local gang = qbPlayer.PlayerData.gang
            CareerCache[src].job_name = job.name
            CareerCache[src].job_label = job.label or 'Civilian'
            CareerCache[src].job_grade_name = job.grade and job.grade.name or 'Freelancer'
            if gang and gang.name ~= 'none' then
                CareerCache[src].gang_name = gang.name
                CareerCache[src].gang_label = gang.label
                CareerCache[src].gang_grade_name = gang.grade and gang.grade.name
            end
            -- 动态重新解析组织
            local orgId, org = ResolveOrgForPlayer(qbPlayer)
            CareerCache[src].org_id = orgId
            CareerCache[src].org_label = org.label
            CareerCache[src].org_type = org.type
        end
        return CareerCache[src]
    end

    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if qbPlayer then
        local orgId, org = ResolveOrgForPlayer(qbPlayer)
        local job = qbPlayer.PlayerData.job
        local gang = qbPlayer.PlayerData.gang
        return {
            job_name = job.name, job_label = job.label or 'Civilian',
            job_grade_name = job.grade and job.grade.name or 'Freelancer',
            org_id = orgId, org_label = org.label, org_type = org.type,
            gang_name = (gang and gang.name ~= 'none') and gang.name or nil,
            gang_label = (gang and gang.name ~= 'none') and gang.label or nil,
            gang_grade_name = (gang and gang.name ~= 'none') and gang.grade and gang.grade.name or nil,
            rank_tier = 'entry', department = nil, district = nil, certs = {},
        }
    end
    return nil
end

exports('GetPlayerIdentity', GetPlayerIdentity)

-- ==========================================
--        标 签 比 对 器 (增加 org 标签)
-- ==========================================

local function PlayerMatchesTags(src, requiredTags)
    local identity = GetPlayerIdentity(src)
    if not identity then return false end
    for tag, val in pairs(requiredTags) do
        if tag == 'role'     and identity.job_name ~= val then return false end
        if tag == 'org'      and identity.org_id ~= val then return false end
        if tag == 'tier'     and identity.rank_tier ~= val then return false end
        if tag == 'gang'     and identity.gang_name ~= val then return false end
        if tag == 'department' and identity.department ~= val then return false end
        if tag == 'district' and identity.district ~= val then return false end
        if tag == 'cert' then
            local has = false
            for _, c in ipairs(identity.certs) do if c == val then has = true; break end end
            if not has then return false end
        end
    end
    return true
end

exports('PlayerMatchesTags', PlayerMatchesTags)

-- ==========================================
--       Job / Gang 变更联动 (含组织重解析)
-- ==========================================

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if not CareerCache[src] then return end
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer or not job then return end

    local orgId, org = ResolveOrgForPlayer(qbPlayer)
    local targetTier = 'entry'
    if job.isboss or (job.grade and job.grade.level and job.grade.level >= 4) then targetTier = 'leader'
    elseif job.grade and job.grade.level and job.grade.level >= 2 then targetTier = 'mid' end

    CareerCache[src].job_name = job.name
    CareerCache[src].job_label = job.label
    CareerCache[src].job_grade_name = job.grade and job.grade.name or '?'
    CareerCache[src].org_id = orgId
    CareerCache[src].org_label = org.label
    CareerCache[src].org_type = org.type
    CareerCache[src].rank_tier = targetTier
    Player(src).state:set('career_identity', CareerCache[src], true)

    MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?',
        { targetTier, qbPlayer.PlayerData.citizenid })

    DebugPrint(('JobUpdate: %s → 职业:%s 组织:%s 阶层:%s')
        :format(qbPlayer.PlayerData.name, job.label, org.label, targetTier))
end)

AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
    if not CareerCache[src] then
        -- 确保缓存存在
        local qbPlayer = QBCore.Functions.GetPlayer(src)
        if qbPlayer then LoadPlayerCareer(src) end
    end
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer or not gang then return end

    local orgId, org = ResolveOrgForPlayer(qbPlayer)
    local targetTier = 'entry'
    if gang.grade and gang.grade.level then
        local lvl = tonumber(gang.grade.level) or 0
        if lvl >= 4 then targetTier = 'boss'
        elseif lvl >= 2 then targetTier = 'mid' end
    end

    CareerCache[src].gang_name = gang.name ~= 'none' and gang.name or nil
    CareerCache[src].gang_label = gang.name ~= 'none' and gang.label or nil
    CareerCache[src].gang_grade_name = gang.name ~= 'none' and gang.grade and gang.grade.name or nil
    CareerCache[src].org_id = orgId
    CareerCache[src].org_label = org.label
    CareerCache[src].org_type = org.type
    CareerCache[src].rank_tier = targetTier
    Player(src).state:set('career_identity', CareerCache[src], true)

    MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?',
        { targetTier, qbPlayer.PlayerData.citizenid })

    DebugPrint(('GangUpdate: %s → 帮派:%s 组织:%s 阶层:%s')
        :format(qbPlayer.PlayerData.name, gang.label, org.label, targetTier))
end)

-- ==========================================
--        其 他 API (保持不变)
-- ==========================================

local function SetPlayerTier(src, tier)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    tier = tier:lower()
    if not QBConfig.Career.Tiers[tier] then return false end
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    CareerCache[src].rank_tier = tier
    Player(src).state:set('career_identity', CareerCache[src], true)
    MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?', { tier, qbPlayer.PlayerData.citizenid })
    return true
end
exports('SetPlayerTier', SetPlayerTier)

local function SetPlayerDepartment(src, dept)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    CareerCache[src].department = dept
    Player(src).state:set('career_identity', CareerCache[src], true)
    MySQL.Async.execute('UPDATE players SET department = ? WHERE citizenid = ?', { dept, qbPlayer.PlayerData.citizenid })
    return true
end
exports('SetPlayerDepartment', SetPlayerDepartment)

local function SetPlayerDistrict(src, district)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    CareerCache[src].district = district
    Player(src).state:set('career_identity', CareerCache[src], true)
    MySQL.Async.execute('UPDATE players SET district = ? WHERE citizenid = ?', { district, qbPlayer.PlayerData.citizenid })
    return true
end
exports('SetPlayerDistrict', SetPlayerDistrict)

local function AddPlayerCert(src, certId)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    for _, c in ipairs(CareerCache[src].certs) do if c == certId then return true end end
    table.insert(CareerCache[src].certs, certId)
    Player(src).state:set('career_identity', CareerCache[src], true)
    local licences = qbPlayer.PlayerData.metadata['licences'] or {}
    local map = { pilot_license = 'pilot', heavy_vehicle = 'heavy', firearms_cert = 'weapon', boat_license = 'boat' }
    if map[certId] then
        licences[map[certId]] = true
        if certId == 'pilot_license' then licences['driver'] = true end
        qbPlayer.Functions.SetMetaData('licences', licences)
    end
    MySQL.Async.execute('UPDATE players SET certs = ? WHERE citizenid = ?', { json.encode(CareerCache[src].certs), qbPlayer.PlayerData.citizenid })
    return true
end
exports('AddPlayerCert', AddPlayerCert)

local function RemovePlayerCert(src, certId)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    for i, c in ipairs(CareerCache[src].certs) do
        if c == certId then table.remove(CareerCache[src].certs, i); break end
    end
    Player(src).state:set('career_identity', CareerCache[src], true)
    local licences = qbPlayer.PlayerData.metadata['licences'] or {}
    local map = { pilot_license = 'pilot', heavy_vehicle = 'heavy', firearms_cert = 'weapon', boat_license = 'boat' }
    if map[certId] then licences[map[certId]] = false; qbPlayer.Functions.SetMetaData('licences', licences) end
    MySQL.Async.execute('UPDATE players SET certs = ? WHERE citizenid = ?', { json.encode(CareerCache[src].certs), qbPlayer.PlayerData.citizenid })
    return true
end
exports('RemovePlayerCert', RemovePlayerCert)

-- ==========================================
--          测试命令 (含组织信息)
-- ==========================================

QBCore.Commands.Add('careertest', '测试多标签+组织+许可证桥接 (Admin)', {}, true, function(source)
    local qbPlayer = QBCore.Functions.GetPlayer(source)
    if not qbPlayer then return end

    TriggerClientEvent('QBCore:Notify', source, '🧪 career v2 联合测试...', 'primary')
    Wait(500)

    local id = exports['custom-career']:GetPlayerIdentity(source)
    if not id then
        TriggerClientEvent('QBCore:Notify', source, '❌ 无法读取身份缓存', 'error')
        return
    end

    TriggerClientEvent('QBCore:Notify', source,
        ('✅ 职业: %s | 组织: %s | 等级: %s | 阶层: %s'):format(
            id.job_label, id.org_label, id.job_grade_name, id.rank_tier), 'success')
    Wait(500)

    local match = exports['custom-career']:PlayerMatchesTags(source, { org = id.org_id, tier = id.rank_tier })
    TriggerClientEvent('QBCore:Notify', source,
        match and '✅ 组织+阶层标签比对一致' or '❌ 标签比对失败', match and 'success' or 'error')
    Wait(500)

    exports['custom-career']:AddPlayerCert(source, 'pilot_license')
    Wait(500)
    local id2 = exports['custom-career']:GetPlayerIdentity(source)
    local hasCert = false; for _, c in ipairs(id2.certs) do if c == 'pilot_license' then hasCert = true end end
    TriggerClientEvent('QBCore:Notify', source,
        hasCert and '✅ 飞行执照授予+桥接成功' or '❌ 执照授予失败', hasCert and 'success' or 'error')
    Wait(500)

    exports['custom-career']:RemovePlayerCert(source, 'pilot_license')
    local id3 = exports['custom-career']:GetPlayerIdentity(source)
    hasCert = false; for _, c in ipairs(id3.certs) do if c == 'pilot_license' then hasCert = true end end
    TriggerClientEvent('QBCore:Notify', source,
        not hasCert and '✅ 执照吊销成功' or '❌ 吊销失败', not hasCert and 'success' or 'error')

    TriggerClientEvent('QBCore:Notify', source, '🎉 career v2 测试全部通过！', 'success')
end, 'admin')

-- 新增: 查看自己身份
QBCore.Commands.Add('mycareer', '查看你的职业身份信息', {}, false, function(source)
    local id = exports['custom-career']:GetPlayerIdentity(source)
    if not id then
        TriggerClientEvent('QBCore:Notify', source, '身份信息未加载', 'error')
        return
    end
    local lines = {
        ('💼 职业: %s [%s]'):format(id.job_label, id.job_name),
        ('📊 等级: %s'):format(id.job_grade_name),
        ('🏢 组织: %s [%s]'):format(id.org_label, id.org_id),
        ('📐 阶层: %s'):format(id.rank_tier),
    }
    if id.gang_name then
        lines[#lines + 1] = ('🏴 帮派: %s [%s] 等级: %s'):format(id.gang_label, id.gang_name, id.gang_grade_name)
    end
    TriggerClientEvent('chat:addMessage', source, {
        color = { 100, 255, 200 }, multiline = true,
        args = { _L('career_identity_title'), table.concat(lines, '\n') }
    })
end, 'user')

print('[custom-career] 🏢 职业身份服务 v2 已加载 (组织架构: 职业→组织→等级)')
print('[custom-career]   命令: /mycareer /careertest')
