fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Server-only agent action broker: preview, policy, budget and human approval (issues #30/#32)'
version '0.1.0'

server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@core-framework/bus.lua',
    'server/policy.lua',
    'server/director_rules.lua',
    'server/http_api.lua',
    'server/selftest.lua',
    'server/main.lua',
    'server/director.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
    'custom-quest',
    'core-framework',
}
