fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Production Freeze: i18n + Debug OFF + Entity GC + PolyZone Polish'
version '1.0.0'

files {
    'locales/locales.lua',
}

shared_scripts {
    'shared/i18n_shared.lua',
}

server_scripts {
    'server/i18n_server.lua',
    'server/main.lua',
}

client_scripts {
    'client/i18n.lua',
    'client/main.lua',
}

dependencies {
    'qb-core',
}
