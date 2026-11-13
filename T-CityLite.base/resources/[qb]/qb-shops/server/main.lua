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

-- 补货/工资这类"跑到点就发钱"的 handler 必须自带冷却：客户端跑完一趟才发一次，
-- 但事件本身谁都能发，站在交货点循环调用就是印钞机。
local RESTOCK_COOLDOWN_MS = 30000
local LastRestock = {}

-- R0（2026-11-13）：冷却只限速，不证明"跑了这一趟"。真正的凭据是**押金会话**：
-- 只有 DoBail(true) 扣过押金才开一趟，趟内最多结算 Config.MaxDeliveries 次（与客户端同口径）。
-- 钥匙用 citizenid：重连换 source 不该白送一趟新的。
local DeliverySessions = {}

local function nearCoords(source, coords, maxDistance)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return false end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local playerCoords = GetEntityCoords(ped)
    return #(playerCoords - vector3(coords.x, coords.y, coords.z)) <= maxDistance
end

-- 职业门（R0.3，2026-11-13）：送货循环归 trucker。租车与结算都走这里；
-- Config.DeliveryJob 置空表即关闭这道门（退回"谁来都能送"的旧行为）。
local function meetsDeliveryJob(player)
    local gate = Config.DeliveryJob
    if type(gate) ~= 'table' or not gate.name then return true end
    local job = player and player.PlayerData and player.PlayerData.job
    if type(job) ~= 'table' or job.name ~= gate.name then return false end
    if gate.requireDuty and not job.onduty then return false end
    return true
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
    -- R0.3b：Cryptostick 掉率改配置驱动，默认 0。原来硬编码 10%/站，而一根 cryptostick
    -- 在 qb-crypto 按 Worth=1000 兑换 → 20 站/趟期望 2 根 = $2,000，比现金结算（$1,400）还多，
    -- 等于把这一档的收益从 $2.4k/h 抬到 $6k+/h。要保留这个彩蛋就把它调成低概率（1–2%）。
    local bonusChance = tonumber(Config.DeliveryCryptostickChance) or 0
    if bonusChance > 0 and math.random(100) <= bonusChance then
        exports['qb-inventory']:AddItem(source, Config.RewardItem, 1, false, false, 'qb-shops:deliveryPay')
    end
end

-- Events

-- Deliveries

RegisterNetEvent('qb-shops:server:RestockShopItems', function(shop)
    local src = source
    if type(shop) ~= 'string' then return end
    local location = Config.Locations[shop]
    if type(location) ~= 'table' then return end

    -- R0（2026-11-13）：本趟凭据 = 押金会话。没有会话（没付押金）或已跑满 MaxDeliveries，
    -- 一律不结算 —— 原来只靠 30 秒冷却，任何人都能站在交货点一直领 DeliveryPrice。
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end
    local citizenid = player.PlayerData.citizenid
    local session = DeliverySessions[citizenid]
    if not session or (session.stops or 0) >= Config.MaxDeliveries then return end
    -- R0.3：不在岗的 trucker 与非 trucker 一律不结算（Config.DeliveryJob 可置空关闭）
    if not meetsDeliveryJob(player) then return end

    -- 一次交货一条钱：同一玩家**在同一家店** 30 秒内只认一条（原来站交货点循环发就能无限刷
    -- DeliveryPrice）。⚠️ 冷却键必须带 shop：送货路线里相邻两家的交货点可能只隔 47 米
    -- （ammunation ↔ ltdgasoline2），熟练玩家 30 秒内就能跑完第二趟 —— 只按 src 计会让第二趟的
    -- 工资与补货被静默吞掉。
    local cooldownKey = src .. ':' .. shop
    local now = GetGameTimer()
    if LastRestock[cooldownKey] and (now - LastRestock[cooldownKey]) < RESTOCK_COOLDOWN_MS then return end
    -- 交货点距离（deliveryPay 内部也有一次，但它是"不付钱就 return"，闸门认不出这是守卫）
    if not nearCoords(src, location.delivery, 10.0) then return end
    LastRestock[cooldownKey] = now
    session.stops = (session.stops or 0) + 1

    deliveryPay(src, shop)
    -- R0.3：跑一站给一点货运算声望（此前 delivery 声望只在死代码 PaySlip 里发）
    if player.Functions.AddRep then player.Functions.AddRep('delivery', 1) end
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
    -- R0.3：只有（在岗的）trucker 能租车送货；否则收了押金也结算不了，等于骗钱
    if bool and not meetsDeliveryJob(Player) then
        TriggerClientEvent('QBCore:Notify', src, '只有货运司机（在岗）才能租车送货', 'error')
        return
    end
    if bool then
        if Player.Functions.RemoveMoney('cash', Config.TruckDeposit, 'tow-received-bail') then
            Bail[Player.PlayerData.citizenid] = Config.TruckDeposit
            DeliverySessions[Player.PlayerData.citizenid] = { stops = 0 }
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.paid_with_cash', { value = Config.TruckDeposit }), 'success')
            TriggerClientEvent('qb-shops:client:SpawnVehicle', src)
        elseif Player.Functions.RemoveMoney('bank', Config.TruckDeposit, 'tow-received-bail') then
            Bail[Player.PlayerData.citizenid] = Config.TruckDeposit
            DeliverySessions[Player.PlayerData.citizenid] = { stops = 0 }
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.paid_with_bank', { value = Config.TruckDeposit }), 'success')
            TriggerClientEvent('qb-shops:client:SpawnVehicle', src)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_deposit', { value = Config.TruckDeposit }), 'error')
        end
    else
        if Bail[Player.PlayerData.citizenid] then
            Player.Functions.AddMoney('cash', Bail[Player.PlayerData.citizenid], 'trucker-bail-paid')
            Bail[Player.PlayerData.citizenid] = nil
            DeliverySessions[Player.PlayerData.citizenid] = nil
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
