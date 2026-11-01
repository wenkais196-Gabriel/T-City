-- fxmanifest.lua — T-City Lite 核心服务框架

fx_version 'cerulean'

client_scripts {
    'client/shared.lua',
}
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Core service framework: unified data access layer, cache engine, dirty flush pipeline, event firewall'
version '0.6.0'

shared_scripts {
    'shared/util.lua',
    'shared/regions.lua',
    'bus.lua',
    'events/event_types.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/rate_limit.lua',
    'compat.lua',
    'contracts.lua',
    'services/economy_service.lua',
    'services/metadata_service.lua',
    'services/security_service.lua',
    'services/job_service.lua',
    'services/notify_service.lua',
    'services/world_state_service.lua',
    'services/world_trace_service.lua',
    'services/patron_service.lua',
    'services/persistence_manager.lua',
    'server/client_reports.lua',
}

dependencies {
    'oxmysql',
    'qb-core',
    'production-freeze',  -- _L i18n must load before bus.lua
}
