fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Justice system — arrest, lawyer, trial, prison ecosystem'
version '1.0.0'

shared_scripts { 'config.lua' }
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@core-framework/bus.lua',
    'server/main.lua',
    'server/sentence.lua',
    'server/arrest.lua',
    'server/trial.lua',
    'server/prison.lua',
}
client_scripts { 'client/main.lua' }

dependencies {
    'oxmysql', 'qb-core', 'qb-menu', 'qb-target', 'core-framework',
    'custom-police', 'qb-prison', 'custom-career',
    'production-freeze',
}
