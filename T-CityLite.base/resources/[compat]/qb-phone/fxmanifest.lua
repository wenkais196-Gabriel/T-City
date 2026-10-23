fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'qb-phone export shim — forwards legacy exports to custom-phone'
version '1.0.0'

server_scripts {
    'server/main.lua',
}

dependencies {
    'custom-phone',
}
