fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City'
description 'Map sidebar NUI — categorized blip browser with i18n'
version '1.0.0'

shared_scripts {
    '@qb-core/config_blips.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'html/map_sidebar.html'

files {
    'html/map_sidebar.html',
    'html/css/map_sidebar.css',
    'html/js/map_sidebar.js',
}

dependency 'qb-core'
dependency 'production-freeze'     -- provides _L() for i18n
