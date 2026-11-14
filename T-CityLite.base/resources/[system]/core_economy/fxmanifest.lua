fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Unified Economic Reward Gateway — single entry point for ALL money/item/rep rewards'
version '2.0.0'

server_scripts {
    'server/main.lua',
    'server/salary_scale.lua',  -- R2：薪资抑制（只改 QBShared.Jobs 的 payment，不改 qb-core）
}

dependencies {
    'qb-core',
}
