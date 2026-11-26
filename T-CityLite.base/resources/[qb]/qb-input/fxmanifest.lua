fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Menu that allows players to input information for various things'
version '1.2.0'

client_scripts {
    'client/adapter.lua', -- issue #366：convar 关时直接 return，行为不变
    'client/config.lua',
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/styles/*.css',
    'html/script.js'
}
