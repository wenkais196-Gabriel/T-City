fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'custom-notify — 三层通知渲染器（feed / toast / error）'
author 'T-City'
version '0.1.0'

server_script 'server/main.lua'

client_scripts {
    '@core-framework/client/shared.lua',
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
}
