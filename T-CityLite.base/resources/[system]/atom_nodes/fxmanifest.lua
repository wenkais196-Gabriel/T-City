fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Event-Driven Atomic Quest Nodes — GOTO | INTERACT | DELIVER (PolyZone-powered, zero polling)'
version '2.0.0'

files {
    'config/missions_payload.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

dependencies {
    'qb-core',
    'PolyZone',
    'production-freeze',
}
