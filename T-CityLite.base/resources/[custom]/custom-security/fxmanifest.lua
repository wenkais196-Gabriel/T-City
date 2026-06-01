fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'Security firewall, Rate Limit and anti-exploit dispatches'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua'
}

client_scripts {
    'client/security.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/security.lua'
}

dependencies {
    'qb-core',
    'custom-logs'
}
