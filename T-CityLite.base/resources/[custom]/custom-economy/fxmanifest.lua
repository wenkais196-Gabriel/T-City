fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'Unified economic API and adaptive macroeconomic stabilizer'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua'
}

server_scripts {
    -- ⚠️ server/economy.lua removed — replaced by core_economy (Unified Reward Gateway)
}

dependencies {
    'qb-core',
    'custom-logs'
}
