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
    'client/main.lua',
}

dependencies {
    'qb-core',
    'qb-inventory',
}
