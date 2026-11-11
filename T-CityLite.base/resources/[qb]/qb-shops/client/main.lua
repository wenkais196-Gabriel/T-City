local QBCore = exports['qb-core']:GetCoreObject()
local currentShop, playerData
local pedSpawned = false
local listen = false
local ShopPed = {}
local NewZones = {}

-- Functions

local function createBlips()
    if pedSpawned then return end

    for store in pairs(Config.Locations) do
        if Config.Locations[store]['showblip'] then
            local StoreBlip = AddBlipForCoord(Config.Locations[store]['coords']['x'], Config.Locations[store]['coords']['y'], Config.Locations[store]['coords']['z'])
            SetBlipSprite(StoreBlip, Config.Locations[store]['blipsprite'])
            SetBlipScale(StoreBlip, Config.Locations[store]['blipscale'])
            SetBlipDisplay(StoreBlip, 4)
            SetBlipColour(StoreBlip, Config.Locations[store]['blipcolor'])
            SetBlipAsShortRange(StoreBlip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(Config.Locations[store]['label'])
            EndTextCommandSetBlipName(StoreBlip)
        end
    end
end

local function listenForControl()
    if listen then return end
    CreateThread(function()
        listen = true
        while listen do
            if IsControlJustPressed(0, 38) then -- E
                exports['qb-core']:KeyPressed()
                TriggerServerEvent('qb-shops:server:openShop', { shop = currentShop })
                listen = false
                break
            end
            Wait(0)
        end
    end)
end

local function createPeds()
    if pedSpawned then return end
    local defaultTargetIcon = 'fas fa-shopping-cart'
    local defaultTargetLabel = 'Open Shop'

    for k, v in pairs(Config.Locations) do
        if not v.ped then
            -- E-1：这里原本是 qb-target 的 AddCircleZone（长按 ALT 开商店）。
            -- 一个柜台只有一个动作，按 D2 应该是 [E]；入口统一到文件末尾的商铺提示循环。
        else
            local current = type(v['ped']) == 'number' and v['ped'] or joaat(v['ped'])
            RequestModel(current)
            while not HasModelLoaded(current) do Wait(0) end
            ShopPed[k] = CreatePed(0, current, v['coords'].x, v['coords'].y, v['coords'].z - 1, v['coords'].w, false, false)
            TaskStartScenarioInPlace(ShopPed[k], v['scenario'], 0, true)
            FreezeEntityPosition(ShopPed[k], true)
            SetEntityInvincible(ShopPed[k], true)
            SetBlockingOfNonTemporaryEvents(ShopPed[k], true)
            -- E-1：店员身上的 ALT 选项也去掉了 —— 同一个柜台有两套入口，
            -- 玩家会撞见两种价格/两种交互；现在统一走 [E] 提示循环。
        end
    end
    pedSpawned = true
end

local function deletePeds()
    if not pedSpawned then return end
    for _, v in pairs(ShopPed) do
        DeletePed(v)
    end
    pedSpawned = false
end

local function tableCheck(inputValue, requiredValue)
    local playerJob = inputValue.job.name
    local playerJobGrade = inputValue.job.grade.level
    local playerGang = inputValue.gang.name
    local playerGangGrade = inputValue.gang.grade.level
    local shopData = Config.Locations[requiredValue]

    local jobCheck = false
    local gangCheck = false
    local itemCheck = false

    if shopData.requiredJob then
        if type(shopData.requiredJob) == 'table' then
            for job, grade in pairs(shopData.requiredJob) do
                if playerJob == job and playerJobGrade >= grade then
                    jobCheck = true
                    break
                end
            end
        elseif playerJob == shopData.requiredJob then
            jobCheck = true
        end
    else
        jobCheck = true
    end

    if shopData.requiredGang then
        if type(shopData.requiredGang) == 'table' then
            for gang, grade in pairs(shopData.requiredGang) do
                if playerGang == gang and playerGangGrade >= grade then
                    gangCheck = true
                    break
                end
            end
        elseif playerGang == shopData.requiredGang then
            gangCheck = true
        end
    else
        gangCheck = true
    end

    if shopData.requiredItem then
        itemCheck = exports['qb-inventory']:HasItem(shopData.requiredItem)
    else
        itemCheck = true
    end

    return jobCheck and gangCheck and itemCheck
end

-- Events

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    playerData = QBCore.Functions.GetPlayerData()
    createBlips()
    createPeds()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    playerData = {}
    deletePeds()
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(jobInfo)
    playerData.job = jobInfo
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    playerData = QBCore.Functions.GetPlayerData()
    createBlips()
    createPeds()
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    deletePeds()
end)

-- Threads
-- E-1：原本这里有两条路（UseTarget=true 走 ALT；false 走 qb-core 的 DrawText 黑条）。
-- 现在两条都并到下面的统一 [E] 提示循环，所以这段不再启动。
if false then
    CreateThread(function()
        for shop in pairs(Config.Locations) do
            NewZones[#NewZones + 1] = CircleZone:Create(vector3(Config.Locations[shop]['coords']['x'], Config.Locations[shop]['coords']['y'], Config.Locations[shop]['coords']['z']), Config.Locations[shop]['radius'] or 1.5, {
                useZ = true,
                debugPoly = false,
                name = shop,
            })
        end

        local combo = ComboZone:Create(NewZones, { name = 'RandomZOneName', debugPoly = false })
        combo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside then
                if tableCheck(playerData, zone.name) then
                    currentShop = zone.name
                    exports['qb-core']:DrawText(Lang:t('info.open_shop'))
                    listenForControl()
                end
            else
                exports['qb-core']:HideText()
                listen = false
            end
        end)
    end)
end

-- ==============================================================
-- E-1：商铺统一 [E] 入口
--   * 去掉 qb-target 的 ALT 区域/实体选项（原来同一个柜台有两套入口）；
--   * 去掉 qb-core 的 DrawText 黑条（那是另一套视觉）；
--   * 权限判定仍在服务端（qb-shops:server:openShop 会校验距离与职业/帮派），
--     这里只负责"显示 + 按 E"。
-- ==============================================================
local SHOP_PROMPT_RANGE = 2.0
local shopPromptShown = false

CreateThread(function()
    Wait(1500)
    while true do
        local sleep = 800
        local pos = GetEntityCoords(PlayerPedId())
        local nearest, nearestDist = nil, SHOP_PROMPT_RANGE

        for key, shop in pairs(Config.Locations) do
            local coords = shop.coords
            if coords then
                local dist = #(pos - vector3(coords.x, coords.y, coords.z))
                if dist < nearestDist then nearest, nearestDist = key, dist end
            end
        end

        if nearest then
            sleep = 200
            local shop = Config.Locations[nearest]
            local label = shop.targetLabel or '打开商店'
            exports['custom-prompt']:Show({ key = 'E', label = label })
            shopPromptShown = true
            if IsControlJustReleased(0, 38) then
                exports['custom-prompt']:Hide()
                shopPromptShown = false
                TriggerServerEvent('qb-shops:server:openShop', { shop = nearest })
                sleep = 1200
            end
        elseif shopPromptShown then
            exports['custom-prompt']:Hide()
            shopPromptShown = false
        end

        Wait(sleep)
    end
end)
