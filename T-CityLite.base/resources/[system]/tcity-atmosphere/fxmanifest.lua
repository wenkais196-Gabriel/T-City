fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City'
description 'Atmosphere BGM — scene-driven background music via Bus + NUI'
version '1.0.0'

shared_scripts {
    'config/scenes.lua',
}

server_scripts {
    '@core-framework/bus.lua',
    'server/atmosphere_service.lua',
}

client_scripts {
    'client/atmosphere_nui.lua',
}

files {
    'html/index.html',
    'html/atmosphere.js',
    'assets/audio/*.mp3',
}

dependencies {
    'core-framework',
    'qb-core',
}

ui_page 'html/index.html'
