local QBCore = exports['qb-core']:GetCoreObject()

--- 车库反馈（V-1）：统一走 custom-notify 的三层分派。
--- 车库原来全套 QBCore.Functions.Notify，与警情/交易挤同一条通道，样式也不统一。
---@param text string
---@param kind string|nil 'error' | nil（其余一律 feed）
---@param length number|nil
local function feedback(text, kind, length)
    local pushKind = (kind == 'error') and 'error' or 'feed'
    local src = GetPlayerServerId(PlayerId())
    pcall(function()
        exports['custom-notify']:Push(src, pushKind, text, nil, { duration = length })
    end)
end

local PlayerData = {}
local PlayerGang = {}
local PlayerJob = {}
local garageZones = {}
local garageBlips = {}  -- 跟踪所有创建的 blip，按 garage index 索引
local listenForKey = false
local playerLicences = {}  -- 缓存玩家证件状态

-- 检查玩家是否拥有进入指定车库所需的证件
local function HasRequiredLicense(garage)
    if not garage.requiredLicense then return true end
    return playerLicences[garage.requiredLicense] == true
end

-- 刷新玩家证件缓存（O(1) 内存查询）
local function RefreshLicenseCache()
    local metadata = PlayerData.metadata
    if metadata and metadata['licences'] then
        playerLicences = metadata['licences']
    end
end

-- Functions

local function CheckPlayers(vehicle)
    for i = -1, 5, 1 do
        local seat = GetPedInVehicleSeat(vehicle, i)
        if seat then
            TaskLeaveVehicle(seat, vehicle, 0)
        end
    end
    Wait(1500)
    QBCore.Functions.DeleteVehicle(vehicle)
end

local function OpenGarageMenu(data)
    local garage = Config.Garages[data.indexgarage]
    if garage and garage.takeVehicle then
        local dist = #(GetEntityCoords(PlayerPedId()) - garage.takeVehicle)
        if dist > 6.0 then
            feedback('靠近车库入口后再按 E', 'error', 3000)
            return
        end
    end
    QBCore.Functions.TriggerCallback('qb-garages:server:GetGarageVehicles', function(result)
        if result == nil then return feedback(Lang:t('error.no_vehicles'), 'error', 5000) end
        local formattedVehicles = {}
        for _, v in pairs(result) do
            local enginePercent = QBCore.Shared.Round(v.engine, 0)
            local bodyPercent = QBCore.Shared.Round(v.body, 0)
            local vname = nil
            pcall(function()
                vname = QBCore.Shared.Vehicles[v.vehicle].name
            end)
            formattedVehicles[#formattedVehicles + 1] = {
                vehicle = v.vehicle,
                vehicleLabel = vname or v.vehicle,
                plate = v.plate,
                state = v.state,
                fuel = v.fuel,
                engine = enginePercent,
                body = bodyPercent,
                distance = v.drivingdistance or 0,
                garage = Config.Garages[data.indexgarage],
                type = data.type,
                index = data.indexgarage,
                depotPrice = v.depotprice or 0,
                balance = v.balance or 0
            }
        end
        -- V-10：SetNuiFocus 是按资源的，必须由拥有 ui_page 的我们自己来按。
        -- （真正的按下在文件末尾的 exports('ApplyFocus') 里，由 custom-ui 的栈回调）
        -- 把 owner 传给 custom-ui 的栈，它会回过来调我们的 ApplyFocus（见文件末尾的 export）。
        local ok, err = pcall(function()
            exports['custom-ui']:OpenMenu({ keepInput = false, owner = GetCurrentResourceName() })
        end)
        -- 双保险：无论栈有没有走通，都由**我们自己**按一次焦点（这是本资源的 ui_page）。
        -- 栈的 ownerApply 失败时是静默的（老版本 custom-ui / 导出缺失），只靠它会把
        -- "面板出来但没光标"重新演一遍。
        SetNuiFocusKeepInput(false)
        SetNuiFocus(true, true)
        if not ok then
            print(('[qb-garages] custom-ui OpenMenu 调用失败：%s'):format(tostring(err)))
        end
        SendNUIMessage({
            action = 'VehicleList',
            garageLabel = Config.Garages[data.indexgarage].label,
            vehicles = formattedVehicles,
        })
    end, data.indexgarage, data.type, data.category)
end

local function DepositVehicle(veh, data)
    local plate = QBCore.Functions.GetPlate(veh)
    QBCore.Functions.TriggerCallback('qb-garages:server:canDeposit', function(canDeposit)
        if canDeposit then
            local bodyDamage = math.ceil(GetVehicleBodyHealth(veh))
            local engineDamage = math.ceil(GetVehicleEngineHealth(veh))
            local totalFuel = exports[Config.FuelResource]:GetFuel(veh)
            TriggerServerEvent('qb-mechanicjob:server:SaveVehicleProps', QBCore.Functions.GetVehicleProperties(veh))
            TriggerServerEvent('qb-garages:server:updateVehicleStats', plate, totalFuel, engineDamage, bodyDamage)
            CheckPlayers(veh)
            if plate then TriggerServerEvent('qb-garages:server:UpdateOutsideVehicle', plate, nil) end
            feedback(Lang:t('success.vehicle_parked'), 'primary', 4500)
        else
            feedback(Lang:t('error.not_owned'), 'error', 3500)
        end
    end, plate, data.type, data.indexgarage, 1)
end

local function IsVehicleAllowed(classList, vehicle)
    if not Config.ClassSystem then return true end
    for _, class in ipairs(classList) do
        if GetVehicleClass(vehicle) == class then
            return true
        end
    end
    return false
end

local function CreateBlip(garage)
    local blip = AddBlipForCoord(garage.takeVehicle.x, garage.takeVehicle.y, garage.takeVehicle.z)
    SetBlipSprite(blip, garage.blipNumber)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 0.60)
    SetBlipAsShortRange(blip, true)
    SetBlipColour(blip, garage.blipColor)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(garage.blipName)
    EndTextCommandSetBlipName(blip)
    return blip
end

local function RemoveAllBlips()
    for index, blip in pairs(garageBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    garageBlips = {}
end

local function CreateZone(index, garage, zoneType)
    local zone = CircleZone:Create(garage.takeVehicle, 10.0, {
        name = zoneType .. '_' .. index,
        debugPoly = false,
        useZ = true,
        data = {
            indexgarage = index,
            type = garage.type,
            category = garage.category
        }
    })

    return zone
end

local function CreateBlipsZones()
    PlayerData = QBCore.Functions.GetPlayerData()
    PlayerGang = PlayerData.gang
    PlayerJob = PlayerData.job
    RefreshLicenseCache()

    -- 先清除旧 blip 和 zone
    RemoveAllBlips()
    for _, zone in ipairs(garageZones) do
        zone:destroy()
    end
    garageZones = {}

    for index, garage in pairs(Config.Garages) do
        local zone
        -- 证件门控：blip 仅在持有对应证件时显示
        if garage.showBlip and HasRequiredLicense(garage) then
            garageBlips[index] = CreateBlip(garage)
        end

        if garage.type == 'job' and PlayerJob and (PlayerJob.name == garage.job or PlayerJob.type == garage.jobType) then
            zone = CreateZone(index, garage, 'job')
        elseif garage.type == 'gang' and PlayerGang and PlayerGang.name == garage.job then
            zone = CreateZone(index, garage, 'gang')
        elseif garage.type == 'depot' then
            -- depot 也需要证件检查
            if HasRequiredLicense(garage) then
                zone = CreateZone(index, garage, 'depot')
            end
        elseif garage.type == 'public' then
            -- public 车库：证件门控交互
            if HasRequiredLicense(garage) then
                zone = CreateZone(index, garage, 'public')
            end
        end

        if zone then
            garageZones[#garageZones + 1] = zone
        end
    end

    local comboZone = ComboZone:Create(garageZones, { name = 'garageCombo', debugPoly = false })

    comboZone:onPlayerInOut(function(isPointInside, _, zone)
        if isPointInside then
            -- 二次验证：确保玩家仍持有证件（防止并发变更）
            local garage = Config.Garages[zone.data.indexgarage]
            if garage and garage.requiredLicense and not HasRequiredLicense(garage) then
                feedback(('需要 %s 才能使用这个车库'):format(tostring(garage.requiredLicense)), 'error')
                return
            end

            listenForKey = true
            CreateThread(function()
                while listenForKey do
                    Wait(0)
                    if IsControlJustReleased(0, 38) then
                        if GetVehiclePedIsUsing(PlayerPedId()) ~= 0 then
                            if zone.data.type == 'depot' then
                                feedback('扣押场不能存车，请去公共车库', 'error')
                                return
                            end
                            local currentVehicle = GetVehiclePedIsUsing(PlayerPedId())
                            if not IsVehicleAllowed(zone.data.category, currentVehicle) then
                                feedback(Lang:t('error.not_correct_type'), 'error', 3500)
                                return
                            end
                            DepositVehicle(currentVehicle, zone.data)
                        else
                            OpenGarageMenu(zone.data)
                        end
                    end
                end
            end)

            local displayText = Lang:t('info.car_e')
            if zone.data.vehicle == 'sea' then
                displayText = Lang:t('info.sea_e')
            elseif zone.data.vehicle == 'air' then
                displayText = Lang:t('info.air_e')
            elseif zone.data.vehicle == 'rig' then
                displayText = Lang:t('info.rig_e')
            elseif zone.data.type == 'depot' then
                displayText = Lang:t('info.depot_e')
            end
            -- N-2 续（PO 2026-11-12「交互还走原来 notification」）：车位提示改走 custom-prompt。
            -- 原文案形如 "E - Depot"，键块由 custom-prompt 自己画，所以把前缀剥掉。
            -- custom-prompt 有"同内容不重发"的守卫（本文件是逐帧循环，也不会刷 NUI）。
            local label = tostring(displayText):gsub('^E%s*%-%s*', '')
            pcall(function() exports['custom-prompt']:Show({ key = 'E', label = label }) end)
        else
            listenForKey = false
            pcall(function() exports['custom-prompt']:Hide() end)
        end
    end)
end

local function doCarDamage(currentVehicle, stats, props)
    local engine = stats.engine + 0.0
    local body = stats.body + 0.0
    SetVehicleEngineHealth(currentVehicle, engine)
    SetVehicleBodyHealth(currentVehicle, body)
    if not next(props) then return end
    if props.doorStatus then
        for k, v in pairs(props.doorStatus) do
            if v then SetVehicleDoorBroken(currentVehicle, tonumber(k), true) end
        end
    end
    if props.tireBurstState then
        for k, v in pairs(props.tireBurstState) do
            if v then SetVehicleTyreBurst(currentVehicle, tonumber(k), true) end
        end
    end
    if props.windowStatus then
        for k, v in pairs(props.windowStatus) do
            if not v then SmashVehicleWindow(currentVehicle, tonumber(k)) end
        end
    end
end

function GetSpawnPoint(garage)
    local location = nil
    if #garage.spawnPoint > 1 then
        local maxTries = #garage.spawnPoint
        for _ = 1, maxTries do
            local randomIndex = math.random(1, #garage.spawnPoint)
            local chosenSpawnPoint = garage.spawnPoint[randomIndex]
            local isOccupied = IsPositionOccupied(
                chosenSpawnPoint.x,
                chosenSpawnPoint.y,
                chosenSpawnPoint.z,
                5.0,   -- range
                false,
                true,  -- checkVehicles
                false, -- checkPeds
                false,
                false,
                0,
                false
            )
            if not isOccupied then
                location = chosenSpawnPoint
                break
            end
        end
    elseif #garage.spawnPoint == 1 then
        local chosenSpawnPoint = garage.spawnPoint[1]
        local isOccupied = IsPositionOccupied(
            chosenSpawnPoint.x,
            chosenSpawnPoint.y,
            chosenSpawnPoint.z,
            5.0,   -- range
            false,
            true,  -- checkVehicles
            false, -- checkPeds
            false,
            false,
            0,
            false
        )
        if not isOccupied then
            location = chosenSpawnPoint
        end
    end
    if not location then
        feedback(Lang:t('error.vehicle_occupied'), 'error')
    end
    return location
end

-- NUI Callbacks

RegisterNUICallback('closeGarage', function(_, cb)
    local ok = pcall(function() exports['custom-ui']:CloseMenu({ owner = GetCurrentResourceName() }) end)
    if not ok then SetNuiFocus(false, false) end
    cb('ok')
end)

RegisterNUICallback('takeOutVehicle', function(data, cb)
    TriggerEvent('qb-garages:client:takeOutGarage', data)
    cb('ok')
end)

RegisterNUICallback('trackVehicle', function(plate, cb)
    TriggerServerEvent('qb-garages:server:trackVehicle', plate)
    cb('ok')
end)

RegisterNUICallback('takeOutDepo', function(data, cb)
    local depotPrice = data.depotPrice
    if depotPrice ~= 0 then
        TriggerServerEvent('qb-garages:server:PayDepotPrice', data)
    else
        TriggerEvent('qb-garages:client:takeOutGarage', data)
    end
    cb('ok')
end)

-- Events

RegisterNetEvent('qb-garages:client:trackVehicle', function(coords)
    SetNewWaypoint(coords.x, coords.y)
end)

local function CheckPlate(vehicle, plateToSet)
    local vehiclePlate = promise.new()
    CreateThread(function()
        while true do
            Wait(500)
            if GetVehicleNumberPlateText(vehicle) == plateToSet then
                vehiclePlate:resolve(true)
                return
            else
                SetVehicleNumberPlateText(vehicle, plateToSet)
            end
        end
    end)
    return vehiclePlate
end

RegisterNetEvent('qb-garages:client:takeOutGarage', function(data)
    QBCore.Functions.TriggerCallback('qb-garages:server:IsSpawnOk', function(spawn)
        if spawn then
            -- NUI 回传的 garage 表可能丢失 vector4 类型；优先用 index 从客户端 Config 取
            local garage = Config.Garages[data.index] or data.garage
            if GetConvarInt('tcity_debug', 0) == 1 then
                print(('[qb-garages] takeOutGarage plate=%s index=%s garage=%s'):format(
                    tostring(data.plate), tostring(data.index), tostring(garage and garage.label)))
            end
            if not garage or not garage.spawnPoint then
                feedback('车库配置无效', 'error', 5000)
                return
            end
            local location = GetSpawnPoint(garage)
            if not location then
                feedback('取车点被占用，先把车开走', 'error', 5000)
                return
            end
            QBCore.Functions.TriggerCallback('qb-garages:server:spawnvehicle', function(netId, properties, vehPlate)
                if not netId then
                    feedback('取车失败：服务端拒绝生成载具（驾照/在外车辆上限）', 'error', 6000)
                    return
                end
                while not NetworkDoesNetworkIdExist(netId) do Wait(10) end
                local veh = NetworkGetEntityFromNetworkId(netId)
                Citizen.Await(CheckPlate(veh, vehPlate))
                QBCore.Functions.SetVehicleProperties(veh, properties)
                exports[Config.FuelResource]:SetFuel(veh, data.stats.fuel)
                TriggerServerEvent('qb-garages:server:updateVehicleState', 0, vehPlate)
                TriggerEvent('vehiclekeys:client:SetOwner', vehPlate)
                -- V-2：取车成功必须留一条回执（原来完全静默，玩家不知道生效没有）
                feedback(('已取车 %s · %s'):format(tostring(vehPlate),
                    tostring(garage.label or data.garage and data.garage.label or '车库')))
                -- 同步预热 custom-vehicles 客户端缓存，防止 Warp 后冷缓存误锁
                local normPlate = vehPlate:gsub('^%s+', ''):gsub('%s+$', ''):upper()
                TriggerEvent('custom-vehicles:client:keysUpdated', {
                    plate = normPlate, hasKeys = true, keyType = 'owner'
                })
                if Config.Warp then TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1) end
                if Config.VisuallyDamageCars then doCarDamage(veh, data.stats, properties) end
                SetVehicleEngineOn(veh, true, true, false)
            end, data.plate, data.vehicle, location, true)
        else
            feedback(Lang:t('error.not_depot'), 'error', 5000)
        end
    end, data.plate, data.type)
end)

-- Housing calls

local houseGarageZones = {}
local listenForKeyHouse = false
local houseComboZones = nil

local function CreateHouseZone(index, garage, zoneType)
    local houseZone = CircleZone:Create(garage.takeVehicle, 5.0, {
        name = zoneType .. '_' .. index,
        debugPoly = false,
        useZ = true,
        data = {
            indexgarage = index,
            type = zoneType,
            category = garage.category
        }
    })

    if houseZone then
        houseGarageZones[#houseGarageZones + 1] = houseZone

        if not houseComboZones then
            houseComboZones = ComboZone:Create(houseGarageZones, { name = 'houseComboZones', debugPoly = false })
        else
            houseComboZones:AddZone(houseZone)
        end
    end

    houseComboZones:onPlayerInOut(function(isPointInside, _, zone)
        if isPointInside then
            listenForKeyHouse = true
            CreateThread(function()
                while listenForKeyHouse do
                    Wait(0)
                    if IsControlJustReleased(0, 38) then
                        if GetVehiclePedIsUsing(PlayerPedId()) ~= 0 then
                            local currentVehicle = GetVehiclePedIsUsing(PlayerPedId())
                            DepositVehicle(currentVehicle, zone.data)
                        else
                            OpenGarageMenu(zone.data)
                        end
                    end
                end
            end)
            local houseLabel = tostring(Lang:t('info.house_garage')):gsub('^E%s*%-%s*', '')
            pcall(function() exports['custom-prompt']:Show({ key = 'E', label = houseLabel }) end)
        else
            listenForKeyHouse = false
            exports['qb-core']:HideText()
        end
    end)
end

local function ZoneExists(zoneName)
    for _, zone in ipairs(houseGarageZones) do
        if zone.name == zoneName then
            return true
        end
    end
    return false
end

local function RemoveHouseZone(zoneName)
    local removedZone = houseComboZones:RemoveZone(zoneName)
    if removedZone then
        removedZone:destroy()
    end
    for index, zone in ipairs(houseGarageZones) do
        if zone.name == zoneName then
            table.remove(houseGarageZones, index)
            break
        end
    end
end

RegisterNetEvent('qb-garages:client:setHouseGarage', function(house, hasKey) -- event sent periodically from housing
    if not house then return end
    local formattedHouseName = string.gsub(string.lower(house), ' ', '')
    local zoneName = 'house_' .. formattedHouseName
    if Config.Garages[formattedHouseName] then
        if hasKey and not ZoneExists(zoneName) then
            CreateHouseZone(formattedHouseName, Config.Garages[formattedHouseName], 'house')
        elseif not hasKey and ZoneExists(zoneName) then
            RemoveHouseZone(zoneName)
        end
    else
        QBCore.Functions.TriggerCallback('qb-garages:server:getHouseGarage', function(garageInfo) -- create garage if not exist
            if not garageInfo.garage then return end
            local garageCoords = json.decode(garageInfo.garage)
            Config.Garages[formattedHouseName] = {
                houseName = house,
                takeVehicle = vector3(garageCoords.x, garageCoords.y, garageCoords.z),
                spawnPoint = {
                    vector4(garageCoords.x, garageCoords.y, garageCoords.z, garageCoords.w or garageCoords.h)
                },
                label = garageInfo.label,
                type = 'house',
                category = Config.VehicleClass['all']
            }
            TriggerServerEvent('qb-garages:server:syncGarage', Config.Garages)
        end, house)
    end
end)

RegisterNetEvent('qb-garages:client:houseGarageConfig', function(houseGarages)
    for houseName, garageConfig in pairs(houseGarages) do
        local formattedHouseName = string.gsub(string.lower(garageConfig.label), ' ', '')
        if garageConfig.takeVehicle and garageConfig.takeVehicle.x and garageConfig.takeVehicle.y and garageConfig.takeVehicle.z and garageConfig.takeVehicle.w then
            Config.Garages[formattedHouseName] = {
                houseName = houseName,
                takeVehicle = vector3(garageConfig.takeVehicle.x, garageConfig.takeVehicle.y, garageConfig.takeVehicle.z),
                spawnPoint = {
                    vector4(garageConfig.takeVehicle.x, garageConfig.takeVehicle.y, garageConfig.takeVehicle.z, garageConfig.takeVehicle.w)
                },
                label = garageConfig.label,
                type = 'house',
                category = Config.VehicleClass['all']
            }
        end
    end
    TriggerServerEvent('qb-garages:server:syncGarage', Config.Garages)
end)

RegisterNetEvent('qb-garages:client:addHouseGarage', function(house, garageInfo) -- event from housing on garage creation
    local formattedHouseName = string.gsub(string.lower(house), ' ', '')
    Config.Garages[formattedHouseName] = {
        houseName = house,
        takeVehicle = vector3(garageInfo.takeVehicle.x, garageInfo.takeVehicle.y, garageInfo.takeVehicle.z),
        spawnPoint = {
            vector4(garageInfo.takeVehicle.x, garageInfo.takeVehicle.y, garageInfo.takeVehicle.z, garageInfo.takeVehicle.w)
        },
        label = garageInfo.label,
        type = 'house',
        category = Config.VehicleClass['all']
    }
    TriggerServerEvent('qb-garages:server:syncGarage', Config.Garages)
end)

-- Handlers

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    CreateBlipsZones()
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateBlipsZones()
end)

-- 证件状态变化时实时重建 blip 和 zone
RegisterNetEvent('QBCore:Player:SetPlayerData', function(val)
    local oldLicences = playerLicences
    PlayerData = val
    RefreshLicenseCache()
    -- 仅在证件状态实际变化时重建（避免不必要的开销）
    for certType, hasLicense in pairs(playerLicences) do
        if oldLicences[certType] ~= hasLicense then
            CreateBlipsZones()
            return
        end
    end
end)

RegisterNetEvent('QBCore:Client:OnGangUpdate', function(gang)
    PlayerGang = gang
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    PlayerJob = job
end)

-- ══════════════════════════════════════════════════════════════
-- V-10（2026-11-12 PO：扣押场取车面板没有光标、点不了付款）
-- SetNuiFocus 是**按资源**的：custom-ui 没有 ui_page，从它那里调等于把焦点给空气。
-- custom-ui 的输入栈只决定"该谁有焦点"，然后回调**拥有页面**的资源的这个 export。
-- （上一版漏了这段 —— 注释里写了 export 名，代码里没有，栈的 ownerApply 静默失败。）
-- ══════════════════════════════════════════════════════════════
exports('ApplyFocus', function(hasFocus, hasCursor, keepInput)
    SetNuiFocusKeepInput(keepInput == true)
    SetNuiFocus(hasFocus == true, hasCursor ~= false)
end)
