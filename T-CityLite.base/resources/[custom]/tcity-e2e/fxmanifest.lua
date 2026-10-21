fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City E2E'
description 'Server-side end-to-end harness (no client required) — dev only'
version '0.1.0'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
    'core-framework',
    'custom-quest',
    'story-engine',
}
