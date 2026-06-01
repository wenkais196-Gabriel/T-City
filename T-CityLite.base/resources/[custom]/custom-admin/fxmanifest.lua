fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'High-Security Admin Command Panel and Webhook Auditing for T-City Lite'
version '1.0.0'

lua54 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/commands.lua'
}

dependencies {
    'qb-core',
    'custom-career',
    'custom-main'
}
