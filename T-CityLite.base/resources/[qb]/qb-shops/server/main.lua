local QBCore = exports['qb-core']:GetCoreObject()

-- qb-core 重启后，上面这份快照里的函数引用会全部失效（P1-6，PR #196）：
-- 本资源没有声明 qb-core 依赖，不会被重启级联带走，所以在 qb-core 起来时重解析一次。
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'qb-core' then return end
    -- ⚠️ 不能在事件里同步调：真机实测此刻 export 引用可能还指向 qb-core 旧 script host，
    -- 会抛 `Execution of function reference in script host failed`。放线程里重试到拿到新表。
    CreateThread(function()
        for _ = 1, 30 do
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
                return
            end
            Wait(500)
        end
    end)
end)
local Bail = {}

-- Functions

local function checkTable(inputValue, requiredValue)
    if type(inputValue) == 'table' and type(requiredValue) == 'table' then
        for _, v in ipairs(requiredValue) do
            if inputValue[v] then return true end
        end
    elseif type(requiredValue) == 'table' then
        for _, v in ipairs(requiredValue) do
            if v == inputValue then return true end
        end
    elseif type(inputValue) == 'string' and type(requiredValue) == 'string' then
        return inputValue == requiredValue
    elseif type(inputValue) == 'table' and type(requiredValue) == 'string' then
        return inputValue[requiredValue] == true
    elseif type(inputValue) == 'string' and type(requiredValue) == 'table' then
        for _, v in ipairs(requiredValue) do
            if v == inputValue then return true end
        end
    end

    return false
end

-- 📊 动态定价: 读取 NPCPricing 引擎或 economy_baseline 的实时价格
---@param itemName string
---@param basePrice number
---@return number dynamicPrice
local function getDynamicPrice(itemName, basePrice)
    -- 优先使用 NPCPricing 引擎 (NPC 动态定价)
    if _G.Bus and _G.Bus.NPCPricing then
        return _G.Bus.NPCPricing.GetBuyPrice(itemName, basePrice)
    end
    -- Fallback: 使用全局经济乘数
    local globalMult = 1.0
    if exports['core_economy'] then
        globalMult = exports['core_economy']:GetGlobalMultiplier()
    else
        globalMult = GetConvarFloat('economy_reward_scale', 1.0)
        -- 与 core_economy 同语义：0 / 负数 / NaN 当作「没配」，否则会把商品刷成免费或整屏 NaN
        if not (globalMult > 0) then globalMult = 1.0 end
    end
    return math.floor(basePrice * globalMult + 0.5)
end

local function saveShopInv(shop, products)
    local shopinv = {}
    shopinv[shop] = {}
    shopinv[shop].products = products
    SaveResourceFile(GetCurrentResourceName(), Config.ShopsInvJsonFile, json.encode(shopinv), -1)
end

-- 补货/工资这类"跑到点就发钱"的 handler 必须自带冷却：
-- 客户端跑完一趟才发一次，但事件本身谁都能发，站在交货点循环调用就是印钞机。
local RESTOCK_COOLDOWN_MS = 30000
local LastRestock = {}

local function nearCoords(source, coords, maxDistance)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return false end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local playerCoords = GetEntityCoords(ped)
    return #(playerCoords - vector3(coords.x, coords.y, coords.z)) <= maxDistance
end

local function deliveryPay(source, shop)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    local deliverCoords = Config.Locations[shop].delivery
    local distance = #(playerCoords - vector3(deliverCoords.x, deliverCoords.y, deliverCoords.z))
    if distance > 10 then return end
    Player.Functions.AddMoney('bank', Config.DeliveryPrice, 'qb-shops:deliveryPay')
    if math.random(100) <= 10 then exports['qb-inventory']:AddItem(source, Config.RewardItem, 1, false, false, 'qb-shops:deliveryPay') end
end

-- Events

-- Deliveries

RegisterNetEvent('qb-shops:server:RestockShopItems', function(shop)
    local src = source
    if type(shop) ~= 'string' then return end
    local location = Config.Locations[shop]
    if type(location) ~= 'table' then return end

    -- 一次交货一条钱：同一玩家 30 秒内只认一条（原来站交货点循环发就能无限刷 DeliveryPrice）
    local now = GetGameTimer()
    if LastRestock[src] and (now - LastRestock[src]) < RESTOCK_COOLDOWN_MS then return end
    -- 交货点距离（deliveryPay 内部也有一次，但它是"不付钱就 return"，闸门认不出这是守卫）
    if not nearCoords(src, location.delivery, 10.0) then return end
    LastRestock[src] = now

    deliveryPay(src, shop)
    if not Config.Locations[shop].useStock then return end
    local randAmount = math.random(10, 50)
    for k in pairs(Config.Locations[shop].products) do Config.Locations[shop].products[k].amount = Config.Locations[shop].products[k].amount + randAmount end
    saveShopInv(shop, Config.Locations[shop].products)
    TriggerClientEvent('qb-shops:client:SetShopItems', -1, shop, Config.Locations[shop].products)
end)

RegisterNetEvent('qb-shops:server:UpdateShopItems', function(shop, itemData, amount) -- called from inventory
    -- itemData / amount 都来自客户端：`itemData.slot` 必须是该店真实存在的商品下标，
    -- amount 必须是正整数（负数会把库存加上去 = 白拿货）。
    if type(shop) ~= 'string' or type(itemData) ~= 'table' then return end
    local location = Config.Locations[shop]
    if type(location) ~= 'table' or not location.useStock then return end
    local slot = tonumber(itemData.slot)
    if not slot or not location.products[slot] then return end
    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    if amount > 1000 then amount = 1000 end
    Config.Locations[shop].products[slot].amount = Config.Locations[shop].products[slot].amount - math.floor(amount)
    if Config.Locations[shop].products[itemData.slot].amount < 0 then
        Config.Locations[shop].products[itemData.slot].amount = 0
    end
    saveShopInv(shop, Config.Locations[shop].products)
    TriggerClientEvent('qb-shops:client:SetShopItems', -1, shop, Config.Locations[shop].products)
end)

RegisterNetEvent('qb-shops:server:DoBail', function(bool)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(bool) ~= 'boolean' then return end
    if bool then
        if Player.Functions.RemoveMoney('cash', Config.TruckDeposit, 'tow-received-bail') then
            Bail[Player.PlayerData.citizenid] = Config.TruckDeposit
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.paid_with_cash', { value = Config.TruckDeposit }), 'success')
            TriggerClientEvent('qb-shops:client:SpawnVehicle', src)
        elseif Player.Functions.RemoveMoney('bank', Config.TruckDeposit, 'tow-received-bail') then
            Bail[Player.PlayerData.citizenid] = Config.TruckDeposit
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.paid_with_bank', { value = Config.TruckDeposit }), 'success')
            TriggerClientEvent('qb-shops:client:SpawnVehicle', src)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_deposit', { value = Config.TruckDeposit }), 'error')
        end
    else
        if Bail[Player.PlayerData.citizenid] then
            Player.Functions.AddMoney('cash', Bail[Player.PlayerData.citizenid], 'trucker-bail-paid')
            Bail[Player.PlayerData.citizenid] = nil
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.refund_to_cash', { value = Config.TruckDeposit }), 'success')
        end
    end
end)

RegisterNetEvent('qb-shops:server:PaySlip', function(drops)
    -- 全仓没有任何客户端调用点（deliveries.lua 只发 RestockShopItems / DoBail），
    -- 而这里按客户端给的 drops 直接 AddMoney：站在交货点发 PaySlip(99999) 就是 500 * 99999 的印钞机。
    -- 既然没人用，就只认服务端来源。
    if source ~= 0 then return end
    local src = source
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local coords = Config.DeliveryLocations['main'].coords
    local distance = #(playerCoords - vector3(coords.x, coords.y, coords.z))
    if distance > 10 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local completedDrops = tonumber(drops)
    if not drops then return end
    local payment = Config.DeliveryPrice * completedDrops
    Player.Functions.AddMoney('bank', payment, 'trucker-salary')
    Player.Functions.AddRep('delivery', completedDrops)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.you_earned', { value = payment }), 'success')
end)

-- Opening shops

RegisterNetEvent('qb-shops:server:openShop', function(data)
    local src = source
    -- data 为 nil / 非表时 `data.shop` 会直接抛错打断事件线程
    if type(data) ~= 'table' or type(data.shop) ~= 'string' then return end
    local shopName = data.shop
    local shopData = Config.Locations[shopName]
    if type(shopData) ~= 'table' then return end
    -- 只允许打开自己身边这家店的界面（原来可以在任意位置开任意店）
    if not nearCoords(src, shopData.coords, 5.0) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerData = Player.PlayerData
    local products = shopData.products
    local items = {}

    if shopData.useStock then
        local shopInvJson = json.decode(LoadResourceFile(GetCurrentResourceName(), Config.ShopsInvJsonFile))
        if shopInvJson[shopName] then
            for k, v in pairs(shopInvJson[shopName].products) do
                if products[k] then
                    products[k].amount = v.amount
                end
            end
        end
    end

    for i = 1, #products do
        local curProduct = products[i]
        local addProduct = true

        if curProduct.requiredGrade and playerData.job.grade.level < curProduct.requiredGrade then
            addProduct = false
        end

        if addProduct and curProduct.requiredJob and not checkTable(playerData.job.name, curProduct.requiredJob) then
            addProduct = false
        end

        if addProduct and curProduct.requiredGang and not checkTable(playerData.gang.name, curProduct.requiredGang) then
            addProduct = false
        end

        if addProduct and curProduct.requiredLicense and not checkTable(playerData.metadata['licences'], curProduct.requiredLicense) then
            addProduct = false
        end

        if addProduct then
            curProduct.slot = #items + 1
            -- 📊 动态定价: 基础价格 × 全局乘数 × 供需热度
            curProduct.price = getDynamicPrice(curProduct.name, curProduct.price)
            items[#items + 1] = curProduct
        end
    end

    exports['qb-inventory']:CreateShop({
        name = shopName,
        label = shopData.label,
        slots = shopData.slots,
        coords = shopData.coords,
        items = items,
    })
    exports['qb-inventory']:OpenShop(src, shopName)
end)
