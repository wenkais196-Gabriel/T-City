fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Agent effect channel v1: server-issued client effects with ack + audit'
version '0.1.0'

shared_script 'shared/effect_rules.lua'
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}
client_script '@core-framework/client/shared.lua'
client_script 'client/main.lua'


dependencies {


    'qb-core',


    'oxmysql',


    'core-framework',


}
