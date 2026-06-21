-- main.lua — custom-justice 司法系统主入口 + Bus 注册

local QBCore = exports['qb-core']:GetCoreObject()
JusticeService = {}

-- 案件追踪: caseId → { suspect, officers, lawyers, judge, crimes[], verdict, status }
local activeCases = {}
local caseCounter = 0

-- 囚犯追踪: citizenid → { sentenceMinutes, startTime, crimes[], reductions[] }
local inmates = {}

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

function JusticeService.SetVerdict(caseId, verdict)
    local c = activeCases[caseId]
    if not c then return false end
    c.verdict = verdict
    c.status = 'sentenced'
    return true
end

-- ==============================================================
-- 囚犯管理
-- ==============================================================

function JusticeService.GetInmates() return inmates end

function JusticeService.GetInmate(citizenid) return inmates[citizenid] end

function JusticeService.ReleaseInmate(citizenid)
    local inmate = inmates[citizenid]
    if not inmate then return false end
    inmates[citizenid] = nil

    -- 找在线玩家传送出狱
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Player then
        local src = Player.PlayerData.source
        TriggerClientEvent('justice:client:released', src)
    end
    return true
end

-- ==============================================================
-- 获取在线职业人数
-- ==============================================================

function JusticeService.GetOnlineJobCount(jobName)
    if Bus and Bus.JobService then
        return Bus.JobService.GetOnDutyCount(jobName)
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
-- 离线囚犯计时恢复
-- ==============================================================
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local cid = Player.PlayerData.citizenid
    local inmate = inmates[cid]
    if inmate then
        local src = Player.PlayerData.source
        -- 通知客户端进入监狱模式
        TriggerClientEvent('justice:client:enterPrison', src, {
            sentenceMinutes = inmate.sentenceMinutes,
            startTime = inmate.startTime,
            crimes = inmate.crimes,
            reductions = inmate.reductions,
        })
    end
end)

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
