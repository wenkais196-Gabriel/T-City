-- fxmanifest.lua — custom-vehicles 自研载具系统
--
-- v0.9.0 — 模块化·高性能·安全·可拓展 四原则设计
--
-- 核心能力:
--   - 服务端权威钥匙管理 (GiveKeys/RemoveKeys/HasKeys)
--   - 统一车辆状态管理 (里程/引擎损耗/磨损部件/氮气/Tuner)
--   - 客户端事件驱动 (gameEventTriggered) 替代高频 Tick 轮询
--   - 热线发动 (Hotwire) + 撬锁 (Lockpick) 安全校验
--   - 100% 向下兼容 qb-vehiclekeys + qb-mechanicjob 旧版 exports/events
--   - 车载中控屏 API + 安全带/巡航/转向灯/推车
--   - Convar 驱动运行时调参
--
-- 设计原则: 模块化·高性能·安全·可拓展

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Unified vehicle system — keys + state management + driving aids. O(1) cache, event-driven, drop-in replacement for qb-vehiclekeys + qb-mechanicjob state.'
version '0.9.0'

shared_scripts {
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/key_manager.lua',
    'server/compat.lua',        -- 兼容桥先加载，main.lua exports 覆盖
    'server/vehicle_state.lua', -- v0.9: 统一车辆状态 (替代 qb-mechanicjob 状态缓存)
    'server/dashboard_api.lua', -- v0.7b: 中控屏服务端 API
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
    'client/vehicle_degradation.lua', -- v0.9: 里程/引擎损耗/磨损部件 (修复帧级扣血 Bug)
    'client/vehicle_nitrous.lua',     -- v0.9: 氮气加速系统
    'client/seatbelt.lua',
    'client/cruise.lua',
    'client/vehiclepush.lua',
    'client/noshuff.lua',
    'client/indicators.lua',
    -- client/dashboard.lua 已迁移至 tcity-dashboard
}

dependencies {
    'oxmysql',
    'qb-core',
    'core-framework',
    'custom-quest',
}
