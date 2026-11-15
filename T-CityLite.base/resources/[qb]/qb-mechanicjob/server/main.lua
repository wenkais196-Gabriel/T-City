local QBCore = exports['qb-core']:GetCoreObject()
-- ═══════════════════════════════════════════════════════════════
-- v3.1: 车辆状态管理已迁移至 custom-vehicles (server/vehicle_state.lua)
--   - vehicleComponents / drivingDistance / tunedVehicles / nitrousVehicles
--   - 所有持久化事件 & callback 由 custom-vehicles 统一处理
--   - qb-mechanicjob 通过 exports.custom-vehicles 或 Bus 访问车辆状态
-- ═══════════════════════════════════════════════════════════════

-- Functions

function Trim(plate)
    return (string.gsub(plate, '^%s*(.-)%s*$', '%1'))
end

local function StartParticles(coords, netId, color)
    for _, playerId in ipairs(GetPlayers()) do
        local playerPed = GetPlayerPed(playerId)
        local playerCoords = GetEntityCoords(playerPed)
        local distance = #(coords - playerCoords)
        if distance < 10 then
            Player(playerId).state:set('paint_particles', true, false)
            TriggerClientEvent('qb-mechanicjob:client:startParticles', playerId, netId, color)
        end
    end
end

local function StopParticles()
    for _, playerId in ipairs(GetPlayers()) do
        if Player(playerId).state.paint_particles then
            Player(playerId).state:set('paint_particles', false, false)
            TriggerClientEvent('qb-mechanicjob:client:stopParticles', playerId)
        end
    end
end

local function LerpColor(colorFrom, colorTo, fraction)
    return {
        r = colorFrom.r + (colorTo.r - colorFrom.r) * fraction,
        g = colorFrom.g + (colorTo.g - colorFrom.g) * fraction,
        b = colorFrom.b + (colorTo.b - colorFrom.b) * fraction
    }
end

local function TransitionVehicleColor(vehicle, section, currentColor, targetColor, duration)
    local startTime = GetGameTimer()
    local endTime = startTime + duration
    while GetGameTimer() <= endTime do
        local currentTime = GetGameTimer()
        local fraction = (currentTime - startTime) / duration
        local newColor = LerpColor(currentColor, targetColor, fraction)
        if section == 'primary' then
            SetVehicleCustomPrimaryColour(vehicle, math.floor(newColor.r), math.floor(newColor.g), math.floor(newColor.b))
        elseif section == 'secondary' then
            SetVehicleCustomSecondaryColour(vehicle, math.floor(newColor.r), math.floor(newColor.g), math.floor(newColor.b))
        end
        Wait(0)
    end
end

local function GetPaintTypeIndex(type)
    if type == 'metallic' then return 0 end
    if type == 'matte' then return 12 end
    if type == 'chrome' then return 120 end
    return 0
end

-- ═══════════════════════════════════════════════════════════════
-- Callbacks
--   getnitrousVehicles / checkTune / getVehicleStatus
--   已由 custom-vehicles/server/vehicle_state.lua 统一注册。
--   qb-mechanicjob 不再重复注册，避免 FiveM 后加载覆盖前加载。
--   仅保留 hasPermission (机修专属权限检查)。
-- ═══════════════════════════════════════════════════════════════

QBCore.Functions.CreateCallback('qb-mechanicjob:server:hasPermission', function(source, cb)
    if QBCore.Functions.HasPermission(source, { 'god', 'admin', 'command' }) then
        cb(true)
    else
        cb(false)
    end
end)

-- Events

RegisterNetEvent('qb-mechanicjob:server:stash', function(data)
    local src = source
    local shopName = data.job
    if not Config.Shops[shopName] then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Config.Shops[shopName].managed and Player.PlayerData.job.name ~= shopName then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local stashCoords = Config.Shops[shopName].stash
    if #(playerCoords - stashCoords) < 2.5 then
        local stashName = shopName .. '_stash'
        exports['qb-inventory']:OpenInventory(src, stashName, {
            maxweight = 4000000,
            slots = 100,
        })
    end
end)

-- 喷漆台是"本店员工 + 在本店喷漆位旁边"才能用的（client 侧 qb-target 的 paintbooth 就是按 job 限制的）。
-- 原来这两个 handler 没有任何来源校验：任何玩家可以给**地图上任意一辆车**免费改色，
-- 还能让服务端把它 FreezeEntityPosition 住 PaintTime*1000 毫秒（顺手可以把别人的车冻在路口）。
local PAINT_MAX_DISTANCE = 20.0     -- 玩家到本店喷漆位的最大距离（target 圈是 2.0，留出走动余量）
local PAINT_VEHICLE_RANGE = 20.0    -- 车到玩家的最大距离

local function CanSprayVehicle(src, netId)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData and Player.PlayerData.job
    if type(job) ~= 'table' or type(job.name) ~= 'string' then return false end
    local shop = Config.Shops and Config.Shops[job.name]
    if type(shop) ~= 'table' or not shop.managed then return false end
    if type(netId) ~= 'number' then return false end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    local playerCoords = GetEntityCoords(ped)
    if shop.paint and #(playerCoords - shop.paint) > PAINT_MAX_DISTANCE then return false end
    if #(playerCoords - GetEntityCoords(vehicle)) > PAINT_VEHICLE_RANGE then return false end
    return true
end

RegisterNetEvent('qb-mechanicjob:server:sprayVehicleCustom', function(netId, section, type, color)
    local src = source
    if not CanSprayVehicle(src, netId) then return end
    if section ~= 'primary' and section ~= 'secondary' then return end
    if type(color) ~= 'table' then return end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local vehicleCoords = GetEntityCoords(vehicle)
    local paintTypeIndex = GetPaintTypeIndex(type)
    FreezeEntityPosition(vehicle, true)
    StartParticles(vehicleCoords, netId, color)
    local r, g, b
    if section == 'primary' then
        local _, colorSecondary = GetVehicleColours(vehicle)
        SetVehicleColours(vehicle, paintTypeIndex, colorSecondary)
        r, g, b = GetVehicleCustomPrimaryColour(vehicle)
    elseif section == 'secondary' then
        local colorPrimary, _ = GetVehicleColours(vehicle)
        SetVehicleColours(vehicle, colorPrimary, paintTypeIndex)
        r, g, b = GetVehicleCustomSecondaryColour(vehicle)
    end
    local currentColor = { r = r, g = g, b = b }
    TransitionVehicleColor(vehicle, section, currentColor, color, Config.PaintTime * 1000)
    StopParticles()
    FreezeEntityPosition(vehicle, false)
end)

RegisterNetEvent('qb-mechanicjob:server:sprayVehicle', function(netId, primary, secondary, pearlescent, wheel, colors)
    local src = source
    if not CanSprayVehicle(src, netId) then return end
    if type(colors) ~= 'table' then return end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local vehicleCoords = GetEntityCoords(vehicle)
    FreezeEntityPosition(vehicle, true)

    if colors.primary then
        StartParticles(vehicleCoords, netId, colors.primary)
        Wait(Config.PaintTime * 1000)
        -- local _, colorSecondary = GetVehicleColours(vehicle)
        -- ClearVehicleCustomPrimaryColour(vehicle) -- does not exist yet
        -- SetVehicleColours(vehicle, tonumber(primary), colorSecondary)
        TriggerClientEvent('qb-mechanicjob:client:vehicleSetColors', -1, netId, 'primary', primary)
        StopParticles()
    end

    if colors.secondary then
        StartParticles(vehicleCoords, netId, colors.secondary)
        Wait(Config.PaintTime * 1000)
        -- local colorPrimary, _ = GetVehicleColours(vehicle)
        -- ClearVehicleCustomSecondaryColour(vehicle) -- does not exist yet
        -- SetVehicleColours(vehicle, colorPrimary, tonumber(secondary))
        TriggerClientEvent('qb-mechanicjob:client:vehicleSetColors', -1, netId, 'secondary', secondary)
        StopParticles()
    end

    if colors.pearlescent then
        StartParticles(vehicleCoords, netId, colors.pearlescent)
        Wait(Config.PaintTime * 1000)
        -- local pearlescentColor, wheelColor = GetVehicleExtraColours(vehicle) -- does not exist yet
        -- SetVehicleExtraColours(vehicle, tonumber(pearlescent) or pearlescentColor, tonumber(wheel) or wheelColor) -- does not exist yet
        TriggerClientEvent('qb-mechanicjob:client:vehicleSetColors', -1, netId, 'pearlescent', pearlescent)
        StopParticles()
    end

    if colors.wheel then
        StartParticles(vehicleCoords, netId, colors.wheel)
        Wait(Config.PaintTime * 1000)
        -- local pearlescentColor, wheelColor = GetVehicleExtraColours(vehicle) -- does not exist yet
        -- SetVehicleExtraColours(vehicle, tonumber(pearlescent) or pearlescentColor, tonumber(wheel) or wheelColor) -- does not exist yet
        TriggerClientEvent('qb-mechanicjob:client:vehicleSetColors', -1, netId, 'wheel', wheel)
        StopParticles()
    end

    FreezeEntityPosition(vehicle, false)
end)

-- ═══════════════════════════════════════════════════════════════
-- 车辆状态事件已迁移至 custom-vehicles/server/vehicle_state.lua
--   syncNitrous / syncNitrousFlames / tuneStatus / SaveVehicleProps
--   repairVehicleComponent / updateVehicleComponents / updateDrivingDistance
-- 兼容事件名在 custom-vehicles 中注册，qb-mechanicjob 不再重复处理
-- ═══════════════════════════════════════════════════════════════

-- 这个 handler 顾客也会触发（repair.lua 修车时按配方逐项扣料），所以**不能**加职业限制；
-- 但 `part` / `amount` 完全是客户端给的：part 随便填会在 `QBCore.Shared.Items[part]` 上炸出 nil，
-- amount 可以给负数或天文数字（负数扣料还可能把背包数量写成负的）。
RegisterNetEvent('qb-mechanicjob:server:removeItem', function(part, amount)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(part) ~= 'string' or type(QBCore.Shared.Items[part]) ~= 'table' then return end

    amount = tonumber(amount) or 1
    if amount < 1 then amount = 1 end
    if amount > 10 then amount = 10 end
    amount = math.floor(amount)

    if not exports['qb-inventory']:RemoveItem(src, part, amount, false, 'qb-mechanicjob:server:removeItem') then DropPlayer(src, 'qb-mechanicjob:server:removeItem') end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[part], 'remove')
end)

-- Items

local performanceParts = {
    'veh_armor',
    'veh_brakes',
    'veh_engine',
    'veh_suspension',
    'veh_transmission',
    'veh_turbo',
}

for i = 1, #performanceParts do
    QBCore.Functions.CreateUseableItem(performanceParts[i], function(source, item)
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then return end
        if Config.RequireJob and Player.PlayerData.job.type ~= 'mechanic' then return end
        TriggerClientEvent('qb-mechanicjob:client:installPart', source, item.name)
    end)
end

local cosmeticParts = {
    'veh_interior',
    'veh_exterior',
    'veh_wheels',
    'veh_neons',
    'veh_xenons',
    'veh_tint',
    'veh_plates',
}

for i = 1, #cosmeticParts do
    QBCore.Functions.CreateUseableItem(cosmeticParts[i], function(source, item)
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then return end
        if Config.RequireJob and Player.PlayerData.job.type ~= 'mechanic' then return end
        TriggerClientEvent('qb-mechanicjob:client:installCosmetic', source, item.name)
    end)
end

QBCore.Functions.CreateUseableItem('veh_toolbox', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    if Config.RequireJob and Player.PlayerData.job.type ~= 'mechanic' then return end
    TriggerClientEvent('qb-mechanicjob:client:PartsMenu', source)
end)

QBCore.Functions.CreateUseableItem('tunerlaptop', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    if Config.RequireJob and Player.PlayerData.job.type ~= 'mechanic' then return end
    TriggerClientEvent('qb-mechanicjob:client:openChip', source)
end)

QBCore.Functions.CreateUseableItem('nitrous', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    if Config.RequireJob and Player.PlayerData.job.type ~= 'mechanic' then return end
    TriggerClientEvent('qb-mechanicjob:client:installNitrous', source)
end)

QBCore.Functions.CreateUseableItem('tirerepairkit', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    TriggerClientEvent('qb-mechanicjob:client:repairTire', source)
end)

QBCore.Functions.CreateUseableItem('repairkit', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    TriggerClientEvent('qb-mechanicjob:client:repairVehicle', source)
end)

QBCore.Functions.CreateUseableItem('advancedrepairkit', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    TriggerClientEvent('qb-mechanicjob:client:repairVehicleFull', source)
end)

QBCore.Functions.CreateUseableItem('cleaningkit', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    TriggerClientEvent('qb-mechanicjob:client:cleanVehicle', source)
end)

-- 🔧 车间分配指令（对接 custom-career department）
QBCore.Commands.Add('setmechdept', '分配机修工车间', { { name = 'id', help = 'Player ID' }, { name = 'shop', help = 'mechanic / bennys / beeker' } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local targetId = tonumber(args[1])
    local shop = args[2] and args[2]:lower()
    if not Player or Player.PlayerData.job.type ~= 'mechanic' or Player.PlayerData.job.grade.level < 4 then
        TriggerClientEvent('QBCore:Notify', src, '仅机修老板 (Boss) 可分配车间', 'error')
        return
    end
    if not Config.ShopDepartments[shop] then
        TriggerClientEvent('QBCore:Notify', src, ('无效车间: %s'):format(shop or 'nil'), 'error')
        return
    end
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error'); return end
    if Target.PlayerData.job.type ~= 'mechanic' then TriggerClientEvent('QBCore:Notify', src, '目标不是机修工', 'error'); return end
    local success = exports['custom-career']:SetPlayerDepartment(targetId, shop)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('已将 %s 分配至 %s'):format(Target.PlayerData.charinfo.firstname, Config.ShopDepartments[shop].label), 'success')
        TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('你已被分配至 %s'):format(Config.ShopDepartments[shop].label), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, '操作失败', 'error')
    end
end)

-- Commands

QBCore.Commands.Add('fix', 'Repair your vehicle (Admin Only)', {}, false, function(source)
    -- 🛡️ Fix: 添加服务器侧玩家有效性校验
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    local ped = GetPlayerPed(source)
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        TriggerClientEvent('QBCore:Notify', source, '你不在任何载具中', 'error')
        return
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    if not plate then return end
    local trimmedPlate = Trim(plate)
    -- v3.1: 使用 custom-vehicles 统一接口重置部件状态
    if exports['custom-vehicles'] and exports['custom-vehicles'].ResetVehicleComponents then
        exports['custom-vehicles']:ResetVehicleComponents(trimmedPlate)
    end
    -- 先修复耐久数据，再触发客户端视觉效果
    TriggerClientEvent('qb-mechanicjob:client:fixEverything', source)
end, 'admin')
