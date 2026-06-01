fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'Central custom logic entry for this QBCore server'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config/*.lua'
}

client_scripts {
    'client/main.lua',
    'client/dispatch.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/dispatch.lua'
}

dependencies {
    'qb-core',
    'custom-logs'
}

