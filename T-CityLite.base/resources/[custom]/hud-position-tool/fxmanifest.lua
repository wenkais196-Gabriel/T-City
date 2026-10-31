fx_version 'cerulean'
game 'gta5'

name 'hud-position-tool'
description '实时 HUD 定位调试工具 — /mapsize /ringpos /huddebug'
author 'T-City2 Dev'
version '1.0.0'

dependencies {
    'core-framework',
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    -- 小地图风格（native / square），必须在 client.lua 之后：它要覆盖 client.lua 的结果
    'client.lua',
    'client/minimap_style.lua',
}

ui_page 'html/overlay.html'

files {
    'html/overlay.html',
}
