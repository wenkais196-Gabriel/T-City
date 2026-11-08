-- ====================|| VARIABLES || ==================== --

QBCore = exports["qb-core"]:GetCoreObject()

-- ====================|| SERVER-SIDE LIMITS || ==================== --

-- 客户端的每一条请求都只是"意图"：加多少升、是不是在加油站、油桶现在有多少油，
-- 全部由服务端按 Config 复算。原来 litres / fuel 都是客户端说多少就多少。
local MAX_REFILL_LITRES = 300            -- 一次最多加 300 升（原版最大油箱的 3 倍，够用且封住天文数字）
local MAX_CAN_FUEL = Config.JerryCanLitre or 40
local GAS_STATION_RANGE = 40.0           -- 服务端认为"在加油站"的距离（客户端是按泵模型触发交互的，
                                         -- 泵与站点标记点相距十几米很常见，给小了会误杀正常加油）

local function isNearGasStation(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    for _, station in ipairs(Config.GasStations or {}) do
        if #(coords - station) < GAS_STATION_RANGE then return true end
    end
    return false
end

local function clampNumber(value, min, max)
    local number = tonumber(value)
    if not number then return nil end
    if number < min then number = min end
    if number > max then number = max end
    return number
end

-- ====================|| EVENTS || ==================== --

QBCore.Functions.CreateCallback('qb-fuel:server:refillVehicle', function (src, cb, litres)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return cb(false) end

    -- 负数/字符串/表一律拒绝（`RemoveMoney` 已经在 EconomyService 里挡了 <=0，但价格先算错就没意义）
    local clampedLitres = clampNumber(litres, 0, MAX_REFILL_LITRES)
    if not clampedLitres or clampedLitres <= 0 then return cb(false) end
    litres = clampedLitres
    if not isNearGasStation(src) then return cb(false) end

    local finalPrice = math.floor(litres * Config.FuelPrice)
    if finalPrice <= 0 then return cb(false) end

    if Player.PlayerData.money[Config.MoneyType] >= finalPrice then
        cb(Player.Functions.RemoveMoney(Config.MoneyType, finalPrice, 'refuel-vehicle'))
    else
        cb(false)
    end
end)

RegisterServerEvent('qb-fuel:server:buyJerryCan', function ()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 只能在加油站买（原来是全图任意位置下单）
    if not isNearGasStation(src) then return end

    if Player.Functions.RemoveMoney(Config.MoneyType, Config.JerryCanCost, 'buy-jerry-can') then
        Player.Functions.AddItem('weapon_petrolcan', 1, nil, { fuel = Config.JerryCanLitre, ammo = Config.JerryCanLitre })
    end
end)

RegisterServerEvent('qb-fuel:server:refillJerryCan', function ()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not isNearGasStation(src) then return end

    local jerryCan = Player.Functions.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Functions.Notify(Lang:t('error.no_jerrycan'), 'error') end
    -- `info` 可能是 nil（老数据的油桶），原来直接 `jerryCan.info.fuel = ...` 会抛错吞掉整条交易
    if type(jerryCan.info) ~= 'table' then jerryCan.info = {} end

    if Player.Functions.RemoveMoney(Config.MoneyType, Config.JerryCanRefillCost, 'refill-jerry-can') then
        jerryCan.info.fuel = MAX_CAN_FUEL
        jerryCan.info.ammo = MAX_CAN_FUEL
        Player.Functions.RemoveItem('weapon_petrolcan', 1, jerryCan.slot)
        Player.Functions.AddItem('weapon_petrolcan', 1, nil, jerryCan.info)
    end
end)

-- 客户端在"往车里倒油"时调用，语义是**扣减**（client/main.lua: `setCanFuel(canLiter - liter)`）。
-- 原来服务端直接把客户端给的数字写进油桶 —— 于是"加满"和"扣减"没有区别，
-- 任何玩家发一条 setCanFuel(40) 就白得 40 升油。这里只允许单调递减，并且夹在 0..上限内。
RegisterServerEvent('qb-fuel:server:setCanFuel', function (fuel)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local jerryCan = Player.Functions.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Functions.Notify(Lang:t('error.no_jerrycan'), 'error') end
    if type(jerryCan.info) ~= 'table' then jerryCan.info = {} end

    local current = tonumber(jerryCan.info.fuel) or 0
    if current < 0 then current = 0 end
    if current > MAX_CAN_FUEL then current = MAX_CAN_FUEL end
    local target = clampNumber(fuel, 0, MAX_CAN_FUEL)
    if not target then return end
    -- 只能减不能加：加满必须走 refillJerryCan 付钱。
    -- ⚠️ 这里**不能**静默写成 `target = current`：客户端 `canLiter` 来自 `GetAmmoInPedWeapon`
    -- （油桶 ammo 是 0..100 刻度，而 `Config.JerryCanLitre` 只有 40），一旦两边错位就会变成
    -- "油桶一个不少、车里油却加上去了" —— 那是刷油复制，比不给过更糟。
    if target > current then
        Player.Functions.Notify(Lang:t('error.no_fuel_can'), 'error')
        return
    end

    jerryCan.info.fuel = target
    jerryCan.info.ammo = target
    Player.Functions.RemoveItem('weapon_petrolcan', 1, jerryCan.slot)
    Player.Functions.AddItem('weapon_petrolcan', 1, nil, jerryCan.info)
end)
