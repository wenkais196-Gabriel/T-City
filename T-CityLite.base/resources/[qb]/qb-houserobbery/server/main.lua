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

-- Functions

local function ResetHouseStateTimer(house)
    CreateThread(function()
        Wait(Config.TimeToCloseDoors * 60000)
        Config.Houses[house]['opened'] = false
        for _, v in pairs(Config.Houses[house]['furniture']) do
            v['searched'] = false
        end
        TriggerClientEvent('qb-houserobbery:client:ResetHouseState', -1, house)
    end)
end

-- 客户端传来的 house / cabin 直接拿去索引 `Config.Houses` 会抛错（打崩事件线程），
-- 也可能指向一个不存在的抽屉去刷 `searched` 状态。
local function getFurniture(house, cabin)
    if type(house) ~= 'string' then return nil, nil end
    local houseConfig = Config.Houses[house]
    if type(houseConfig) ~= 'table' then return nil, nil end
    local furniture = houseConfig['furniture']
    if type(furniture) ~= 'table' then return nil, houseConfig end
    local index = tonumber(cabin) or cabin
    local cabinConfig = furniture[index]
    if type(cabinConfig) ~= 'table' then return nil, houseConfig end
    return cabinConfig, houseConfig
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-houserobbery:server:GetHouseConfig', function(_, cb)
    cb(Config.Houses)
end)

-- Events

RegisterNetEvent('qb-houserobbery:server:SetBusyState', function(cabin, house, bool)
    -- 🔒 三个参数全来自客户端：坏 key 会让 `Config.Houses[house][...]` 抛错；
    --    而且任意玩家都能把任意家具标成 isBusy=true，等于锁死整间房子的搜刮。
    if type(bool) ~= 'boolean' then return end
    local cabinConfig = getFurniture(house, cabin)
    if not cabinConfig then return end
    if cabinConfig['searched'] then return end
    cabinConfig['isBusy'] = bool
    TriggerClientEvent('qb-houserobbery:client:SetBusyState', -1, cabin, house, bool)
end)

RegisterNetEvent('qb-houserobbery:server:enterHouse', function(house)
    local src = source
    local houseConfig = type(house) == 'string' and Config.Houses[house] or nil
    if type(houseConfig) ~= 'table' then return end
    if not QBCore.Functions.GetPlayer(src) then return end
    if not houseConfig['opened'] then
        ResetHouseStateTimer(house)
        TriggerClientEvent('qb-houserobbery:client:setHouseState', -1, house, true)
    end
    TriggerClientEvent('qb-houserobbery:client:enterHouse', src, house)
    houseConfig['opened'] = true
end)

RegisterNetEvent('qb-houserobbery:server:searchFurniture', function(cabin, house)
    local src = source
    -- 🔒 house / cabin 来自客户端：先做索引校验，坏 key 会让下面 `Config.Houses[house]` 抛错
    local cabinConfig, houseConfig = getFurniture(house, cabin)
    if not cabinConfig then return end
    -- 🔒 已经搜过的抽屉不能再搜（客户端可以不发这个状态，服务端才是权威）
    if cabinConfig['searched'] then return end
    -- ⚠️ 导出在 custom-crime 里，不是 custom-main：写错资源名会直接
    --    `attempt to call a nil value (method 'CheckHouseRobbery')`，整条搜刮流程永远失败。
    if not exports['custom-crime']:CheckHouseRobbery(src, house, cabin) then
        return
    end
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end
    local tier = houseConfig.tier
    local rewardTable = tier and Config.Rewards[tier] or nil
    if type(rewardTable) ~= 'table' then return end
    local availableItems = rewardTable[cabinConfig.type]
    if type(availableItems) ~= 'table' or #availableItems == 0 then return end
    local itemCount = math.random(0, 3)
    if itemCount > 0 then
        for _ = 1, itemCount do
            local selectedItem = availableItems[math.random(1, #availableItems)]
            local itemInfo = QBCore.Shared.Items[selectedItem.item]

            if not itemInfo.unique then
                local amount = math.random(selectedItem.min, selectedItem.max)
                exports['qb-inventory']:AddItem(src, selectedItem.item, amount, false, false, 'qb-houserobbery:server:searchFurniture')
            else
                exports['qb-inventory']:AddItem(src, selectedItem.item, 1, false, false, 'qb-houserobbery:server:searchFurniture')
            end
            TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'add')
            Wait(500)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.emty_box'), 'error')
    end
    cabinConfig['searched'] = true
    TriggerClientEvent('qb-houserobbery:client:setCabinState', -1, house, cabin, true)
end)

RegisterNetEvent('qb-houserobbery:server:removeAdvancedLockpick', function()
    -- 只删调用者自己背包里的开锁器（source 不来自参数，越权面为零）
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    exports['qb-inventory']:RemoveItem(src, 'advancedlockpick', 1, false, 'qb-houserobbery:server:removeAdvancedLockpick')
end)

RegisterNetEvent('qb-houserobbery:server:removeLockpick', function()
    -- 只删调用者自己背包里的开锁器（source 不来自参数，越权面为零）
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    exports['qb-inventory']:RemoveItem(src, 'lockpick', 1, false, 'qb-houserobbery:server:removeLockpick')
end)
