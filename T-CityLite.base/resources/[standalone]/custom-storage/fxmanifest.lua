-- fxmanifest.lua — custom-storage 组织仓库

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Generic organization storage system — per-org shared stash with differentiated capacity (job & gang)'
version '1.0.0'

shared_scripts {
    'config.lua',
}

server_scripts {
    'server/main.lua',
}

dependencies {
    'oxmysql',
    'qb-core',
    'qb-inventory',
    'core-framework',
}
