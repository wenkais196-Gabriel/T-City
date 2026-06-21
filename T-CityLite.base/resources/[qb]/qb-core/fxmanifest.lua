fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Core resource for the framework, contains all the core functionality and features'
version '1.3.0'

shared_scripts {
    'config.lua',
    'config_blips.lua',
    'shared/locale.lua',
    'locale/en.lua',
    'locale/*.lua',
    'shared/main.lua',
    'shared/items.lua',
    'shared/jobs.lua',
    'shared/vehicles.lua',
    'shared/gangs.lua',
    'shared/weapons.lua',
    'shared/locations.lua'
}

client_scripts {
    'client/main.lua',
    'client/native_notify.lua',
    'client/functions.lua',
    'client/loops.lua',
    'client/events.lua',
    'client/drawtext.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- 🔄 重构: 服务模块 (必须在 main/player/functions 之前加载)
    'server/services/security_service.lua',
    'server/services/economy_service.lua',
    'server/services/metadata_service.lua',
    'server/services/qualification_service.lua',
    'server/services/persistence_manager.lua',
    -- 📊 动态经济: 热度追踪 + 资金回收 (统一奖励已迁移至 core_economy)
    'server/services/heat_service.lua',
    'server/services/sink_service.lua',
    -- 核心模块
    'server/main.lua',
    'server/functions.lua',
    'server/player.lua',
    'server/events.lua',
    'server/commands.lua',
    'server/exports.lua',
    'server/debug.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/css/drawtext.css',
    'html/js/*.js'
}

dependency 'oxmysql'

-- 🔄 Unified Bus: core-framework provides the consolidated DirtyFlush/SecurityService/EconomyService
-- qb-core falls back gracefully when core-framework is not loaded
optional_dependency 'core-framework'
