fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'High-Performance Multi-label Career Tag System for T-City Lite'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'configs.lua'
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

dependencies {
    'qb-core',
    'core-framework',
}
