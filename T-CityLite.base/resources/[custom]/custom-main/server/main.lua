local QBCore = exports['qb-core']:GetCoreObject()

-- 辅助调试打印
local function DebugPrint(msg)
    if QBConfig.Custom.General.EnableDebug then
        print(('[custom-main][server] %s'):format(msg))
    end
end

-- ==========================================
--               资 源 启 动 事 件
-- ==========================================

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    DebugPrint('T-City Lite v0.3 custom-main server initialized successfully.')
    exports['custom-logs']:LogGeneric("服务器核心就绪", "模块化核心 `custom-main` 资源及 v0.3 经济与安全拦截层加载完成。", 65280) -- 绿色
end)

-- ==========================================
--               玩 家 登 录 桥 接
-- ==========================================

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData and Player.PlayerData.source
    if not src then return end

    -- 若未启用医疗系统，预先清除死亡元数据，防止上线卡在死亡/到底状态
    if GetResourceState('qb-ambulancejob') ~= 'started' then
        if Player.PlayerData.metadata['isdead'] or Player.PlayerData.metadata['inlaststand'] then
            Player.Functions.SetMetaData('isdead', false)
            Player.Functions.SetMetaData('inlaststand', false)
            DebugPrint(('Pre-emptively cleared death metadata for %s due to qb-ambulancejob disabled'):format(Player.PlayerData.citizenid))
        end
    end

    local name = GetPlayerName(src) or "unknown"
    local citizenid = Player.PlayerData.citizenid or "unknown"
    local cash = Player.Functions.GetMoney('cash') or 0
    local bank = Player.Functions.GetMoney('bank') or 0

    DebugPrint(('PlayerLoaded: %s (%s)'):format(citizenid, name))

    -- 接入新 logs 模块记录精美的登录日志，同时附带资产审计信息
    local text = ("**玩家名**: %s\n**CitizenID**: %s\n**物理ID (Source)**: %d\n**初始资金**: 现金 $%d | 银行 $%d"):format(
        name, citizenid, src, cash, bank
    )
    exports['custom-logs']:LogGeneric("玩家上线通知", text, 65280) -- 绿色
end)

-- 统一的状态重置事件（用于医疗职业停用时的生命状态同步）
-- 安全约束: 仅在服务端判定玩家确实死亡/倒地且医疗资源未启用时允许重置，每名玩家 10 秒冷却
local ResetDeathCooldowns = {}
local RESET_DEATH_COOLDOWN_MS = 10000

RegisterNetEvent('custom-main:server:ResetDeathStatus', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local now = GetGameTimer()
    local lastReset = ResetDeathCooldowns[src]
    if lastReset and (now - lastReset) < RESET_DEATH_COOLDOWN_MS then return end

    local metadata = Player.PlayerData.metadata or {}
    if not metadata['isdead'] and not metadata['inlaststand'] then
        -- 无死亡/倒地状态可清，忽略重复的客户端同步请求（不占用冷却）
        return
    end

    ResetDeathCooldowns[src] = now

    -- 医疗资源运行期间不存在合法的客户端重置场景，直接拦截并审计
    if GetResourceState('qb-ambulancejob') == 'started' then
        exports['custom-logs']:LogSecurity('拦截非法死亡状态重置', ('**玩家**: %s\n**CitizenID**: %s\n**物理ID**: %d\n**isdead**: %s | **inlaststand**: %s\n**说明**: 医疗资源运行中，客户端无权清除死亡/倒地状态。'):format(
            GetPlayerName(src) or 'unknown', Player.PlayerData.citizenid or 'unknown', src,
            tostring(metadata['isdead']), tostring(metadata['inlaststand'])), 16711680) -- 红色
        return
    end

    Player.Functions.SetMetaData('isdead', false)
    Player.Functions.SetMetaData('inlaststand', false)
    DebugPrint(('ResetDeathStatus accepted for citizenid: %s'):format(Player.PlayerData.citizenid))
end)

AddEventHandler('playerDropped', function()
    ResetDeathCooldowns[source] = nil
end)

-- ==========================================
--               玩 家 登 出 桥 接
-- ==========================================

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local name = GetPlayerName(src) or "unknown"
    local citizenid = Player.PlayerData.citizenid or "unknown"
    local cash = Player.Functions.GetMoney('cash') or 0
    local bank = Player.Functions.GetMoney('bank') or 0

    DebugPrint(('PlayerUnload: %s (%s)'):format(citizenid, name))

    -- 接入新 logs 模块记录离线通知与离线资产审计
    local text = ("**玩家名**: %s\n**CitizenID**: %s\n**离线前资金**: 现金 $%d | 银行 $%d"):format(
        name, citizenid, cash, bank
    )
    exports['custom-logs']:LogGeneric("玩家离线通知", text, 16711680) -- 红色
end)

-- ==========================================
--               职 业 更 新 桥 接
-- ==========================================

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    local Player = QBCore.Functions.GetPlayer(src)
    local name = Player and GetPlayerName(src) or "unknown"
    local citizenid = Player and Player.PlayerData.citizenid or "unknown"

    DebugPrint(('JobUpdate: Player=%s, Job=%s, Grade=%s'):format(
        name,
        job and job.name or 'nil',
        job and job.grade and job.grade.level or 'nil'
    ))

    local text = ("**玩家名**: %s (%s)\n**新职业**: %s (%s)\n**等级**: %d (是否主管: %s)"):format(
        name, citizenid, 
        job and job.label or "nil", job and job.name or "nil",
        job and job.grade and job.grade.level or 0, 
        tostring(job and job.isboss or false)
    )
    exports['custom-logs']:LogGeneric("职业变动审计", text, 10079487) -- 淡蓝紫
end)

-- ==========================================
--        Legacy Backward Compatibility Exports
-- ==========================================

exports('LogEconomy', function(title, msg, col)
    exports['custom-logs']:LogEconomy(title, msg, col)
end)

exports('LogSecurity', function(title, msg, col)
    exports['custom-logs']:LogSecurity(title, msg, col)
end)

exports('LogGeneric', function(title, msg, col)
    exports['custom-logs']:LogGeneric(title, msg, col)
end)
