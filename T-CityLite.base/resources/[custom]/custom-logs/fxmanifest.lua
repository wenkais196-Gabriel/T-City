fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'Custom logging and audit dispatches'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua'
}

server_scripts {
    'server/logs.lua'
}

dependencies {
    'qb-core'
}
