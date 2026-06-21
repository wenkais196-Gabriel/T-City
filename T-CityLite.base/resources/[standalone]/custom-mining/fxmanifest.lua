-- fxmanifest.lua — custom-mining 矿业系统

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Mining system — ore gathering, smelting, org storage integration'
version '1.0.0'

shared_scripts { 'config.lua' }
server_scripts { 'server/main.lua', 'server/smelter.lua' }
client_scripts { 'client/main.lua' }

dependencies {
    'oxmysql', 'qb-core', 'qb-inventory', 'qb-target', 'qb-menu',
    'progressbar', 'core-framework', 'custom-storage', 'custom-market',
    'production-freeze',
}
