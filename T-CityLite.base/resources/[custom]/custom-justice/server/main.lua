-- main.lua — custom-justice 司法系统主入口 + Bus 注册

local QBCore = exports['qb-core']:GetCoreObject()
JusticeService = {}

-- 案件追踪: caseId → { suspect, officers, lawyers, judge, crimes[], verdict, status }
local activeCases = {}
local caseCounter = 0

-- 囚犯追踪: citizenid → { sentenceMinutes, startTime, crimes[], reductions[] }
local inmates = {}
JusticeService.Inmates = inmates

-- ==============================================================
-- 案件管理
-- ==============================================================

function JusticeService.CreateCase(suspectSrc, officerSrc, crimes)
    caseCounter = caseCounter + 1
    local caseId = ('CASE-%04d'):format(caseCounter)

    local suspectPlayer = QBCore.Functions.GetPlayer(suspectSrc)
    local suspectName = suspectPlayer and GetPlayerName(suspectSrc) or 'Unknown'

    activeCases[caseId] = {
        id = caseId,
        suspect = { src = suspectSrc, name = suspectName, citizenid = suspectPlayer and suspectPlayer.PlayerData.citizenid },
        officers = { { src = officerSrc, name = GetPlayerName(officerSrc) } },
        lawyers = {},
        judge = nil,
        crimes = crimes or {},
        verdict = nil,
        status = 'pending',  -- pending → assigned_lawyer → trial → sentenced → closed
        createdAt = os.time(),
    }

    -- 同时让 owner 记一条正式案卷（police_cases），并记住两套 id 的映射。
    -- 没有映射的话，判决只能落在报告上；而报告不一定存在，案卷维度就永远查不到判决。
    local officerSource = tonumber(officerSrc) or 0
    if officerSource > 0 and GetResourceState('custom-police') == 'started' then
        local ok, created = pcall(function()
            return exports['custom-police']:CreateCase(officerSource, {
                title = ('逮捕登记 · %s'):format(caseId),
                summary = ('司法案卷 %s（嫌疑人 %s）'):format(caseId,
                    tostring(activeCases[caseId].suspect.citizenid or 'unknown')),
            })
        end)
        if ok and type(created) == 'table' and created.id then
            activeCases[caseId].police_case_id = tonumber(created.id)
        else
            print(('[custom-justice] police case not created for %s (%s)'):format(
                caseId, tostring(created)))
        end
    end

    return caseId
end

function JusticeService.GetCase(caseId) return activeCases[caseId] end
function JusticeService.GetActiveCases() return activeCases end

function JusticeService.AssignLawyer(caseId, lawyerSrc)
    local c = activeCases[caseId]
    if not c then return false end
    local Lawyer = QBCore.Functions.GetPlayer(lawyerSrc)
    if not Lawyer then return false end
    table.insert(c.lawyers, { src = lawyerSrc, name = GetPlayerName(lawyerSrc) })
    c.status = 'assigned_lawyer'
    return true
end

function JusticeService.SetVerdict(caseId, verdict, minutes)
    local c = activeCases[caseId]
    if not c then return false end
    c.verdict = verdict
    c.status = 'sentenced'
    c.court_status = tostring(verdict)
    -- 案卷维度也要记住判决（v3.11 的 court_status / sentence_minutes）。
    if c.police_case_id and GetResourceState('custom-police') == 'started' then
        local ok, result = pcall(function()
            return exports['custom-police']:RecordCaseVerdict(c.police_case_id, tostring(verdict), minutes)
        end)
        if not ok or type(result) ~= 'table' or not result.ok then
            print(('[custom-justice] case verdict not written for %s (%s)'):format(
                tostring(caseId), tostring(result)))
        end
    end
    return true
end

--- 为在线嫌疑人开一个司法案件（警察逮捕提交的 open_case 联动）。
--- 只创建内存案件，不写 police_cases；失败统一返回 false。
---@param citizenid string
---@param officerSrc number
---@param crimes string[]
---@return string|false caseId
function JusticeService.OpenCase(citizenid, officerSrc, crimes)
    citizenid = tostring(citizenid or '')
    if #citizenid == 0 or #citizenid > 50 then return false end
    if type(crimes) ~= 'table' or #crimes < 1 then return false end

    local Suspect = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if not Suspect then return false end

    local Officer = QBCore.Functions.GetPlayer(tonumber(officerSrc) or 0)
    if not Officer then return false end
    local officerJob = Officer.PlayerData.job and Officer.PlayerData.job.name
    if officerJob ~= 'police' and officerJob ~= 'judge' then return false end

    -- Only hand known charge ids to the case; unknown entries would produce a
    -- 0-minute case.
    local validCrimes = {}
    for _, crimeId in ipairs(crimes) do
        if Config.Justice.Crimes[crimeId] then
            validCrimes[#validCrimes + 1] = crimeId
        end
    end
    if #validCrimes < 1 then return false end

    local caseId = JusticeService.CreateCase(
        Suspect.PlayerData.source, Officer.PlayerData.source, validCrimes)
    return caseId or false
end

-- ==============================================================
-- 囚犯管理
-- ==============================================================

function JusticeService.GetInmates() return inmates end

function JusticeService.GetInmate(citizenid) return inmates[citizenid] end

--- Close the durable sentence first, then clear the runtime cache and push the
--- online player out. `Release` is idempotent, so a repeated call (or a sweep
--- that already expired the row) only clears the projection.
function JusticeService.ReleaseInmate(citizenid, reason, status)
    citizenid = tostring(citizenid or '')
    if #citizenid == 0 or #citizenid > 50 then return false end

    local released = false
    if JusticeSentences then
        local ok, result = pcall(JusticeSentences.Release, citizenid, reason, status)
        released = ok and result == true
    end

    local inmate = inmates[citizenid]
    if not inmate and not released then return false end
    inmates[citizenid] = nil

    -- 找在线玩家传送出狱
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Player then
        local src = Player.PlayerData.source
        Player.Functions.SetMetaData('injail', 0)
        local qbPrison = inmate and inmate.qbPrison
        if qbPrison == nil then
            qbPrison = GetResourceState('qb-prison') == 'started'
        end
        if qbPrison then
            TriggerClientEvent('prison:client:UnjailPerson', src)
        else
            TriggerClientEvent('justice:client:released', src)
        end
    end
    return true
end

-- ==============================================================
-- 获取在线职业人数
-- ==============================================================

function JusticeService.GetOnlineJobCount(jobName)
    if GetResourceState('core-framework') == 'started' then
        local ok, count = pcall(function()
            return exports['core-framework']:service_job_GetOnDutyCount(jobName)
        end)
        if ok then return count end
    end
    return QBCore.Functions.GetDutyCount(jobName)
end

-- ==============================================================
-- Bus 注册
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('justice', {
        CreateCase = JusticeService.CreateCase,
        GetCase = JusticeService.GetCase,
        GetActiveCases = JusticeService.GetActiveCases,
        AssignLawyer = JusticeService.AssignLawyer,
        SetVerdict = JusticeService.SetVerdict,
        OpenCase = JusticeService.OpenCase,
        GetInmates = JusticeService.GetInmates,
        GetInmate = JusticeService.GetInmate,
        ReleaseInmate = JusticeService.ReleaseInmate,
        GetOnlineJobCount = JusticeService.GetOnlineJobCount,
    })
end

-- ==============================================================
-- 定期清理已结案件 (每小时)
-- ==============================================================
CreateThread(function()
    while true do
        Wait(3600 * 1000)
        local now = os.time()
        for caseId, c in pairs(activeCases) do
            if c.status == 'closed' and now - c.createdAt > 7200 then
                activeCases[caseId] = nil
            end
        end
    end
end)

-- ==============================================================
-- 离线/重连囚犯恢复
-- ==============================================================
-- 恢复由 prison.lua 的 QBCore:Server:PlayerLoaded 统一处理：那里读取
-- justice_sentences 的权威剩余时间，写 metadata.injail 并在需要时触发
-- prison:client:Enter。此处不再注册第二个 handler，避免双计时/双入场。

-- 🔧 司法部门管理指令
QBCore.Commands.Add('setjusticedept', '分配司法人员部门', { { name = 'id', help = 'Player ID' }, { name = 'dept', help = 'court / defense' } }, true, function(source, args)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local targetId = tonumber(args[1])
	local dept = args[2] and args[2]:lower()
	if not Player or (Player.PlayerData.job.name ~= 'judge' and Player.PlayerData.job.grade.level < 4) then
		TriggerClientEvent('QBCore:Notify', src, '仅法官或 Boss 可分配司法部门', 'error')
		return
	end
	local validDepts = { court = '法院', defense = '辩护律师' }
	if not validDepts[dept] then
		TriggerClientEvent('QBCore:Notify', src, '无效部门: court / defense', 'error')
		return
	end
	local Target = QBCore.Functions.GetPlayer(targetId)
	if not Target then TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error'); return end
	local success = exports['custom-career']:SetPlayerDepartment(targetId, dept)
	if success then
		TriggerClientEvent('QBCore:Notify', src, ('已将 %s 分配至 %s'):format(Target.PlayerData.charinfo.firstname, validDepts[dept]), 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('你已被分配至 %s'):format(validDepts[dept]), 'success')
	else
		TriggerClientEvent('QBCore:Notify', src, '操作失败', 'error')
	end
end)

print('[custom-justice] ⚖️  司法服务已注册到 Bus')

exports('Imprison', function(citizenid, minutes, crimes, opts)
    return JusticeService.Imprison(citizenid, minutes, crimes, opts)
end)

exports('OpenCase', function(citizenid, officerSrc, crimes)
    return JusticeService.OpenCase(citizenid, officerSrc, crimes)
end)
