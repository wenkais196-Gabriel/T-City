-- main.lua — qb-vehicleshop 服务端入口 (v2.2.0)
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 架构:
--   bus.lua       — 共享工具 + Bus 注册 + spawnvehicle callback
--   purchases.lua — 购买逻辑 (buyShowroom / sellShowroom / transfervehicle)
--   finance.lua   — 分期逻辑 (finance / payments / checkFinance)
--
-- 向后兼容: 所有事件名未变, Config.Shops 格式未变, qb-menu 客户端未变

local QBCore = exports['qb-core']:GetCoreObject()

-- Bus 已通过 bus.lua 注册到 core-framework
-- 外部资源可通过以下方式调用:
--   1. Bus.dealership.GetShopConfig('pdm')
--   2. exports['qb-vehicleshop']:service_dealership_GetShopConfig('pdm')
--   3. Bus.SafeCall('dealership', 'CheckLicense', player, vehicleModel)

print('^2[qb-vehicleshop] ^7🏪 车店系统已启动 v2.2.0')
print('^2[qb-vehicleshop] ^7  Bus: dealership (6 methods)')
print('^2[qb-vehicleshop] ^7  模块: bus.lua | purchases.lua | finance-lifecycle.lua | finance-payments.lua | integration.lua')
local ok, shops = pcall(function() return Bus.dealership.GetShopList() end)
if ok then
    print('^2[qb-vehicleshop] ^7  商店: ' .. table.concat(shops, ', '))
end
