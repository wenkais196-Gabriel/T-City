-- fxmanifest.lua — custom-market 动态交易市场

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Dynamic commodity market with supply-demand price engine — buy high/sell low with mean reversion'
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
