-- custom-taxes — 五大资金消耗口系统 (v1.0.0)
--
-- PropertyTax       — 房产税懒加载 (阶梯税率 × 地段系数 × 欠费充公)
-- VehicleLifecycle  — 车辆生命周期消耗 (购置税/过户税/保险/大修)
-- NPCPricing        — NPC动态定价引擎 (供需弹性 + HeatService联动)
-- ItemDurability    — 物品耐久归零销毁 (武器/防弹衣/工具)
-- TransactionMonitor — 大额转账监控 ($100k+扣5% / 跨组织$50k+扣3%)

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Economic Sink Systems: Property Tax, Vehicle Lifecycle, NPC Pricing, Item Durability, Transaction Monitor'
version '1.0.0'

shared_scripts {
    '@qb-core/config.lua',
}

server_scripts {
    -- ⚠️ vehicle_lifecycle.lua removed — merged to core_economy SinkService
    -- ⚠️ npc_pricing.lua removed — replaced by economy_baseline.json + core_economy
    'server/property_tax.lua',
    'server/item_durability.lua',
    'server/transaction_monitor.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
}
