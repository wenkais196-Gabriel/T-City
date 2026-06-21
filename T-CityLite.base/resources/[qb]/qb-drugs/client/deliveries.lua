QBCore = exports['qb-core']:GetCoreObject()
local currentDealer = nil
local dealerIsHome = false
local waitingDelivery = nil
local activeDelivery = nil
local deliveryTimeout = 0
local waitingKeyPress = false
local dealerCombo = nil
local drugDeliveryZone

-- Handlers
AddStateBagChangeHandler('isLoggedIn', nil, function(_, _, value)
    if value then
        QBCore.Functions.TriggerCallback('qb-drugs:server:RequestConfig', function(DealerConfig)
            Config.Dealers = DealerConfig
        end)
        Wait(1000)
        InitZones()
    else
        if not Config.UseTarget and dealerCombo then dealerCombo:destroy() end
    end
end)

-- ============================================================
--  辅助函数
-- ============================================================
local function GetClosestDealer()
    local ped = PlayerPedId()
    local pCoords = GetEntityCoords(ped)
    for k, v in pairs(Config.Dealers) do
        if #(pCoords - vector3(v.coords.x, v.coords.y, v.coords.z)) < 2 then
            currentDealer = k
            break
        end
    end
end

local function KnockDoorAnim(home)
    local knockAnimLib = 'timetable@jimmy@doorknock@'
    local knockAnim = 'knockdoor_idle'
    local PlayerPed = PlayerPedId()
    local myData = QBCore.Functions.GetPlayerData()
    if home then
        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'knock_door', 0.2)
        Wait(100)
        while not HasAnimDictLoaded(knockAnimLib) do RequestAnimDict(knockAnimLib) Wait(100) end
        TaskPlayAnim(PlayerPed, knockAnimLib, knockAnim, 3.0, 3.0, -1, 1, 0, false, false, false)
        Wait(3500)
        TaskPlayAnim(PlayerPed, knockAnimLib, 'exit', 3.0, 3.0, -1, 1, 0, false, false, false)
        Wait(1000)
        dealerIsHome = true
        TriggerEvent('chat:addMessage', { color = { 255, 0, 0 }, multiline = true, args = {
            Lang:t('info.dealer_name', { dealerName = Config.Dealers[currentDealer]['name'] }),
            Lang:t('info.fred_knock_message', { firstName = myData.charinfo.firstname })
        }})
        if not Config.UseTarget then
            exports['qb-core']:DrawText(Lang:t('info.other_dealers_button'), 'left')
            AwaitingInput()
        end
    -- 非营业时间已移除通知：由 KnockDealerDoor 静默处理
end
end

-- 判断指定经销商当前是否在营业时间内 (跨夜兼容)
local function DealerIsOpen(dealerName)
    local dealer = Config.Dealers[dealerName]
    if not dealer or not dealer.time then return false end
    local hours = GetClockHours()
    local min = dealer.time.min
    local max = dealer.time.max
    if max < min then
        return hours <= max or hours >= min   -- 跨夜营业 (例: 22:00-04:00)
    else
        return hours >= min and hours <= max  -- 同日营业 (例: 10:00-18:00)
    end
end

local function KnockDealerDoor()
    GetClosestDealer()
    if DealerIsOpen(currentDealer) then
        KnockDoorAnim(true)
    end
    -- 非营业时间静默返回：目标可见但无交互反馈，玩家自行探索营业时段
end

local function RandomDeliveryItemOnRep()
    local myRep = QBCore.Functions.GetPlayerData().metadata['rep']['dealer'] or 0
    local availableItems = {}
    for k, _ in pairs(Config.DeliveryItems) do
        if Config.DeliveryItems[k]['minrep'] <= myRep then
            availableItems[#availableItems + 1] = k
        end
    end
    return availableItems[math.random(1, #availableItems)]
end

-- ============================================================
--  核心配送函数（按依赖顺序: Cleanup → Timer → Deliver → Request）
-- ============================================================
local function CleanupDelivery()
    waitingDelivery = nil
    activeDelivery = nil
    deliveryTimeout = 0
    exports['qb-hud']:HideTaskTimer()
    SetWaypointOff()
    if Config.UseTarget then exports['qb-target']:RemoveZone('drugDeliveryZone')
    elseif drugDeliveryZone then drugDeliveryZone:destroy() end
end

local function DeliveryTimer()
    CreateThread(function()
        local startTime = GetGameTimer()
        local fastTime = activeDelivery and activeDelivery['fastTime'] or 300
        local maxTime = activeDelivery and activeDelivery['maxTime'] or 600
        while deliveryTimeout > 0 and activeDelivery do
            deliveryTimeout = deliveryTimeout - 1
            local elapsed = math.floor((GetGameTimer() - startTime) / 1000)
            local mins = math.floor(deliveryTimeout / 60)
            local secs = deliveryTimeout % 60
            -- 阶段判定 + 简洁 NUI 计时器
            local phase
            if elapsed <= fastTime then
                phase = 'fast'
            elseif elapsed <= maxTime then
                phase = 'normal'
            else
                phase = 'overtime'
            end
            exports['qb-hud']:ShowTaskTimer(mins, secs, phase)
            Wait(1000)
        end
        exports['qb-hud']:HideTaskTimer()
        deliveryTimeout = 0
        if waitingDelivery then
            QBCore.Functions.Notify('⏰ 送货超时！押金和货物已损失', 'error')
            TriggerServerEvent('qb-drugs:server:failDelivery', activeDelivery or waitingDelivery)
            CleanupDelivery()
        end
    end)
end

local function PoliceCall()
    if math.random(1, 100) <= Config.PoliceCallChance then
        TriggerServerEvent('police:server:policeAlert', 'Suspicous activity')
    end
end

local function DeliverStuff()
    if not activeDelivery then return end
    local startMs = activeDelivery['startTime'] or 0
    local elapsed = startMs > 0 and math.floor((GetGameTimer() - startMs) / 1000) or 0
    if deliveryTimeout > 0 then
        Wait(500)
        TaskStartScenarioInPlace(PlayerPedId(), 'PROP_HUMAN_BUM_BIN', 0, true)
        PoliceCall()
        QBCore.Functions.Progressbar('work_dropbox', Lang:t('info.delivering_products'), 3500, false, true, {
            disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true,
        }, {}, {}, {},
            function() -- Done
                TriggerServerEvent('qb-drugs:server:successDelivery', activeDelivery, true, elapsed)
                CleanupDelivery()
            end,
            function() -- Cancel/ESC
                ClearPedTasks(PlayerPedId())
                QBCore.Functions.Notify('🚫 送货已取消，押金不退还', 'error')
                TriggerServerEvent('qb-drugs:server:failDelivery', activeDelivery)
                CleanupDelivery()
            end)
    else
        TriggerServerEvent('qb-drugs:server:successDelivery', activeDelivery, false, elapsed)
        CleanupDelivery()
    end
end

local function SetMapBlip(x, y)
    SetNewWaypoint(x, y)
    QBCore.Functions.Notify(Lang:t('success.route_has_been_set'), 'success')
end

local function RequestDelivery()
    if waitingDelivery or activeDelivery then
        QBCore.Functions.Notify(Lang:t('error.pending_delivery'), 'error')
        return
    end
    GetClosestDealer()
    local amount = 1  -- 固定每次交付 1 个物品，统一数量
    local item = RandomDeliveryItemOnRep()
    local locationIdx = math.random(1, #Config.DeliveryLocations)
    local targetLoc = Config.DeliveryLocations[locationIdx]
    local playerCoords = GetEntityCoords(PlayerPedId())
    local distance = #(playerCoords - targetLoc['coords'])
    local baseTime = math.ceil(distance / Config.DeliveryAvgSpeed) + Config.DeliveryFixedTime
    local fastTime = math.ceil(baseTime * Config.DeliveryFastMult)
    local maxTime = math.ceil(baseTime * Config.DeliveryLateMult)
    local basePayout = Config.DeliveryItems[item]['payout'] * amount
    local deposit = math.ceil(basePayout * Config.DeliveryDepositRate)

    waitingDelivery = {
        ['coords'] = targetLoc['coords'], ['locationLabel'] = targetLoc['label'],
        ['amount'] = amount, ['dealer'] = currentDealer,
        ['itemData'] = Config.DeliveryItems[item], ['item'] = item,
        ['distance'] = distance, ['baseTime'] = baseTime,
        ['fastTime'] = fastTime, ['maxTime'] = maxTime,
        ['deposit'] = deposit, ['basePayout'] = basePayout,
    }

    QBCore.Functions.Notify(
        ('📦 配送距离: %.0fm | 押金: $%d | 快速窗口: %ds'):format(distance, deposit, fastTime),
        'primary', 5000)
    TriggerServerEvent('qb-drugs:server:acceptDelivery', waitingDelivery)

    SetTimeout(2000, function()
        if not activeDelivery then
            activeDelivery = waitingDelivery
            activeDelivery['startTime'] = GetGameTimer()
            deliveryTimeout = waitingDelivery['maxTime'] or 300
            DeliveryTimer()
            SetNewWaypoint(activeDelivery['coords'].x, activeDelivery['coords'].y)
            if Config.UseTarget then
                exports['qb-target']:AddBoxZone('drugDeliveryZone',
                    vector3(activeDelivery['coords'].x, activeDelivery['coords'].y, activeDelivery['coords'].z),
                    1.5, 1.5, {
                        name = 'drugDeliveryZone', heading = 0,
                        minZ = activeDelivery['coords'].z - 1, maxZ = activeDelivery['coords'].z + 1, debugPoly = false
                    }, {
                        options = {{
                            icon = 'fas fa-user-secret', label = Lang:t('info.target_deliver'),
                            action = function() DeliverStuff() waitingDelivery = nil end,
                            canInteract = function() return waitingDelivery ~= nil end
                        }}, distance = 1.5
                    })
            end
        end
        local loc = waitingDelivery['coords']
        local itemLabel = QBCore.Shared.Items[waitingDelivery['itemData']['item']]['label']
        local locLabel = waitingDelivery['locationLabel'] or 'Drop-off'
        local msg = ('📦 配送: %s x%d\n📍 %s | 📏 %.0fm\n⏱️ 快速:%ds 超时:%ds\n💰 押金:$%d'):format(
            itemLabel, amount, locLabel, distance, fastTime, maxTime, deposit)
        TriggerServerEvent('qb-drugs:server:sendDeliverySMS', msg,
            { x = loc.x, y = loc.y, label = locLabel }, 'active')
    end)
end

-- ============================================================
--  PolyZone 交互
-- ============================================================
function AwaitingInput()
    CreateThread(function()
        waitingKeyPress = true
        while waitingKeyPress do
            if not dealerIsHome then
                if IsControlPressed(0, 38) then
                    exports['qb-core']:KeyPressed()
                    KnockDealerDoor()
                end
            elseif dealerIsHome then
                if IsControlJustPressed(0, 38) then
                    GetClosestDealer()
                    TriggerServerEvent('qb-drugs:server:dealerShop', currentDealer)
                    exports['qb-core']:KeyPressed()
                    waitingKeyPress = false
                end
                if IsControlJustPressed(0, 47) then
                    if waitingDelivery then
                        exports['qb-core']:KeyPressed()
                        waitingKeyPress = false
                    end
                    RequestDelivery()
                    exports['qb-core']:KeyPressed()
                    dealerIsHome = false
                    waitingKeyPress = false
                end
            end
            Wait(0)
        end
    end)
end

function InitZones()
    if next(Config.Dealers) == nil then return end
    if Config.UseTarget then
        for k, v in pairs(Config.Dealers) do
            exports['qb-target']:AddBoxZone('dealer_' .. k, vector3(v.coords.x, v.coords.y, v.coords.z), 1.5, 1.5, {
                name = 'dealer_' .. k, heading = v.heading,
                minZ = v.coords.z - 1, maxZ = v.coords.z + 1, debugPoly = false,
            }, {
                options = {
                    {
                        icon = 'fas fa-user-secret', label = Lang:t('info.target_request'),
                        action = function()
                            GetClosestDealer()
                            KnockDealerDoor()
                            if dealerIsHome then RequestDelivery() end
                        end,
                        canInteract = function()
                            GetClosestDealer()
                            if waitingDelivery or activeDelivery then return false end
                            -- 非营业时间显示目标但不出现菜单，让玩家自行探索
                            return DealerIsOpen(currentDealer)
                        end
                    },
                    {
                        icon = 'fas fa-user-secret', label = Lang:t('info.target_openshop'),
                        action = function()
                            GetClosestDealer()
                            TriggerServerEvent('qb-drugs:server:dealerShop', currentDealer)
                        end,
                        canInteract = function()
                            GetClosestDealer()
                            -- 非营业时间显示目标但不出现菜单，让玩家自行探索
                            return DealerIsOpen(currentDealer)
                        end
                    }
                }, distance = 1.5
            })
        end
    else
        local dealerPoly = {}
        for k, v in pairs(Config.Dealers) do
            dealerPoly[#dealerPoly + 1] = BoxZone:Create(vector3(v.coords.x, v.coords.y, v.coords.z), 1.5, 1.5, {
                heading = -20, name = 'dealer_' .. k, debugPoly = false,
                minZ = v.coords.z - 1, maxZ = v.coords.z + 1,
            })
        end
        dealerCombo = ComboZone:Create(dealerPoly, { name = 'dealerPoly' })
        if not dealerCombo then return end
        dealerCombo:onPlayerInOut(function(isPointInside)
            if isPointInside then
                if not dealerIsHome then
                    exports['qb-core']:DrawText(Lang:t('info.knock_button'), 'left')
                    AwaitingInput()
                elseif dealerIsHome then
                    exports['qb-core']:DrawText(Lang:t('info.other_dealers_button'), 'left')
                    AwaitingInput()
                end
            else
                waitingKeyPress = false
                exports['qb-core']:HideText()
            end
        end)
    end
end

-- ============================================================
--  事件
-- ============================================================
RegisterNetEvent('qb-drugs:client:RefreshDealers', function(DealerData)
    if not Config.UseTarget and dealerCombo then dealerCombo:destroy() end
    Config.Dealers = DealerData
    Wait(1000)
    InitZones()
end)

RegisterNetEvent('qb-drugs:client:updateDealerItems', function(itemData, amount)
    TriggerServerEvent('qb-drugs:server:updateDealerItems', itemData, amount, currentDealer)
end)

RegisterNetEvent('qb-drugs:client:setDealerItems', function(itemData, amount, dealer)
    Config.Dealers[dealer]['products'][itemData.slot].amount = Config.Dealers[dealer]['products'][itemData.slot].amount - amount
end)

RegisterNetEvent('qb-drugs:client:setLocation', function(locationData)
    if activeDelivery then
        SetMapBlip(activeDelivery['coords']['x'], activeDelivery['coords']['y'])
        QBCore.Functions.Notify(Lang:t('error.pending_delivery'), 'error')
        return
    end
    activeDelivery = locationData
    activeDelivery['startTime'] = GetGameTimer()
    deliveryTimeout = locationData['maxTime'] or 300
    DeliveryTimer()
    SetMapBlip(activeDelivery['coords'].x, activeDelivery['coords'].y)
    if Config.UseTarget then
        exports['qb-target']:AddBoxZone('drugDeliveryZone',
            vector3(activeDelivery['coords'].x, activeDelivery['coords'].y, activeDelivery['coords'].z),
            1.5, 1.5, {
                name = 'drugDeliveryZone', heading = 0,
                minZ = activeDelivery['coords'].z - 1, maxZ = activeDelivery['coords'].z + 1, debugPoly = false
            }, {
                options = {{
                    icon = 'fas fa-user-secret', label = Lang:t('info.target_deliver'),
                    action = function() DeliverStuff() waitingDelivery = nil end,
                    canInteract = function() return waitingDelivery ~= nil end
                }}, distance = 1.5
            })
    else
        drugDeliveryZone = BoxZone:Create(
            vector3(activeDelivery['coords'].x, activeDelivery['coords'].y, activeDelivery['coords'].z),
            1.5, 1.5, { heading = 0, name = 'drugDelivery', debugPoly = false,
                minZ = activeDelivery['coords'].z - 1, maxZ = activeDelivery['coords'].z + 1 })
        drugDeliveryZone:onPlayerInOut(function(isPointInside)
            if isPointInside then
                local inDeliveryZone = true
                exports['qb-core']:DrawText(Lang:t('info.deliver_items_button', {
                    itemAmount = activeDelivery['amount'],
                    itemLabel = QBCore.Shared.Items[activeDelivery['itemData']['item']]['label']
                }), 'left')
                CreateThread(function()
                    while inDeliveryZone do
                        if IsControlJustPressed(0, 38) then
                            exports['qb-core']:KeyPressed()
                            DeliverStuff()
                            waitingDelivery = nil
                            break
                        end
                        Wait(0)
                    end
                end)
            else
                inDeliveryZone = false
                exports['qb-core']:HideText()
            end
        end)
    end
end)

RegisterNetEvent('qb-drugs:client:sendDeliveryMail', function(type, deliveryData)
    local dealerName = deliveryData['dealer'] and Config.Dealers[deliveryData['dealer']]
        and Config.Dealers[deliveryData['dealer']]['name'] or 'Unknown'
    local msg
    if type == 'perfect' then msg = Lang:t('info.perfect_delivery', { dealerName = dealerName })
    elseif type == 'bad' then msg = Lang:t('info.bad_delivery')
    elseif type == 'late' then msg = Lang:t('info.late_delivery') end
    if msg then TriggerServerEvent('qb-drugs:server:sendDeliverySMS', msg) end
end)

-- ============================================================
--  调试命令
-- ============================================================
RegisterCommand('deliverydebug', function()
    print('========== 配送状态调试 ==========')
    print('waitingDelivery: ' .. (waitingDelivery and ('active: ' .. (waitingDelivery['locationLabel'] or '?')) or 'nil'))
    print('activeDelivery:  ' .. (activeDelivery and ('active: ' .. (activeDelivery['locationLabel'] or '?')) or 'nil'))
    print('deliveryTimeout: ' .. tostring(deliveryTimeout))
    print('dealerIsHome:    ' .. tostring(dealerIsHome))
    print('currentDealer:   ' .. tostring(currentDealer))
    print('输入 /deliveryreset 强制重置配送状态')
end, false)

RegisterCommand('deliveryreset', function()
    waitingDelivery = nil; activeDelivery = nil; deliveryTimeout = 0; dealerIsHome = false
    exports['qb-hud']:HideTaskTimer()
    exports['qb-core']:HideText()
    if Config.UseTarget then pcall(function() exports['qb-target']:RemoveZone('drugDeliveryZone') end) end
    QBCore.Functions.Notify('🔧 配送状态已强制重置', 'success')
    print('[qb-drugs] 配送状态已强制重置')
end, false)

RegisterNetEvent('qb-drugs:client:updateRepBar', function(rank, rp)
    local nextRank = rank + 1
    QBCore.Functions.Notify(('🌟 毒贩声望 Lv.%d | 进度 %d/%d'):format(rank, rp, nextRank * 10), 'primary', 5000)
end)
