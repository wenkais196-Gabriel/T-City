fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Menu of options for players to interact with to do certain tasks'
version '1.2.0'

client_scripts {
    'client/adapter.lua', -- issue #366：convar 关时直接 return，行为不变
    'client/main.lua',
}

server_scripts {
    'server/adapter_state.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/script.js',
    'html/style.css',
    'html/jquery.min.js',
    'html/vendor/*',
    'html/vendor/fontawesome/css/*',
    'html/vendor/fontawesome/webfonts/*'
}
