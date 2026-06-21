-- ============================================================================
-- custom-taxes — 五大资金消耗口集成入口 (v1.0.0)
-- ============================================================================
-- 本文件为 custom-taxes 的服务端入口，负责:
--   1. 加载各消耗口子模块
--   2. Hook 车辆/房产购买事件，插入 SinkService 调用
--   3. 注册 Exports 供外部脚本调用
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ── 车辆购置税 Hook ────────────────────────────────────────────────────

-- Hook qb-vehicleshop: buyShowroomVehicle
AddEventHandler('qb-vehicleshop:server:buyShowroomVehicle', function(vehicleData)
    -- vehicleData 包含: { vehicle, price, plate, ... }
    -- 注意: 此事件在原版 qb-vehicleshop 中由 buyShowroomVehicle 函数调用 TriggerEvent 发出
    -- 如果原版没有 TriggerEvent，我们需要在 qb-vehicleshop 中添加
    -- 这里做被动监听
end)

-- Hook qb-vehicleshop: transfervehicle
AddEventHandler('qb-vehicleshop:server:transfervehicle', function(otherSource, plate)
    -- 同上 — 被动监听
end)

-- ── 主动集成: 在购车完成时调用购置税 ──────────────────────────────────

---供 qb-vehicleshop 调用的购置税接口
---@param source number 买家 source
---@param vehiclePrice number 车价
---@param vehicleModel string 车型
function CollectVehiclePurchaseTax(source, vehiclePrice, vehicleModel)
    return CollectPurchaseTax(source, vehiclePrice, vehicleModel)
end
exports('CollectVehiclePurchaseTax', CollectVehiclePurchaseTax)

---供 qb-vehicleshop 调用的过户税接口
---@param buyerSource number
---@param sellerSource number
---@param salePrice number
---@param vehicleModel string
function CollectVehicleTransferTax(buyerSource, sellerSource, salePrice, vehicleModel)
    return CollectTransferTax(buyerSource, sellerSource, salePrice, vehicleModel)
end
exports('CollectVehicleTransferTax', CollectVehicleTransferTax)

---供 qb-garages 调用的保险检查接口
---@param source number
---@param plate string
function CheckInsurance(source, plate)
    return CheckVehicleInsurance(source, plate)
end
exports('CheckInsurance', CheckInsurance)

-- ── 房产购买税 Hook ──────────────────────────────────────────────────

-- Hook qb-houses: buyHouse — 在原有 21% markup 之外额外征收印花税
-- 原版 buyHouse 计算: HousePrice = math.ceil(price * 1.21)
-- 本 Hook 额外加征 2% 购置印花税
AddEventHandler('qb-houses:server:buyHouse', function(houseId, price)
    local src = source
    -- 额外征收 2% 房产购置印花税
    local stampDuty = math.floor(price * 0.02)
    if stampDuty > 0 then
        if _G.Bus and _G.Bus.SinkService then
            _G.Bus.SinkService.Withdraw(src, stampDuty, 'transaction_tax',
                ('house_purchase:%s'):format(houseId))
        else
            local Player = QBCore.Functions.GetPlayer(src)
            if Player then
                Player.Functions.RemoveMoney('bank', stampDuty,
                    ('house_stamp:%s'):format(houseId))
            end
        end
        TriggerClientEvent('QBCore:Notify', src,
            ('Property stamp duty: $%d'):format(stampDuty), 'primary')
    end
end)

-- ── Exports ────────────────────────────────────────────────────────────

-- NPCPricing
exports('GetNPCBuyPrice', function(itemName, basePrice)
    return NPCPricing.GetBuyPrice(itemName, basePrice)
end)
exports('GetNPCSellPrice', function(itemName, basePrice)
    return NPCPricing.GetSellPrice(itemName, basePrice)
end)
exports('RecordNPCBuy', function(itemName, basePrice, quantity)
    NPCPricing.RecordBuy(itemName, basePrice, quantity)
end)
exports('RecordNPCSell', function(itemName, basePrice, quantity)
    NPCPricing.RecordSell(itemName, basePrice, quantity)
end)

-- ItemDurability
exports('DegradeItem', function(source, itemName, slot)
    return DegradeItem(source, itemName, slot)
end)
exports('RepairItem', function(source, itemName, slot)
    return RepairItem(source, itemName, slot)
end)
exports('GetDurabilityPercent', function(itemName, itemInfo)
    return GetDurabilityPercent(itemName, itemInfo)
end)

-- PropertyTax
exports('ProcessPropertyTax', function(source)
    ProcessPropertyTax(source)
end)

-- TransactionMonitor
exports('GetDailyTaxStats', function()
    return GetDailyStats()
end)

print('[custom-taxes] ✅ 五大资金消耗口已全部就绪')
print('[custom-taxes]   PropertyTax | VehicleLifecycle | NPCPricing | ItemDurability | TransactionMonitor')
