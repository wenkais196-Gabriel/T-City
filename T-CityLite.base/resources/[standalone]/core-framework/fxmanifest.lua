-- fxmanifest.lua — T-City Lite 核心服务框架

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Core service framework: unified data access layer, cache engine, dirty flush pipeline, event firewall'
version '0.6.0'

shared_scripts {
    'bus.lua',
}

server_scripts {
    'compat.lua',
    'services/economy_service.lua',
    'services/metadata_service.lua',
    'services/security_service.lua',
    'services/job_service.lua',
    'services/notify_service.lua',
    'cache/cache_manager.lua',
    'cache/dirty_flush.lua',
    'services/persistence_manager.lua',
}

dependencies {
    'oxmysql',
    'qb-core',
    'production-freeze',  -- _L i18n must load before bus.lua
}
