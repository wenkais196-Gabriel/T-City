fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Agent Ops observability: in-memory event ring, live snapshot, health and console commands'
version '0.1.0'

-- Server only on purpose: there is no client script, no net event and no NUI
-- surface. Agents read this resource through the server exports below or the
-- console, never through a player-facing channel.
server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
    'custom-police',
}
