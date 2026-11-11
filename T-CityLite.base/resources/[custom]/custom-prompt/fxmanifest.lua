fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'custom-prompt — 统一的交互提示（E 上下文 / ALT 世界物件）'
author 'T-City'
version '0.1.0'

client_scripts {
    '@core-framework/client/shared.lua',
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
}
