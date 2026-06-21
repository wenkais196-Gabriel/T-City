-- quest_logistics_validators.lua — 物流货运任务自定义校验器
--
-- 为 quest_logistics.lua 中的 3 个货运任务提供步骤级校验逻辑:
--   1. validate_logistics_vehicle — 自有车绑定 / 3次机会 / 失败自动取消
--   2. validate_delivery_arrival  — 送达地点 + 绑定车辆校验
--   3. validate_rental_cleanup     — 租用车回收 / 押金退还
--
-- 依赖: qb-vehiclekeys (现有) 或 custom-vehicles (新版)
--        qb-garages / player_vehicles 表

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 内部状态: 玩家物流任务绑定追踪
-- ==============================================================

---@class LogisticsBinding
---@field plate string         车牌号
---@field netId number         车辆网络 ID
---@field model string         车辆模型名
---@field isRental boolean     是否为租用车辆
---@field rentalDeposit number 租车押金
---@field rentalFeePct number  租车抽成比例 (0-100)

-- citizenid → questId → LogisticsBinding
local PlayerBindings = {}

-- v0.7.2: 验证尝试计数 — citizenid → questId → attempts
local ValidationAttempts = {}
local MAX_VALIDATION_ATTEMPTS = 3

-- ==============================================================
-- 辅助: 验证失败处理（累加次数，满3次自动取消任务）
-- ==============================================================

local function recordValidationFailure(citizenid, questId, src)
    if not ValidationAttempts[citizenid] then
        ValidationAttempts[citizenid] = {}
    end
    local attempts = (ValidationAttempts[citizenid][questId] or 0) + 1
    ValidationAttempts[citizenid][questId] = attempts

    local remaining = MAX_VALIDATION_ATTEMPTS - attempts
    if remaining <= 0 then
        -- 3次失败 → 自动取消任务
        ValidationAttempts[citizenid][questId] = nil
        TriggerClientEvent('QBCore:Notify', src,
            '❌ 验证失败 3 次，任务已自动取消', 'error')
        QuestManager.FailQuest(src, questId, 'validation_exhausted')
    end
    return attempts, remaining
end

local function clearValidationAttempts(citizenid, questId)
    if ValidationAttempts[citizenid] then
        ValidationAttempts[citizenid][questId] = nil
    end
end

--- 获取或创建玩家绑定
local function getBinding(citizenid, questId)
    if not PlayerBindings[citizenid] then
        PlayerBindings[citizenid] = {}
    end
    return PlayerBindings[citizenid][questId]
end

local function setBinding(citizenid, questId, binding)
    if not PlayerBindings[citizenid] then
        PlayerBindings[citizenid] = {}
    end
    PlayerBindings[citizenid][questId] = binding
end

local function clearBinding(citizenid, questId)
    if PlayerBindings[citizenid] then
        PlayerBindings[citizenid][questId] = nil
    end
end

-- ==============================================================
-- 辅助函数: 安全获取玩家当前车辆信息
-- ==============================================================

--- 获取玩家当前驾驶的车辆信息
--- v0.7.2: 使用客户端传来的 vehicleNetId（GetVehiclePedIsIn 服务端不可用）
---@param src number
---@param vehicleNetId number|nil 客户端上传的车辆网络ID
---@return table|nil { plate, netId, model, class }
local function getPlayerVehicle(src, vehicleNetId)
    local veh = nil
    if vehicleNetId then
        veh = NetworkGetEntityFromNetworkId(vehicleNetId)
    end
    if not veh or veh == 0 then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            veh = GetVehiclePedIsIn(ped, false)
        end
    end
    if not veh or veh == 0 then return nil end

    local plate = 'UNKNOWN'
    if GetVehicleNumberPlateText then
        plate = tostring(GetVehicleNumberPlateText(veh)):gsub('^%s+', ''):gsub('%s+$', '')
    end

    local netId = 0
    if NetworkGetNetworkIdFromEntity then
        netId = NetworkGetNetworkIdFromEntity(veh) or 0
    end

    local model = 0
    if GetEntityModel then
        model = GetEntityModel(veh) or 0
    end

    local vehClass = 0
    if GetVehicleClass then
        vehClass = GetVehicleClass(veh) or 0
    end

    return { plate = plate, netId = netId, model = model, class = vehClass }
end

--- 检查玩家是否拥有指定车牌的载具（优先内存 KeyManager，回退 DB）
local function playerOwnsVehicle(citizenid, plate)
    if KeyManager and KeyManager.GetOwner then
        local owner = KeyManager.GetOwner(plate)
        if owner == citizenid then return true end
    end
    if not MySQL then return false end
    local owned = false
    local p = promise.new()
    MySQL.query('SELECT plate FROM player_vehicles WHERE citizenid = ? AND plate = ?', {
        citizenid, plate
    }, function(result)
        owned = result and #result > 0
        p:resolve(owned)
    end)
    Citizen.Await(p)
    return owned
end

-- ==============================================================
-- 校验器 1: validate_logistics_vehicle (含3次机会)
-- ==============================================================

local function validate_logistics_vehicle(src, stepData, questData)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, 'Player not found' end

    local citizenid = Player.PlayerData.citizenid
    local questId = questData.questId

    -- 1. 检查玩家是否在车内
    local vehicleNetId = questData.vehicleNetId
    local vehInfo = getPlayerVehicle(src, vehicleNetId)
    if not vehInfo then
        local attempts, remaining = recordValidationFailure(citizenid, questId, src)
        if remaining >= 0 then
            return false, ('你必须坐进一辆载具中（剩余 %d/%d 次）'):format(remaining, MAX_VALIDATION_ATTEMPTS)
        end
        return false, '验证机会已用完'
    end

    -- 2. 检查载具类别
    local allowedClasses = stepData.allowed_classes or {}
    if #allowedClasses > 0 and vehInfo.class > 0 then
        local classOk = false
        for _, c in ipairs(allowedClasses) do
            if vehInfo.class == c then classOk = true; break end
        end
        if not classOk then
            local attempts, remaining = recordValidationFailure(citizenid, questId, src)
            if remaining >= 0 then
                return false, ('载具类型不符（剩余 %d/%d 次）'):format(remaining, MAX_VALIDATION_ATTEMPTS)
            end
            return false, '验证机会已用完'
        end
    end

    -- 3. 验证通过 → 清除尝试计数 + 记录绑定
    clearValidationAttempts(citizenid, questId)
    local isOwned = playerOwnsVehicle(citizenid, vehInfo.plate)
    local rentalFeePct = stepData.rental_fee_percent or 20

    setBinding(citizenid, questId, {
        plate    = vehInfo.plate,
        netId    = vehInfo.netId,
        model    = vehInfo.model,
        isRental = not isOwned,
        rentalDeposit = 0,
        rentalFeePct  = isOwned and 0 or rentalFeePct,
    })

    TriggerClientEvent('vehiclekeys:client:SetOwner', src, vehInfo.plate)

    if isOwned then
        return true, ('✅ 已绑定私家车 [%s] — 享受 100%% 收益'):format(vehInfo.plate)
    else
        return true, ('📋 已登记运输载具 [%s] — 收益抽成 %d%%'):format(vehInfo.plate, rentalFeePct)
    end
end

-- ==============================================================
-- 校验器 2: validate_delivery_arrival
-- ==============================================================

local function validate_delivery_arrival(src, stepData, questData)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, 'Player not found' end

    local citizenid = Player.PlayerData.citizenid
    local questId = questData.questId

    local binding = getBinding(citizenid, questId)
    print(('[logistics-validator] DELIVERY: citizenid=%s, quest=%s, binding=%s'):format(
        citizenid, questId, binding and ('plate='..binding.plate) or 'nil'))
    if not binding then
        return false, '没有绑定的载具，请先完成车辆验证步骤'
    end

    if stepData.use_bound_vehicle then
        local vehicleNetId = questData.vehicleNetId
        print(('[logistics-validator] DELIVERY: vehicleNetId=%s'):format(tostring(vehicleNetId)))
        local vehInfo = getPlayerVehicle(src, vehicleNetId)
        if not vehInfo then
            return false, '你必须坐在绑定的载具中'
        end
        print(('[logistics-validator] DELIVERY: current plate=%s, bound plate=%s'):format(vehInfo.plate, binding.plate))
        if vehInfo.plate ~= binding.plate then
            return false, ('载具不匹配！必须使用 [%s]'):format(binding.plate)
        end
    end

    if stepData.require_trailer then
        local vehicleNetId = questData.vehicleNetId
        local vehInfo = getPlayerVehicle(src, vehicleNetId)
        if vehInfo then
            local ped = GetPlayerPed(src)
            local veh = GetVehiclePedIsIn(ped, false)
            local trailer = GetVehicleTrailerVehicle(veh)
            if not trailer or trailer == 0 then
                return false, '拖车斗丢失！请重新挂接挂车后再交付'
            end
        end
    end

    if stepData.destCoords then
        local ped = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(ped)
        local dest = vector3(stepData.destCoords.x, stepData.destCoords.y, stepData.destCoords.z)
        local dist = #(playerCoords - dest)
        local radius = stepData.radius or 10.0
        if dist > radius then
            return false, ('距离卸货点还有 %.0f 米（需要 %.0f 米以内）'):format(dist, radius)
        end
    end

    return true, '已到达卸货点'
end

-- ==============================================================
-- 校验器 3: validate_rental_cleanup
-- ==============================================================

local function validate_rental_cleanup(src, stepData, questData)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, 'Player not found' end

    local citizenid = Player.PlayerData.citizenid
    local questId = questData.questId

    local binding = getBinding(citizenid, questId)
    if not binding then return true, '自有载具无需归还' end
    if not binding.isRental then
        clearBinding(citizenid, questId)
        return true, '私家车已释放'
    end

    if stepData.returnCoords then
        local ped = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(ped)
        local ret = vector3(stepData.returnCoords.x, stepData.returnCoords.y, stepData.returnCoords.z)
        local radius = stepData.radius or 10.0
        local dist = #(playerCoords - ret)
        if dist > radius then
            return false, ('距离还车点还有 %.0f 米'):format(dist)
        end
    end

    if binding.netId then
        local veh = NetworkGetEntityFromNetworkId(binding.netId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            SetVehicleDoorsLocked(veh, 0)
            SetVehicleEngineOn(veh, false, true, true)
            SetVehicleHasBeenOwnedByPlayer(veh, false)
            local returnPlate = binding.plate
            SetTimeout(600000, function()
                if DoesEntityExist(veh) then
                    local occupied = false
                    for _, pId in ipairs(GetPlayers()) do
                        local pPed = GetPlayerPed(tonumber(pId))
                        if pPed and IsPedInVehicle(pPed, veh, false) then occupied = true; break end
                    end
                    if not occupied then DeleteEntity(veh) end
                end
            end)
        end
    end

    clearBinding(citizenid, questId)
    return true, '租用车已归还'
end

-- ==============================================================
-- 导出
-- ==============================================================

function GetLogisticsBinding(citizenid, questId)
    return getBinding(citizenid, questId)
end

function ClearLogisticsBinding(citizenid, questId)
    clearBinding(citizenid, questId)
    clearValidationAttempts(citizenid, questId)
end

-- ==============================================================
-- 注册
-- ==============================================================

if QuestValidators then
    QuestValidators.Register('validate_logistics_vehicle', validate_logistics_vehicle)
    QuestValidators.Register('validate_delivery_arrival', validate_delivery_arrival)
    QuestValidators.Register('validate_rental_cleanup', validate_rental_cleanup)
end

-- ==============================================================
-- 任务完成: 清理绑定 + 城市KPI
-- ==============================================================

local logisticsProgressMap = {
    euro_trucking_steel = { category = 'infrastructure', points = 5 },
    euro_trucking_heavy_trailer = { category = 'infrastructure', points = 12 },
    aviation_medical_airlift = { category = 'healthcare', points = 8 },
}

AddEventHandler('quest:server:onQuestCompleted', function(citizenid, questId)
    -- v0.10: 租用载具仅记录、不影响任务结算之外的逻辑
    -- 租赁费抽成在 QuestRewards.GrantRewards 中通过 binding.rentalFeePct 自动扣除
    -- 载具归还是玩家自己的事，quest 系统不干预
    clearBinding(citizenid, questId)
    clearValidationAttempts(citizenid, questId)
    TriggerEvent('quest:server:cleanupTrailers', citizenid)  -- v0.10: trailer cleanup
    local progress = logisticsProgressMap[questId]
    if progress then
        TriggerEvent('city:server:addProgress', progress.category, progress.points)
    end
end)

-- ==============================================================
-- v0.7.2: 任务失败 → 赔付基础收益的 50%
-- ==============================================================

AddEventHandler('quest:server:onQuestFailed', function(citizenid, questId, reason)
    local binding = getBinding(citizenid, questId)
    if binding and binding.isRental and binding.netId then
        local veh = NetworkGetEntityFromNetworkId(binding.netId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then DeleteEntity(veh) end
    end
    clearBinding(citizenid, questId)
    clearValidationAttempts(citizenid, questId)
    TriggerEvent('quest:server:cleanupTrailers', citizenid)  -- v0.9: trailer cleanup

    -- 失败赔付: 扣除基础收益的 50%
    local template = QuestRegistry.GetTemplate(questId)
    if template and template.rewards and template.rewards.money then
        local baseAvg = math.floor(((template.rewards.money.min or 0) + (template.rewards.money.max or 0)) / 2)
        local penalty = math.floor(baseAvg * 0.5)
        if penalty > 0 then
            local src = nil
            for _, pId in ipairs(GetPlayers()) do
                local Player = QBCore.Functions.GetPlayer(tonumber(pId))
                if Player and Player.PlayerData.citizenid == citizenid then
                    src = tonumber(pId)
                    break
                end
            end
            if src then
                local Player = QBCore.Functions.GetPlayer(src)
                if Player then
                    local accountType = template.rewards.money.type or 'bank'
                    Player.Functions.RemoveMoney(accountType, penalty, ('quest_fail:%s'):format(questId))
                    TriggerClientEvent('QBCore:Notify', src,
                        ('💸 任务失败，扣除基础收益 50%% (-$%d)'):format(penalty), 'error')
                end
            end
        end
    end
end)

-- ==============================================================
-- v0.8a: 货物损伤追踪 — 接收客户端损伤回传
-- ==============================================================

---@class CargoDamageRecord
---@field questId string
---@field collisionCount number
---@field damagePct number
---@field bodyHealthDelta number
---@field engineHealthDelta number

-- citizenid → questId → CargoDamageRecord
local CargoDamageRecords = {}

RegisterNetEvent('quest:server:cargoDamageResult', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    if not CargoDamageRecords[citizenid] then
        CargoDamageRecords[citizenid] = {}
    end
    CargoDamageRecords[citizenid][data.questId] = {
        questId = data.questId,
        collisionCount = data.collisionCount or 0,
        damagePct = data.damagePct or 0,
        bodyHealthDelta = data.bodyHealthDelta or 0,
        engineHealthDelta = data.engineHealthDelta or 0,
    }

    print(('[logistics-damage] 📦 %s | 任务: %s | 碰撞: %d 次 | 损伤: %d%%'):format(
        citizenid, data.questId, data.collisionCount, data.damagePct))
end)

-- ==============================================================
-- v0.8a: 时效追踪 — 记录任务开始时间 + 计算时效奖惩
-- ==============================================================

-- citizenid → questId → { startTime (os.time), timeLimitMin, earlyBonusPct, latePenaltyPct }
local TimeTrackers = {}

--- 当物流任务开始时记录时间（由 quest:server:onQuestCompleted 事件触发时已太晚）
--- 改为在 quest:server:onQuestStarted 或步骤推进时记录
---@param citizenid string
---@param questId string
---@param logisticsExt table|nil 来自 quest 模板的 logistics_ext
function TrackQuestStartTime(citizenid, questId, logisticsExt)
    if not logisticsExt or not logisticsExt.time_limit_min then return end

    if not TimeTrackers[citizenid] then
        TimeTrackers[citizenid] = {}
    end
    TimeTrackers[citizenid][questId] = {
        startTime = os.time(),
        timeLimitMin = logisticsExt.time_limit_min or 15,
        earlyBonusPct = logisticsExt.early_bonus_pct or 20,
        latePenaltyPct = logisticsExt.late_penalty_pct or 10,
    }
end

--- 计算时效奖励倍率（由奖励分发器调用）
---@param citizenid string
---@param questId string
---@return number timeMultiplier (1.0 = 基准, >1.0 = 提前奖励, <1.0 = 超时罚款)
---@return string|nil timeNote
function CalculateTimeBonus(citizenid, questId)
    if not TimeTrackers[citizenid] or not TimeTrackers[citizenid][questId] then
        return 1.0, nil
    end

    local tracker = TimeTrackers[citizenid][questId]
    local elapsedSec = os.time() - tracker.startTime
    local elapsedMin = elapsedSec / 60
    local limitMin = tracker.timeLimitMin

    if elapsedMin <= limitMin * 0.5 then
        -- 提前 50%+ 完成 → 额外奖励
        local bonus = 1.0 + (tracker.earlyBonusPct / 100)
        TimeTrackers[citizenid][questId] = nil  -- 清理
        return bonus, ('⏱ 极速送达！提前 %.0f 分钟 (+%d%%)'):format(limitMin - elapsedMin, tracker.earlyBonusPct)
    elseif elapsedMin <= limitMin then
        -- 按时完成
        TimeTrackers[citizenid][questId] = nil
        return 1.0, ('⏱ 准时送达 (%.0f/%.0f 分钟)'):format(elapsedMin, limitMin)
    else
        -- 超时 → 罚款
        local overMin = elapsedMin - limitMin
        local penaltySteps = math.floor(overMin / (limitMin * 0.1)) + 1
        local penaltyPct = math.min(50, penaltySteps * tracker.latePenaltyPct)
        local multiplier = 1.0 - (penaltyPct / 100)
        TimeTrackers[citizenid][questId] = nil
        return multiplier, ('⏱ 超时 %.0f 分钟！扣除 %d%%'):format(overMin, penaltyPct)
    end
end

--- 获取货物损伤扣减倍率（由奖励分发器调用）
---@param citizenid string
---@param questId string
---@return number damageMultiplier (1.0 = 无损, <1.0 = 有损)
---@return string|nil damageNote
function CalculateCargoDamagePenalty(citizenid, questId)
    if not CargoDamageRecords[citizenid] or not CargoDamageRecords[citizenid][questId] then
        return 1.0, nil
    end

    local record = CargoDamageRecords[citizenid][questId]
    CargoDamageRecords[citizenid][questId] = nil  -- 清理

    if record.damagePct <= 0 then
        return 1.0, '📦 货物完好无损'
    end

    local penaltyPct = math.min(record.damagePct, 50)  -- 封顶 50%
    local multiplier = 1.0 - (penaltyPct / 100)
    local note = ('📦 货物损伤 %d%% (%d 次碰撞) — 扣除 %d%%'):format(
        record.damagePct, record.collisionCount, penaltyPct)
    return multiplier, note
end

-- ==============================================================
-- v0.8a: 校验器 — validate_fuel_departure（出发前燃料检查）
-- ==============================================================

local function validate_fuel_departure(src, stepData, questData)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, 'Player not found' end

    local minFuel = stepData.min_fuel_percent or 25  -- 默认要求 ≥ 25% 油量
    local ped = GetPlayerPed(src)
    local veh = GetVehiclePedIsIn(ped, false)

    if not veh or veh == 0 then
        return false, '你必须坐在载具中'
    end

    -- 通过 qb-fuel export 获取油量
    local fuelLevel = nil
    if exports['qb-fuel'] then
        local ok, result = pcall(function()
            return exports['qb-fuel']:GetFuel(veh)
        end)
        if ok then fuelLevel = result end
    end

    -- Fallback: 通过原生 FiveM 装饰器读取
    if not fuelLevel then
        fuelLevel = Entity(veh).state.fuel or GetVehicleFuelLevel(veh)
    end

    if type(fuelLevel) ~= 'number' then fuelLevel = 100 end

    -- fuelLevel 通常为 0–100 百分比
    if fuelLevel < minFuel then
        return false, ('⛽ 燃料不足！当前 %.0f%%，需要 ≥ %d%%'):format(fuelLevel, minFuel)
    end

    return true, ('⛽ 燃料充足 (%.0f%%)'):format(fuelLevel)
end

-- ==============================================================
-- v0.8a: 注册新校验器
-- ==============================================================

if QuestValidators then
    QuestValidators.Register('validate_fuel_departure', validate_fuel_departure)
end

-- ==============================================================
-- v0.8a: 物流任务开始时自动启动时效追踪 + 货物损伤监控
-- ==============================================================

AddEventHandler('quest:server:onStepCompleted', function(citizenid, questId, stepId, nextStepId)
    local template = QuestRegistry.GetTemplate(questId)
    if not template or not template.logistics_ext then return end

    local ext = template.logistics_ext

    -- 第一步完成 = 开始运输，启动时效追踪
    if ext.time_limit_min then
        TrackQuestStartTime(citizenid, questId, ext)
    end

    -- 查找玩家 src（多处复用）
    local function findSrc()
        for _, pId in ipairs(GetPlayers()) do
            local Player = QBCore.Functions.GetPlayer(tonumber(pId))
            if Player and Player.PlayerData.citizenid == citizenid then
                return tonumber(pId)
            end
        end
        return nil
    end

    -- 激活客户端运输 HUD（有时限时）
    if ext.time_limit_min then
        local src = findSrc()
        if src then
            TriggerClientEvent('quest:client:transportHudActivate', src, {
                questId = questId,
                timeLimitMin = ext.time_limit_min,
            })
        end
    end

    -- 激活客户端疲劳追踪
    local src = findSrc()
    if src then
        TriggerClientEvent('quest:client:fatigueActivate', src)
    end

    -- 如果是脆弱货物，激活客户端损伤监控
    if ext.cargo_fragile then
        local binding = getBinding(citizenid, questId)
        if binding then
            if src then
                TriggerClientEvent('quest:client:cargoDamageStart', src, {
                    questId = questId,
                    plate = binding.plate,
                    maxPenaltyPct = ext.damage_max_penalty_pct or 30,
                })
            end
        end
    end
end)

-- v0.8a: 任务完成时停止客户端损伤监控 + 清理时效追踪
AddEventHandler('quest:server:onQuestCompleted', function(citizenid, questId)
    -- 停止客户端模块
    local src = nil
    for _, pId in ipairs(GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(tonumber(pId))
        if Player and Player.PlayerData.citizenid == citizenid then
            src = tonumber(pId)
            break
        end
    end
    if src then
        TriggerClientEvent('quest:client:cargoDamageStop', src)
        TriggerClientEvent('quest:client:transportHudDeactivate', src)
        TriggerClientEvent('quest:client:fatigueDeactivate', src)
        TriggerClientEvent('quest:client:entityTrackStop', src)  -- v0.9
    end

    -- 清理
    clearBinding(citizenid, questId)
    clearValidationAttempts(citizenid, questId)
    TriggerEvent('quest:server:cleanupTrailers', citizenid)  -- v0.10: trailer cleanup
    if TimeTrackers[citizenid] then
        TimeTrackers[citizenid][questId] = nil
    end
    if CargoDamageRecords[citizenid] then
        CargoDamageRecords[citizenid][questId] = nil
    end
end)

-- v0.8a: onQuestFailed 仅处理 cargo/time 清理，罚款逻辑由原处理器负责
AddEventHandler('quest:server:onQuestFailed', function(citizenid, questId, reason)
    -- 停止客户端模块
    local src = nil
    for _, pId in ipairs(GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(tonumber(pId))
        if Player and Player.PlayerData.citizenid == citizenid then
            src = tonumber(pId)
            break
        end
    end
    if src then
        TriggerClientEvent('quest:client:cargoDamageStop', src)
        TriggerClientEvent('quest:client:transportHudDeactivate', src)
        TriggerClientEvent('quest:client:fatigueDeactivate', src)
        TriggerClientEvent('quest:client:entityTrackStop', src)  -- v0.9
    end

    -- 清理时效追踪 + 损伤记录（罚款/车辆清理由原 AddEventHandler 处理）
    TriggerEvent('quest:server:cleanupTrailers', citizenid)  -- v0.9: trailer cleanup
    if TimeTrackers[citizenid] then
        TimeTrackers[citizenid][questId] = nil
    end
    if CargoDamageRecords[citizenid] then
        CargoDamageRecords[citizenid][questId] = nil
    end
end)

print('[quest-logistics-validators] ✅ 5 个物流校验器已注册 (v0.9: +trailer_cleanup +fuel_departure +damage_tracking +time_bonus)')