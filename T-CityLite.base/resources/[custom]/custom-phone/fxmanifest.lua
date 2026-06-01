fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'High-Performance Phone-First Custom Phone System for T-City Lite'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/banking.lua',
    'server/jobboard.lua',
    'server/faction.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/assets/*'
}

dependencies {
    'qb-core',
    'oxmysql'
}
