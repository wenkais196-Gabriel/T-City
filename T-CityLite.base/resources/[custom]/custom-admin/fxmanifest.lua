fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'High-Security Admin Command Panel and Webhook Auditing for T-City Lite'
version '1.0.0'

lua54 'yes'

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/admin_panel.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/commands.lua'
}

dependencies {
    'qb-core',
    'custom-career',
    'custom-main',
    'core-framework',
}
