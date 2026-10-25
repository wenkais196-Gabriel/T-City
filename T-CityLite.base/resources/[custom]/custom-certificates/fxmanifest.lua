fx_version 'cerulean'
game 'gta5'

author 'T-City'
description 'Certificate License System — modular, high-performance, secure, extensible'
version '1.0.0'

shared_scripts {
    'config.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/main.lua',
}

dependencies {
    'qb-core',
    'qb-inventory',
    'core-framework',
}
