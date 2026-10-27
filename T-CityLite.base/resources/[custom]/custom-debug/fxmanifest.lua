fx_version 'cerulean'
game 'gta5'

author 'Debug Tool'
description '黑屏诊断与强制修复工具'
version '1.0.0'

lua54 'yes'

dependencies {
    'core-framework',
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/debug.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html'
}
