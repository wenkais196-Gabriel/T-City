fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'Central robbery and crime validations'
version '1.0.0'

lua54 'yes'

server_scripts {
    'server/crime.lua'
}

dependencies {
    'qb-core',
    'custom-logs'
}
