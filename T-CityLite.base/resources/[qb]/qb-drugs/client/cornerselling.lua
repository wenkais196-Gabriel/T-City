local cornerselling = false
local hasTarget = false
local lastPed = {}
local stealingPed = nil
local stealData = {}
local availableDrugs = {}
local currentOfferDrug = nil
local CurrentCops = 0
local textDrawn = false
local zoneMade = false

-- Functions
local function LoadAnimDict(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end
end

local function TooFarAway()
    QBCore.Functions.Notify(Lang:t('error.too_far_away'), 'error')
    LocalPlayer.state:set('inv_busy', false, true)
    cornerselling = false
    hasTarget = false
    availableDrugs = {}
end

-- Fixed:
-- swapped the condition to `random <= Config.PoliceCallChance` so "Config.PoliceCallChance", represents the call probability.
local function PoliceCall()
    local random = math.random(1, 100)
    if random <= Config.PoliceCallChance then
        TriggerServerEvent('police:server:policeAlert', 'Drug sale in progress')
    end
end

local function RobberyPed()
    if Config.UseTarget then
        exports['qb-target']:AddEntityZone('stealingPed', stealingPed, {
            name = 'stealingPed',
            debugPoly = false,
        }, {
            options = {
                {
                    icon = 'fas fa-magnifying-glass',
                    label = Lang:t('info.search_ped'),
                    action = function()
                        local player = PlayerPedId()
                        RequestAnimDict('pickup_object')
                        while not HasAnimDictLoaded('pickup_object') do
                            Wait(0)
                        end
                        TaskPlayAnim(player, 'pickup_object', 'pickup_low', 8.0, -8.0, -1, 1, 0, false, false, false)
                        Wait(2000)
                        ClearPedTasks(player)
                        TriggerServerEvent('qb-drugs:server:giveStealItems', stealData.item, stealData.amount)
                        TriggerEvent('qb-inventory:client:ItemBox', QBCore.Shared.Items[stealData.item], 'add')
                        stealingPed = nil
                        stealData = {}
                        exports['qb-target']:RemoveZone('stealingPed')
                    end,
                    canInteract = function(entity)
                        if IsEntityDead(entity) then
                            return true
                        end
                    end
                }
            },
            distance = 1.5,
        })
        CreateThread(function()
            while stealingPed do
                local playerPed = PlayerPedId()
                local pos = GetEntityCoords(playerPed)
                local pedpos = GetEntityCoords(stealingPed)
                local dist = #(pos - pedpos)
                if dist > 100 then
                    stealingPed = nil
                    stealData = {}
                    exports['qb-target']:RemoveZone('stealingPed')
                    break
                end
                Wait(200)
            end
        end)
    else
        CreateThread(function()
            while stealingPed do
                if IsEntityDead(stealingPed) then
                    local playerPed = PlayerPedId()
                    local pos = GetEntityCoords(playerPed)
                    local pedpos = GetEntityCoords(stealingPed)
                    if not Config.UseTarget and #(pos - pedpos) < 1.5 then
                        if not textDrawn then
                            textDrawn = true
                            exports['qb-core']:DrawText(Lang:t('info.pick_up_button'))
                        end
                        if IsControlJustReleased(0, 38) then
                            exports['qb-core']:KeyPressed()
                            textDrawn = false
                            RequestAnimDict('pickup_object')
                            while not HasAnimDictLoaded('pickup_object') do
                                Wait(0)
                            end
                            TaskPlayAnim(playerPed, 'pickup_object', 'pickup_low', 8.0, -8.0, -1, 1, 0, false, false, false)
                            Wait(2000)
                            ClearPedTasks(playerPed)
                            TriggerServerEvent('qb-drugs:server:giveStealItems', stealData.item, stealData.amount)
                            TriggerEvent('qb-inventory:client:ItemBox', QBCore.Shared.Items[stealData.item], 'add')
                            stealingPed = nil
                            stealData = {}
                        end
                    end
                else
                    local playerPed = PlayerPedId()
                    local pos = GetEntityCoords(playerPed)
                    local pedpos = GetEntityCoords(stealingPed)
                    if #(pos - pedpos) > 100 then
                        stealingPed = nil
                        stealData = {}
                        break
                    end
                end
                Wait(200)
            end
        end)
    end
end

local function SellToPed(ped)
    hasTarget = true

    for i = 1, #lastPed, 1 do
        if lastPed[i] == ped then
            hasTarget = false
            return
        end
    end

    local successChance = math.random(1, 100)
    local scamChance = math.random(1, 100)
    local getRobbed = math.random(1, 100)
    if successChance <= Config.SuccessChance then
        hasTarget = false
        return
    end

    local drugType = math.random(1, #availableDrugs)
    local bagAmount = math.random(1, availableDrugs[drugType].amount)
    if bagAmount > 15 then bagAmount = math.random(9, 15) end

    currentOfferDrug = availableDrugs[drugType]

    local ddata = Config.DrugsPrice[currentOfferDrug.item]
    local randomPrice = math.random(ddata.min, ddata.max) * bagAmount
    if scamChance <= Config.ScamChance then randomPrice = math.random(3, 10) * bagAmount end

    SetEntityAsNoLongerNeeded(ped)
    ClearPedTasks(ped)

    local coords = GetEntityCoords(PlayerPedId(), true)
    local pedCoords = GetEntityCoords(ped)
    local pedDist = #(coords - pedCoords)
    if getRobbed <= Config.RobberyChance then
        TaskGoStraightToCoord(ped, coords, 15.0, -1, 0.0, 0.0)
    else
        TaskGoStraightToCoord(ped, coords, 1.2, -1, 0.0, 0.0)
    end

    while pedDist > 1.5 do
        coords = GetEntityCoords(PlayerPedId(), true)
        pedCoords = GetEntityCoords(ped)
        if getRobbed <= Config.RobberyChance then
            TaskGoStraightToCoord(ped, coords, 15.0, -1, 0.0, 0.0)
        else
            TaskGoStraightToCoord(ped, coords, 1.2, -1, 0.0, 0.0)
        end
        TaskGoStraightToCoord(ped, coords, 1.2, -1, 0.0, 0.0)
        pedDist = #(coords - pedCoords)
        Wait(100)
    end

    TaskLookAtEntity(ped, PlayerPedId(), 5500.0, 2048, 3)
    TaskTurnPedToFaceEntity(ped, PlayerPedId(), 5500)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT_UPRIGHT', 0, false)

    if hasTarget then
        while pedDist < 1.5 and not IsPedDeadOrDying(ped) do
            local coords2 = GetEntityCoords(PlayerPedId(), true)
            local pedCoords2 = GetEntityCoords(ped)
            local pedDist2 = #(coords2 - pedCoords2)
            if getRobbed <= Config.RobberyChance then
                TriggerServerEvent('qb-drugs:server:robCornerDrugs', drugType, bagAmount)
                QBCore.Functions.Notify(Lang:t('info.has_been_robbed', { bags = bagAmount, drugType = availableDrugs[drugType].label }))
                stealingPed = ped
                stealData = {
                    item = availableDrugs[drugType].item,
                    drugType = drugType,
                    amount = bagAmount,
                }
                hasTarget = false
                local moveto = GetEntityCoords(PlayerPedId())
                local movetoCoords = { x = moveto.x + math.random(100, 500), y = moveto.y + math.random(100, 500), z = moveto.z, }
                ClearPedTasksImmediately(ped)
                TaskGoStraightToCoord(ped, movetoCoords.x, movetoCoords.y, movetoCoords.z, 15.0, -1, 0.0, 0.0)
                lastPed[#lastPed + 1] = ped
                RobberyPed()
                break
            else
                if pedDist2 < 1.5 and cornerselling then
                    if Config.UseTarget and not zoneMade then
                        zoneMade = true
                        exports['qb-target']:AddEntityZone('sellingPed', ped, {
                            name = 'sellingPed',
                            debugPoly = false,
                        }, {
                            options = {
                                {
                                    icon = 'fas fa-hand-holding-dollar',
                                    label = Lang:t('info.target_drug_offer', { bags = bagAmount, drugLabel = currentOfferDrug.label, randomPrice = randomPrice }),
                                    action = function(entity)
                                        if IsPedInAnyVehicle(PlayerPedId(), false) then
                                            QBCore.Functions.Notify(Lang:t('error.in_vehicle'), 'error')
                                            hasTarget = false
                                            zoneMade = false
                                            SetPedKeepTask(entity, false)
                                            SetEntityAsNoLongerNeeded(entity)
                                            ClearPedTasksImmediately(entity)
                                            lastPed[#lastPed + 1] = entity
                                            exports['qb-target']:RemoveZone('sellingPed')
                                            return
                                        else
                                            exports['qb-target']:RemoveZone('sellingPed')
                                            QBCore.Functions.Progressbar('cornerSelling', Lang:t('info.selling_to_ped'), '5000', false, false, {
                                                disableMovement = true,
                                                disableCarMovement = true,
                                                disableMouse = false,
                                                disableCombat = false,
                                            }, {}, {}, {}, function()
                                                TriggerServerEvent('qb-drugs:server:sellCornerDrugs', drugType, bagAmount, randomPrice)
                                                hasTarget = false
                                                zoneMade = false
                                                exports['qb-target']:RemoveZone('sellingPed')
                                                LoadAnimDict('gestures@f@standing@casual')
                                                TaskPlayAnim(PlayerPedId(), 'gestures@f@standing@casual', 'gesture_point', 3.0, 3.0, -1, 49, 0, 0, 0, 0)
                                                Wait(650)
                                                ClearPedTasks(PlayerPedId())
                                                SetPedKeepTask(entity, false)
                                                SetEntityAsNoLongerNeeded(entity)
                                                ClearPedTasksImmediately(entity)
                                                lastPed[#lastPed + 1] = entity
                                                PoliceCall()
                                            end)
                                        end
                                    end,
                                },
                                {
                                    icon = 'fas fa-x',
                                    label = 'Decline offer',
                                    action = function(entity)
                                        QBCore.Functions.Notify(Lang:t('error.offer_declined'), 'error')
                                        hasTarget = false
                                        zoneMade = false
                                        SetPedKeepTask(entity, false)
                                        SetEntityAsNoLongerNeeded(entity)
                                        ClearPedTasksImmediately(entity)
                                        lastPed[#lastPed + 1] = entity
                                        exports['qb-target']:RemoveZone('sellingPed')
                                    end,
                                },
                            },
                            distance = 1.5,
                        })
                    elseif not Config.UseTarget then
                        if not textDrawn then
                            textDrawn = true
                            exports['qb-core']:DrawText(Lang:t('info.drug_offer', { bags = bagAmount, drugLabel = currentOfferDrug.label, randomPrice = randomPrice }))
                        end
                        if IsControlJustPressed(0, 38) then
                            if IsPedInAnyVehicle(PlayerPedId(), false) then
                                QBCore.Functions.Notify(Lang:t('error.in_vehicle'), 'error')
                                exports['qb-core']:KeyPressed()
                                textDrawn = false
                                hasTarget = false
                                SetPedKeepTask(ped, false)
                                SetEntityAsNoLongerNeeded(ped)
                                ClearPedTasksImmediately(ped)
                                lastPed[#lastPed + 1] = ped
                                break
                            else
                                exports['qb-core']:KeyPressed()
                                textDrawn = false
                                QBCore.Functions.Progressbar('cornerSelling', Lang:t('info.selling_to_ped'), '5000', false, false, {
                                    disableMovement = true,
                                    disableCarMovement = true,
                                    disableMouse = false,
                                    disableCombat = false,
                                }, {}, {}, {}, function()
                                    TriggerServerEvent('qb-drugs:server:sellCornerDrugs', drugType, bagAmount, randomPrice)
                                    hasTarget = false
                                    LoadAnimDict('gestures@f@standing@casual')
                                    TaskPlayAnim(PlayerPedId(), 'gestures@f@standing@casual', 'gesture_point', 3.0, 3.0, -1, 49, 0, 0, 0, 0)
                                    Wait(650)
                                    ClearPedTasks(PlayerPedId())
                                    SetPedKeepTask(ped, false)
                                    SetEntityAsNoLongerNeeded(ped)
                                    ClearPedTasksImmediately(ped)
                                    lastPed[#lastPed + 1] = ped
                                    PoliceCall()
                                end)
                            end
                        end
                        if IsControlJustPressed(0, 47) then
                            exports['qb-core']:KeyPressed()
                            textDrawn = false
                            QBCore.Functions.Notify(Lang:t('error.offer_declined'), 'error')
                            hasTarget = false
                            SetPedKeepTask(ped, false)
                            SetEntityAsNoLongerNeeded(ped)
                            ClearPedTasksImmediately(ped)
                            lastPed[#lastPed + 1] = ped
                            break
                        end
                    end
                else
                    if Config.UseTarget then
                        zoneMade = false
                        exports['qb-target']:RemoveZone('sellingPed')
                    else
                        if textDrawn then
                            exports['qb-core']:HideText()
                            textDrawn = false
                        end
                    end
                    hasTarget = false
                    SetPedKeepTask(ped, false)
                    SetEntityAsNoLongerNeeded(ped)
                    ClearPedTasksImmediately(ped)
                    lastPed[#lastPed + 1] = ped
                    break
                end
            end
            Wait(100)
        end
        Wait(math.random(4000, 7000))
    end
end

-- 生成一个买家 NPC 并走向玩家（带调试蓝点）
local function SpawnBuyerPed(playerCoords)
    local pedModel = 'a_m_m_skater_01'
    if not IsModelInCdimage(pedModel) then pedModel = 'a_m_y_stbla_02' end
    if not IsModelInCdimage(pedModel) then pedModel = 'csb_ramp_marine' end
    RequestModel(pedModel)
    local timeout = 0
    while not HasModelLoaded(pedModel) and timeout < 100 do
        Wait(0); timeout = timeout + 1
    end
    if not HasModelLoaded(pedModel) then return nil end

    local spawnPos = playerCoords + vector3(math.random(20, 40) * (math.random() > 0.5 and 1 or -1),
                                             math.random(20, 40) * (math.random() > 0.5 and 1 or -1), 0)
    local ped = CreatePed(4, GetHashKey(pedModel), spawnPos.x, spawnPos.y, spawnPos.z, 0.0, true, false)
    if ped == 0 then return nil end

    SetPedFleeAttributes(ped, 0, 0)
    SetPedCombatAttributes(ped, 46, true)
    SetPedSeeingRange(ped, 50.0)
    TaskGoStraightToCoord(ped, playerCoords.x, playerCoords.y, playerCoords.z, 1.2, -1, 0.0, 0.0)
    SetModelAsNoLongerNeeded(pedModel)

    -- 调试蓝点：在地图上标记买家位置
    local blip = AddBlipForEntity(ped)
    SetBlipSprite(blip, 1)       -- 白色方块
    SetBlipColour(blip, 3)       -- 蓝色
    SetBlipScale(blip, 0.8)
    SetBlipAsFriendly(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(_L('blip_drugs_buyer'))
    EndTextCommandSetBlipName(blip)
    SetPedIsDrunk(ped, true)     -- 让 NPC 走路摇晃更像 "瘾君子"

    return ped
end

local function ToggleSelling()
    if not cornerselling then
        cornerselling = true
        LocalPlayer.state:set('inv_busy', true, true)
        QBCore.Functions.Notify(Lang:t('info.started_selling_drugs'))
        local startLocation = GetEntityCoords(PlayerPedId())
        local noPedTimer = 0  -- 等待 NPC 计时器（秒）
        local spawnedPed = nil
        CreateThread(function()
            while cornerselling do
                local player = PlayerPedId()
                local coords = GetEntityCoords(player)

                if not hasTarget then
                    -- 先找附近已有的 NPC
                    local PlayerPeds = {}
                    for _, activePlayer in ipairs(GetActivePlayers()) do
                        local ped = GetPlayerPed(activePlayer)
                        PlayerPeds[#PlayerPeds + 1] = ped
                    end
                    local closestPed, closestDistance = QBCore.Functions.GetClosestPed(coords, PlayerPeds)
                    local foundPed = false

                    if closestDistance < 15.0 and closestPed ~= 0 and not IsPedInAnyVehicle(closestPed) and GetPedType(closestPed) ~= 28 then
                        -- 已有 NPC 在附近，直接交互
                        spawnedPed = nil
                        noPedTimer = 0
                        SellToPed(closestPed)
                        foundPed = true
                    elseif spawnedPed and DoesEntityExist(spawnedPed) then
                        -- 检查我们生成的 NPC 是否已走到附近
                        local spDist = #(coords - GetEntityCoords(spawnedPed))
                        if spDist < 3.0 then
                            local buyer = spawnedPed
                            spawnedPed = nil
                            noPedTimer = 0
                            SellToPed(buyer)
                            foundPed = true
                        end
                    end

                    if not foundPed then
                        noPedTimer = noPedTimer + 1
                        if noPedTimer >= 50 then  -- 50 ticks × 200ms = 10 秒
                            noPedTimer = 0
                            if not spawnedPed or not DoesEntityExist(spawnedPed) then
                                spawnedPed = SpawnBuyerPed(coords)
                                if spawnedPed then
                                    QBCore.Functions.Notify("有个鬼鬼祟祟的人正在靠近你...", "primary")
                                end
                            end
                        end
                    end
                end

                local startDist = #(startLocation - coords)
                if startDist > 10 then
                    if spawnedPed and DoesEntityExist(spawnedPed) then
                        DeleteEntity(spawnedPed)
                        spawnedPed = nil
                    end
                    TooFarAway()
                end
                Wait(200)
            end
        end)
    else
        stealingPed = nil
        stealData = {}
        if spawnedPed and DoesEntityExist(spawnedPed) then
            DeleteEntity(spawnedPed)
        end
        cornerselling = false
        LocalPlayer.state:set('inv_busy', false, true)
        QBCore.Functions.Notify(Lang:t('info.stopped_selling_drugs'))
    end
end

-- Events
RegisterNetEvent('qb-drugs:client:cornerselling', function()
    QBCore.Functions.TriggerCallback('qb-drugs:server:cornerselling:getAvailableDrugs', function(result)
        if CurrentCops >= Config.MinimumDrugSalePolice then
            if IsPedInAnyVehicle(PlayerPedId(), false) then
                QBCore.Functions.Notify(Lang:t('error.in_vehicle'), 'error')
            else
                if result then
                    availableDrugs = result
                    ToggleSelling()
                else
                    QBCore.Functions.Notify(Lang:t('error.has_no_drugs'), 'error')
                    LocalPlayer.state:set('inv_busy', false, true)
                end
            end
        else
            QBCore.Functions.Notify(Lang:t('error.not_enough_police', { polices = Config.MinimumDrugSalePolice }), 'error')
        end
    end)
end)

RegisterNetEvent('police:SetCopCount', function(amount)
    CurrentCops = amount
end)

RegisterNetEvent('qb-drugs:client:refreshAvailableDrugs', function(items)
    availableDrugs = items
    if availableDrugs == nil or #availableDrugs <= 0 then
        QBCore.Functions.Notify(Lang:t('error.no_drugs_left'), 'error')
        cornerselling = false
        LocalPlayer.state:set('inv_busy', false, true)
    end
end)
