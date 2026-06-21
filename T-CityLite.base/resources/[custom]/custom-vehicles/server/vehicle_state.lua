-- vehicle_state.lua — custom-vehicles 车辆状态统一管理 (v0.9)
--
-- 职责:
--   1. 里程/引擎损耗/磨损部件/氮气/TunerChip 状态缓存
--   2. 导出 exports + Bus 注册 (统一查询/修改入口)
--   3. 持久化到 player_vehicles (status, drivingdistance, mods)
--   4. 向后兼容: 桥接 qb-mechanicjob 旧事件 & callback
--
-- 设计原则: 模块化·高性能·安全·可拓展

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 状态缓存 (plate → data)
-- ==============================================================

local vehicleComponents = {}  -- [plate] = { radiator=100, axle=100, ... }
local drivingDistance  = {}  -- [plate] = total_distance_in_meters
local tunedVehicles    = {}  -- [plate] = true/false
local nitrousVehicles  = {}  -- [plate] = { hasnitro=bool, level=number }

-- 部件定义 (默认值，可由 Convar 或外部 config 覆盖)
local DefaultWearableParts = {
    radiator = { maxValue = 100 },
    axle     = { maxValue = 100 },
    brakes   = { maxValue = 100 },
    clutch   = { maxValue = 100 },
    fuel     = { maxValue = 100 },
}

-- ==============================================================
-- 工具函数
-- ==============================================================

local function Trim(s)
    if not s then return nil end
    return (s:gsub('^%s*(.-)%s*$', '%1'))
end

local function IsVehicleOwned(plate)
    if not plate then return false end
    local result = MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE plate = ?', { plate })
    return result and true or false
end

--- 初始化车辆部件状态（首次记录时）
local function InitComponents(plate)
    if vehicleComponents[plate] then return end
    vehicleComponents[plate] = {}
    for part, data in pairs(DefaultWearableParts) do
        vehicleComponents[plate][part] = data.maxValue
    end
end

-- ==============================================================
-- Public API (exports)
-- ==============================================================

--- 获取车辆完整状态快照
---@param plate string
---@return table|nil { components, distance, tuned, nitrous }
local function GetVehicleState(plate)
    if not plate then return nil end
    plate = Trim(plate)
    return {
        components = vehicleComponents[plate],
        distance   = drivingDistance[plate] or 0,
        tuned      = tunedVehicles[plate] or false,
        nitrous    = nitrousVehicles[plate] or { hasnitro = false, level = 0 },
    }
end

--- 更新单个磨损部件值
---@param plate string
---@param component string
---@param value number
local function UpdateComponent(plate, component, value)
    if not plate or not component then return end
    plate = Trim(plate)
    InitComponents(plate)
    vehicleComponents[plate][component] = math.max(0, math.min(value, DefaultWearableParts[component] and DefaultWearableParts[component].maxValue or 100))

    -- 持久化: 仅对已入库车辆写盘
    if IsVehicleOwned(plate) then
        MySQL.update('UPDATE player_vehicles SET status = ? WHERE plate = ?', {
            json.encode(vehicleComponents[plate]), plate
        })
    end
end

--- 重置所有磨损部件（修理后调用）
---@param plate string
local function ResetComponents(plate)
    if not plate then return end
    plate = Trim(plate)
    InitComponents(plate)
    for part in pairs(DefaultWearableParts) do
        vehicleComponents[plate][part] = DefaultWearableParts[part].maxValue
    end

    if IsVehicleOwned(plate) then
        MySQL.update('UPDATE player_vehicles SET status = ? WHERE plate = ?', {
            json.encode(vehicleComponents[plate]), plate
        })
    end
end

--- 设置氮气状态
---@param plate string
---@param hasnitro boolean
---@param level number|nil
local function SetNitrous(plate, hasnitro, level)
    if not plate then return end
    plate = Trim(plate)
    if not nitrousVehicles[plate] then
        nitrousVehicles[plate] = { hasnitro = hasnitro, level = level or 100 }
    else
        nitrousVehicles[plate].hasnitro = hasnitro
        if level then nitrousVehicles[plate].level = level end
    end
end

--- 获取氮气状态
---@param plate string
---@return table|nil
local function GetNitrous(plate)
    if not plate then return nil end
    plate = Trim(plate)
    return nitrousVehicles[plate]
end

--- 设置 Tuner Chip 状态
---@param plate string
---@param status boolean
local function SetTuned(plate, status)
    if not plate then return end
    plate = Trim(plate)
    tunedVehicles[plate] = status
end

--- 检查是否已调校
---@param plate string
---@return boolean
local function CheckTune(plate)
    if not plate then return false end
    plate = Trim(plate)
    return tunedVehicles[plate] or false
end

--- 累加里程
---@param plate string
---@param distance number
local function AddDistance(plate, distance)
    if not plate or not distance then return end
    plate = Trim(plate)
    if drivingDistance[plate] then
        drivingDistance[plate] = drivingDistance[plate] + distance
    else
        drivingDistance[plate] = distance
    end

    if IsVehicleOwned(plate) then
        MySQL.update('UPDATE player_vehicles SET drivingdistance = drivingdistance + ? WHERE plate = ?', {
            distance, plate
        })
    end
end

--- 保存车辆改装数据
---@param vehicleProps table { plate, mods, ... }
local function SaveMods(vehicleProps)
    if not vehicleProps or not vehicleProps.plate then return end
    local plate = Trim(vehicleProps.plate)
    if IsVehicleOwned(plate) then
        MySQL.update('UPDATE player_vehicles SET mods = ? WHERE plate = ?', {
            json.encode(vehicleProps), plate
        })
    end
end

-- ==============================================================
-- 网络事件: 客户端 → 服务端同步
-- ==============================================================

--- 里程更新 (客户端下车/换车时触发)
RegisterNetEvent('custom-vehicles:server:updateDistance', function(plate, distance)
    if not plate or not distance then return end
    AddDistance(plate, distance)
end)

--- 部件状态批量同步
RegisterNetEvent('custom-vehicles:server:updateComponents', function(plate, componentData)
    if not plate or not componentData then return end
    plate = Trim(plate)
    if vehicleComponents[plate] then
        -- 合并而非覆盖：只更新客户端传回的脏字段
        for k, v in pairs(componentData) do
            if type(v) == 'number' then
                vehicleComponents[plate][k] = math.max(0, v)
            end
        end
    else
        vehicleComponents[plate] = componentData
    end

    if IsVehicleOwned(plate) then
        MySQL.update('UPDATE player_vehicles SET status = ? WHERE plate = ?', {
            json.encode(vehicleComponents[plate]), plate
        })
    end
end)

--- 氮气同步
RegisterNetEvent('custom-vehicles:server:syncNitrous', function(plate, hasnitro, level)
    SetNitrous(plate, hasnitro, level)
end)

--- Tuner Chip 同步
RegisterNetEvent('custom-vehicles:server:tuneStatus', function(plate)
    SetTuned(plate, true)
end)

--- 保存车辆改装 (外部资源如 qb-garages 调用)
RegisterNetEvent('custom-vehicles:server:SaveVehicleProps', function(vehicleProps)
    SaveMods(vehicleProps)
end)

--- 氮气火焰广播 (客户端 → 全服广播)
RegisterNetEvent('custom-vehicles:server:syncNitrousFlames', function(netId, toggle)
    TriggerClientEvent('custom-vehicles:client:syncNitrousFlames', -1, netId, toggle)
end)

-- 兼容旧事件名
RegisterNetEvent('qb-mechanicjob:server:syncNitrousFlames', function(netId, toggle)
    TriggerClientEvent('custom-vehicles:client:syncNitrousFlames', -1, netId, toggle)
end)

-- ==============================================================
-- Callbacks
-- ==============================================================

QBCore.Functions.CreateCallback('custom-vehicles:server:getVehicleState', function(_, cb, plate)
    if not plate then cb(nil); return end
    cb(GetVehicleState(plate))
end)

QBCore.Functions.CreateCallback('custom-vehicles:server:getNitrousVehicles', function(_, cb)
    cb(nitrousVehicles)
end)

QBCore.Functions.CreateCallback('custom-vehicles:server:checkTune', function(_, cb, plate)
    cb(CheckTune(plate))
end)

-- ==============================================================
-- 向后兼容: qb-mechanicjob 旧事件桥接
-- ==============================================================

RegisterNetEvent('qb-mechanicjob:server:updateDrivingDistance', function(plate, distance)
    AddDistance(plate, distance)
end)

RegisterNetEvent('qb-mechanicjob:server:updateVehicleComponents', function(plate, componentData)
    if not plate or not componentData then return end
    plate = Trim(plate)
    if vehicleComponents[plate] then
        vehicleComponents[plate] = componentData
    else
        vehicleComponents[plate] = componentData
    end
    if IsVehicleOwned(plate) then
        MySQL.update('UPDATE player_vehicles SET status = ? WHERE plate = ?', {
            json.encode(vehicleComponents[plate]), plate
        })
    end
end)

RegisterNetEvent('qb-mechanicjob:server:repairVehicleComponent', function(plate, component)
    UpdateComponent(plate, component, 100)
end)

RegisterNetEvent('qb-mechanicjob:server:syncNitrous', function(plate, hasnitro, level)
    SetNitrous(plate, hasnitro, level)
end)

RegisterNetEvent('qb-mechanicjob:server:tuneStatus', function(plate)
    SetTuned(plate, true)
end)

RegisterNetEvent('qb-mechanicjob:server:SaveVehicleProps', function(vehicleProps)
    SaveMods(vehicleProps)
end)

QBCore.Functions.CreateCallback('qb-mechanicjob:server:getnitrousVehicles', function(_, cb)
    cb(nitrousVehicles)
end)

QBCore.Functions.CreateCallback('qb-mechanicjob:server:checkTune', function(_, cb, plate)
    cb(CheckTune(plate))
end)

QBCore.Functions.CreateCallback('qb-mechanicjob:server:getVehicleStatus', function(_, cb, plate)
    if not plate then cb(false); return end
    plate = Trim(plate)
    if not vehicleComponents[plate] then cb(false); return end
    cb(vehicleComponents[plate])
end)

QBCore.Functions.CreateCallback('qb-mechanicjob:server:hasPermission', function(source, cb)
    if QBCore.Functions.HasPermission(source, { 'god', 'admin', 'command' }) then
        cb(true)
    else
        cb(false)
    end
end)

-- ==============================================================
-- Exports 注册
-- ==============================================================

exports('GetVehicleState', GetVehicleState)
exports('UpdateVehicleComponent', UpdateComponent)
exports('ResetVehicleComponents', ResetComponents)
exports('SetVehicleNitrous', SetNitrous)
exports('GetVehicleNitrous', GetNitrous)
exports('SetVehicleTuned', SetTuned)
exports('CheckVehicleTune', CheckTune)
exports('AddVehicleDistance', AddDistance)
exports('SaveVehicleMods', SaveMods)

-- ==============================================================
-- Bus 注册 (扩展已有的 vehicles 服务)
-- ==============================================================

-- 注: Bus.RegisterService('vehicles', ...) 已在 main.lua 注册了钥匙方法
-- 这里通过补丁方式追加车辆状态方法到 Bus.vehicles
if Bus and Bus._services and Bus._services['vehicles'] then
    local vehBus = Bus._services['vehicles']
    vehBus.GetState          = GetVehicleState
    vehBus.UpdateComponent   = UpdateComponent
    vehBus.ResetComponents   = ResetComponents
    vehBus.SetNitrous        = SetNitrous
    vehBus.GetNitrous        = GetNitrous
    vehBus.SetTuned          = SetTuned
    vehBus.CheckTune         = CheckTune
    vehBus.AddDistance       = AddDistance
    vehBus.SaveMods          = SaveMods

    Bus.vehicles.GetState        = GetVehicleState
    Bus.vehicles.UpdateComponent = UpdateComponent
    Bus.vehicles.ResetComponents = ResetComponents
    Bus.vehicles.SetNitrous      = SetNitrous
    Bus.vehicles.GetNitrous      = GetNitrous
    Bus.vehicles.SetTuned        = SetTuned
    Bus.vehicles.CheckTune       = CheckTune
    Bus.vehicles.AddDistance     = AddDistance
    Bus.vehicles.SaveMods        = SaveMods

    -- 注册为独立 exports
    for methodName, fn in pairs({
        GetState        = GetVehicleState,
        UpdateComponent = UpdateComponent,
        ResetComponents = ResetComponents,
        SetNitrous      = SetNitrous,
        GetNitrous      = GetNitrous,
        SetTuned        = SetTuned,
        CheckTune       = CheckTune,
        AddDistance     = AddDistance,
        SaveMods        = SaveMods,
    }) do
        local exportName = ('service_vehicles_%s'):format(methodName)
        exports(exportName, fn)
    end
end

print('[custom-vehicles] 🔧 车辆状态管理已启动 (vehicle_state.lua)')
print('[custom-vehicles]   Exports: GetVehicleState, UpdateVehicleComponent, ResetVehicleComponents, SetVehicleNitrous, GetVehicleNitrous, SetVehicleTuned, CheckVehicleTune, AddVehicleDistance, SaveVehicleMods')
print('[custom-vehicles]   Bus: service_vehicles_GetState/UpdateComponent/ResetComponents/SetNitrous/...')
print('[custom-vehicles]   Compat: qb-mechanicjob 旧事件 & callback 全部桥接')
