-- main.lua — custom-cartel 主入口
--
-- 职责:
--   1. 注册 Bus.CartelService
--   2. 玩家上线/下线时同步 cartel 状态
--   3. 管理命令 (/cartellab, /cartelstorage 等)
--   4. 协调 drug_lab + npc_manager 子系统

local QBCore = exports['qb-core']:GetCoreObject()
CartelService = {}

-- ==============================================================
-- 内部状态
-- ==============================================================

-- 生产冷却追踪: citizenid → last_production_time
local productionCooldowns = {}

-- 在线 cartel 成员缓存: citizenid → { source, name, grade }
local cartelMembers = {}

-- ==============================================================
-- 玩家生命周期
-- ==============================================================

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local gang = Player.PlayerData.gang

    if gang and gang.name == 'cartel' then
        local cid = Player.PlayerData.citizenid
        cartelMembers[cid] = {
            source = src,
            name = GetPlayerName(src),
            grade = gang.grade and gang.grade.level or 0,
            gradeName = gang.grade and gang.grade.name or 'Unknown',
        }
        print(('[cartel] 🏴 成员上线: %s (等级 %d — %s)'):format(
            GetPlayerName(src), cartelMembers[cid].grade, cartelMembers[cid].gradeName
        ))
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local cid = Player.PlayerData.citizenid
    if cartelMembers[cid] then
        cartelMembers[cid] = nil
    end
    productionCooldowns[cid] = nil
end)

-- ==============================================================
-- 公共 API
-- ==============================================================

--- 获取在线 cartel 成员列表
---@return table[] { citizenid, source, name, grade, gradeName }
function CartelService.GetOnlineMembers()
    local list = {}
    for cid, member in pairs(cartelMembers) do
        table.insert(list, {
            citizenid = cid,
            source = member.source,
            name = member.name,
            grade = member.grade,
            gradeName = member.gradeName,
        })
    end
    return list
end

--- 获取在线 cartel 成员数量
---@return number
function CartelService.GetOnlineCount()
    local count = 0
    for _ in pairs(cartelMembers) do count = count + 1 end
    return count
end

--- 检查玩家是否是 cartel 成员
---@param source number
---@return boolean, number|nil grade
function CartelService.IsMember(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end
    local gang = Player.PlayerData.gang
    if gang and gang.name == 'cartel' then
        return true, gang.grade and gang.grade.level or 0
    end
    return false
end

--- 检查生产冷却
---@param citizenid string
---@return boolean canProduce  -- true = 可以生产
---@return number remainingSec  -- 剩余冷却秒数
function CartelService.CheckProductionCooldown(citizenid)
    local now = os.time()
    local last = productionCooldowns[citizenid] or 0
    local cooldown = Config.Cartel.Security.productionCooldown
    local elapsed = now - last

    if elapsed >= cooldown then
        return true, 0
    end
    return false, cooldown - elapsed
end

--- 设置生产冷却
---@param citizenid string
function CartelService.SetProductionCooldown(citizenid)
    productionCooldowns[citizenid] = os.time()
end

--- 打开 cartel 组织仓库
---@param source number
function CartelService.OpenStorage(source)
    if Bus and Bus.StorageService then
        Bus.StorageService.OpenOrgStorage(source, 'cartel')
    else
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'cartel_storage_down'), 'error')
    end
end

--- 检查 raid 条件
---@return boolean shouldRaid
---@return number policeCount
function CartelService.CheckRaidConditions()
    local policeOnline = 0
    if Bus and Bus.JobService then
        policeOnline = Bus.JobService.GetOnDutyCount('police')
    else
        policeOnline = QBCore.Functions.GetDutyCount('police')
    end

    local minPolice = Config.Cartel.Security.minPoliceForRaid
    if policeOnline < minPolice then
        return false, policeOnline
    end

    -- 概率判定
    local roll = math.random()
    local chance = Config.Cartel.Security.raidChancePerHour
    return roll < chance, policeOnline
end

-- ==============================================================
-- 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('cartel', {
        GetOnlineMembers        = CartelService.GetOnlineMembers,
        GetOnlineCount          = CartelService.GetOnlineCount,
        IsMember                = CartelService.IsMember,
        CheckProductionCooldown = CartelService.CheckProductionCooldown,
        SetProductionCooldown   = CartelService.SetProductionCooldown,
        OpenStorage             = CartelService.OpenStorage,
        CheckRaidConditions     = CartelService.CheckRaidConditions,
    })
end

-- ==============================================================
-- 命令
-- ==============================================================

-- /cartellab — 打开毒品实验室（需要靠近实验室位置）
QBCore.Commands.Add('cartellab', '打开 Cartel 毒品实验室', {}, false, function(source)
    local isMember, _ = CartelService.IsMember(source)
    if not isMember then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'cartel_not_member'), 'error')
        return
    end

    -- 检查距离（客户端负责验证并打开UI）
    TriggerClientEvent('cartel:client:openLab', source)
end, 'user')

-- /cartelstorage — 打开组织仓库
QBCore.Commands.Add('cartelstorage', '打开 Cartel 组织仓库', {}, false, function(source)
    local isMember, _ = CartelService.IsMember(source)
    if not isMember then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'cartel_not_member'), 'error')
        return
    end
    CartelService.OpenStorage(source)
end, 'user')

-- /cartelmembers — 查看在线成员
QBCore.Commands.Add('cartelmembers', '查看 Cartel 在线成员', {}, false, function(source)
    local members = CartelService.GetOnlineMembers()
    local count = #members

    if count == 0 then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'cartel_no_members_online'), 'primary')
        return
    end

    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 100, 0 },
        args = { 'Cartel 在线成员', ('共 %d 人'):format(count) }
    })

    for _, m in ipairs(members) do
        local gradeColor = { 200, 200, 200 }
        if m.grade >= 4 then gradeColor = { 255, 50, 50 }       -- El Jefe 红色
        elseif m.grade >= 2 then gradeColor = { 255, 150, 50 } end -- Jefe 橙色

        TriggerClientEvent('chat:addMessage', source, {
            color = gradeColor,
            args = { '  ', ('[等级%d] %s — %s'):format(m.grade, m.gradeName, m.name) }
        })
    end
end, 'user')

-- /cartelinfo — 管理员查看 cartel 全局状态
QBCore.Commands.Add('cartelinfo', '查看 Cartel 全局状态 (管理员)', {}, true, function(source)
    local members = CartelService.GetOnlineMembers()
    local canRaid, policeCount = CartelService.CheckRaidConditions()

    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 215, 0 },
        multiline = true,
        args = { 'Cartel 状态', ('在线成员: %d | 警察: %d | Raid风险: %s'):format(
            #members, policeCount, canRaid and '⚠️ 高' or '✅ 低'
        ) }
    })
end, 'admin')

print('[custom-cartel] 🏴 Cartel 核心服务已注册到 Bus')
print('[custom-cartel]   Exports: GetOnlineMembers, IsMember, CheckProductionCooldown, OpenStorage')
print('[custom-cartel]   命令: /cartellab /cartelstorage /cartelmembers /cartelinfo')
