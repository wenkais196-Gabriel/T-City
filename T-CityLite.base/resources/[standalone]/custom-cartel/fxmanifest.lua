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
    'server/main.lua',
    'server/drug_lab.lua',
    'server/npc_manager.lua',
}

client_scripts {
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
