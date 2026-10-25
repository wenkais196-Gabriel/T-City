-- fxmanifest.lua — custom-cartel Cartel 组织核心

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Cartel organization core — drug production chain, NPC allies, territory management'
version '1.0.0'

shared_scripts {
    'config.lua',
}

server_scripts {
    '@core-framework/bus.lua',
    'server/main.lua',
    'server/drug_lab.lua',
    'server/npc_manager.lua',
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/main.lua',
}

dependencies {
    'oxmysql',
    'qb-core',
    'qb-inventory',
    'qb-target',
    'qb-menu',
    'progressbar',
    'core-framework',
    'custom-storage',
    'custom-market',
    'custom-security',
    'production-freeze',
}
