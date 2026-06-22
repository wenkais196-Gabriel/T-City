fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot / T-City Lite'
description 'Allows players to purchase vehicles and manage shops through a job. v2.2.0: 模块化重构 — Bus 注册 + 四原则架构, 客户端拆分, NUI 支持'
version '2.2.0'

shared_script {
    'config.lua',
    '@qb-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bus.lua',               -- 共享工具 + Bus 注册 + spawnvehicle
    'server/purchases.lua',         -- 购买逻辑
    'server/finance-lifecycle.lua', -- Phase 2: 玩家计时 + 车辆操作 + 逾期
    'server/finance-payments.lua',  -- Phase 2: 分期购买 + 还款
    'server/integration.lua',       -- Phase 3: custom-vehicles Bus 集成 + 二手车估值
    'server/main.lua',              -- 入口 (启动日志)
}

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    '@PolyZone/EntityZone.lua',
    '@PolyZone/CircleZone.lua',
    '@PolyZone/ComboZone.lua',
    'client/util.lua',       -- 共享工具 + 全局状态 + 玩家生命周期
    'client/bus.lua',        -- Phase 4: 客户端 Bus 注册 (在 util 之后)
    'client/zones.lua',      -- 区域管理 + 展示车辆 + Blip
    'client/menus.lua',      -- qb-menu / qb-input 菜单逻辑
    'client/testdrive.lua',  -- 试驾逻辑
    'client/nui.lua',        -- NUI 回调 + 焦点管理
    'client/main.lua',       -- 入口 (启动日志)
}

-- NUI (Config.UseNui = true 时启用)
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/nui.css',
    'html/nui.js',
    'html/vue.min.js',
}

-- Bus 注册的 exports (由 core-framework Bus.RegisterService 自动生成):
--   exports['qb-vehicleshop']:service_dealership_GetShopConfig(name)
--   exports['qb-vehicleshop']:service_dealership_GetShopList()
--   exports['qb-vehicleshop']:service_dealership_CalculateFinance(...)
--   exports['qb-vehicleshop']:service_dealership_RecalculateFinance(...)
--   exports['qb-vehicleshop']:service_dealership_CheckLicense(player, model)
--   exports['qb-vehicleshop']:service_dealership_GetLicenseName(model)
--   exports['qb-vehicleshop']:service_dealership_EstimateUsedPrice(basePrice, state)
--   exports['qb-vehicleshop']:service_dealership_GetVehicleState(plate)

dependencies {
    'qb-core',
    'core-framework',
    'PolyZone',
}
