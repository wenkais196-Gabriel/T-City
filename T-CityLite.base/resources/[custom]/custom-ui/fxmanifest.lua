fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City Lite'
description 'Shared NUI menu focus / close-guard / distance helpers'
version '1.0.0'

dependencies {
    'core-framework',
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/main.lua',
}
