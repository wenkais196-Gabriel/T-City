fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City E2E'
description 'Server-side Scenario DSL end-to-end harness (no client required) — dev only'
version '0.2.0'

files {
    'config/scenarios/*.json',
}

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
