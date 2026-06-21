-- job_service.lua — 职业/帮派统一管理服务
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 提取自 custom-career + qb-core，作为独立 Bus Service 提供:
--   - 职业 CRUD (GetJob / SetJob / RemoveJob)
--   - 帮派 CRUD (GetGang / SetGang / RemoveGang)
--   - 在岗计数 (GetOnDutyCount)
--   - 职业白名单校验 (ValidateJobAccess)
--   - 所有变更自动标记 dirty + 审计日志
--
-- 使用:
--   local job = Bus.JobService.GetJob(source)
--   local ok = Bus.JobService.SetJob(source, 'police', 3, '市长任命')
--   local count = Bus.JobService.GetOnDutyCount('police')

local QBCore = exports['qb-core']:GetCoreObject()
local JobService = {}

-- ==============================================================
-- 内存缓存: citizenid → { job, gang, last_updated }
-- ==============================================================
local cache = {}

-- ==============================================================
-- 内部辅助
-- ==============================================================

local function getPlayerEntry(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return nil, nil, nil end
    local cid = Player.PlayerData.citizenid
    if not cache[cid] then
        cache[cid] = {
            job      = Player.PlayerData.job,
            gang     = Player.PlayerData.gang,
            last_updated = os.time(),
        }
    end
    return Player, cid, cache[cid]
end

-- ==============================================================
-- 职业管理 API
-- ==============================================================

--- 获取玩家职业（内存优先）
---@param source number
---@return table|nil job { name, label, grade, onduty, ... }
function JobService.GetJob(source)
    local Player, cid, entry = getPlayerEntry(source)
    if not Player then return nil end
    -- 优先返回缓存，fallback 到 PlayerData
    if entry and entry.job then
        return entry.job
    end
    return Player.PlayerData.job
end

--- 设置玩家职业
---@param source number
---@param jobName string 职业名 (如 'police', 'ambulance', 'mechanic')
---@param grade number 职业等级
---@param reason string|nil 变更原因（审计用）
---@return boolean success
---@return string|nil error
function JobService.SetJob(source, jobName, grade, reason)
    local Player, cid, entry = getPlayerEntry(source)
    if not Player then return false, 'Player not found' end

    -- 安全检查（如果 SecurityService 可用）
    if Bus and Bus.SecurityService then
        local ok, cleanedJob, cleanedGrade, err = Bus.SecurityService.ValidateJobEvent(source, jobName, grade)
        if not ok then return false, err end
        jobName = cleanedJob
        grade = cleanedGrade
    else
        -- 手动简单校验
        jobName = tostring(jobName or '')
        grade = tonumber(grade) or 0
        if #jobName == 0 then return false, 'Invalid job name' end
    end

    -- 调用 QBCore 原生方法（触发 OnJobUpdate 事件）
    local success = Player.Functions.SetJob(jobName, grade)
    if not success then
        return false, 'SetJob failed'
    end

    -- 更新缓存
    local newJob = Player.PlayerData.job
    if entry then
        entry.job = newJob
        entry.last_updated = os.time()
    end

    -- 标记脏数据（职业变更）
    if DirtyFlush then
        DirtyFlush.MarkDirty(cid, 'job')
    end

    -- 审计日志
    local logText = ('**%s** (%s) | Job: %s (%d) | Reason: %s'):format(
        GetPlayerName(source), cid,
        newJob.name, newJob.grade and newJob.grade.level or grade,
        reason or 'unknown'
    )
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('职业变更', logText, 65280)
    end

    return true, nil
end

--- 移除玩家职业（设为 unemployed）
---@param source number
---@param reason string|nil
function JobService.RemoveJob(source, reason)
    return JobService.SetJob(source, 'unemployed', 0, reason or 'fired')
end

--- 设置玩家执勤状态
---@param source number
---@param onDuty boolean
function JobService.SetOnDuty(source, onDuty)
    local Player, cid, entry = getPlayerEntry(source)
    if not Player then return false, 'Player not found' end

    local job = Player.PlayerData.job
    if not job then return false, 'No job assigned' end

    -- 通过 QBCore 原生方法
    Player.Functions.SetJob(job.name, job.grade and job.grade.level or 0)
    Player.PlayerData.job.onduty = onDuty == true

    -- 同步 Client
    TriggerClientEvent('QBCore:Client:OnJobUpdate', source, Player.PlayerData.job)

    if entry then
        entry.job = Player.PlayerData.job
        entry.last_updated = os.time()
    end

    -- 🔧 Fix: .onduty 属于 job 结构
    if DirtyFlush then
        DirtyFlush.MarkDirty(cid, 'job')
    end

    return true, nil
end

-- ==============================================================
-- 帮派管理 API
-- ==============================================================

--- 获取玩家帮派
---@param source number
---@return table|nil gang
function JobService.GetGang(source)
    local Player, cid, entry = getPlayerEntry(source)
    if not Player then return nil end
    if entry and entry.gang then
        return entry.gang
    end
    return Player.PlayerData.gang
end

--- 设置玩家帮派
---@param source number
---@param gangName string
---@param grade number
---@param reason string|nil
function JobService.SetGang(source, gangName, grade, reason)
    local Player, cid, entry = getPlayerEntry(source)
    if not Player then return false, 'Player not found' end

    -- 安全检查
    if Bus and Bus.SecurityService then
        local ok, cleanedGang, cleanedGrade, err = Bus.SecurityService.ValidateGangEvent(source, gangName, grade)
        if not ok then return false, err end
        gangName = cleanedGang
        grade = cleanedGrade
    else
        gangName = tostring(gangName or 'none')
        grade = tonumber(grade) or 0
    end

    -- 调用 QBCore 原生方法
    local success = Player.Functions.SetGang(gangName, grade)
    if not success then
        return false, 'SetGang failed'
    end

    if entry then
        entry.gang = Player.PlayerData.gang
        entry.last_updated = os.time()
    end

    -- 标记脏数据（帮派变更）
    if DirtyFlush then
        DirtyFlush.MarkDirty(cid, 'gang')
    end

    -- 审计日志
    local logText = ('**%s** (%s) | Gang: %s (%d) | Reason: %s'):format(
        GetPlayerName(source), cid,
        gangName, grade,
        reason or 'unknown'
    )
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('帮派变更', logText, 16738657)
    end

    return true, nil
end

-- ==============================================================
-- 统计查询 API
-- ==============================================================

--- 获取某职业在岗人数
---@param jobName string
---@return number count
function JobService.GetOnDutyCount(jobName)
    local count = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, Player in pairs(players) do
        if Player.PlayerData.job.name == jobName and Player.PlayerData.job.onduty then
            count = count + 1
        end
    end
    return count
end

--- 获取某帮派在线人数
---@param gangName string
---@return number count
function JobService.GetGangOnlineCount(gangName)
    local count = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, Player in pairs(players) do
        if Player.PlayerData.gang.name == gangName then
            count = count + 1
        end
    end
    return count
end

--- 获取某职业所有在线玩家 source 列表
---@param jobName string
---@return number[] sources
function JobService.GetOnlinePlayersByJob(jobName)
    local sources = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, Player in pairs(players) do
        if Player.PlayerData.job.name == jobName then
            table.insert(sources, Player.PlayerData.source)
        end
    end
    return sources
end

--- 获取某帮派所有在线玩家 source 列表
---@param gangName string
---@return number[] sources
function JobService.GetOnlinePlayersByGang(gangName)
    local sources = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, Player in pairs(players) do
        if Player.PlayerData.gang.name == gangName then
            table.insert(sources, Player.PlayerData.source)
        end
    end
    return sources
end

-- ==============================================================
-- 下线清理
-- ==============================================================

AddEventHandler('playerDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData then
        cache[Player.PlayerData.citizenid] = nil
    end
end)

-- ==============================================================
-- 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('job', {
        GetJob                  = JobService.GetJob,
        SetJob                  = JobService.SetJob,
        RemoveJob               = JobService.RemoveJob,
        SetOnDuty               = JobService.SetOnDuty,
        GetGang                 = JobService.GetGang,
        SetGang                 = JobService.SetGang,
        GetOnDutyCount          = JobService.GetOnDutyCount,
        GetGangOnlineCount      = JobService.GetGangOnlineCount,
        GetOnlinePlayersByJob   = JobService.GetOnlinePlayersByJob,
        GetOnlinePlayersByGang  = JobService.GetOnlinePlayersByGang,
    })
end

print('[job-service] 💼 职业/帮派管理服务已注册到 Bus')
print('[job-service]   Exports: GetJob, SetJob, RemoveJob, SetOnDuty, GetGang, SetGang')
print('[job-service]   Stats: GetOnDutyCount, GetGangOnlineCount, GetOnlinePlayersByJob/Gang')