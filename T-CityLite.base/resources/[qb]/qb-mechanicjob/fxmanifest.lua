fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Mechanic job — repair/customize vehicles. Vehicle state managed by custom-vehicles.'
version '3.1.0'

dependencies {
    'qb-core',
    'qb-inventory',
    'custom-career',
    'custom-vehicles',
}

shared_scripts {
    '@qb-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config/*.lua',
}

client_scripts {
    -- v3.1: drivingdistance.lua + nitrous.lua 已迁移至 custom-vehicles
    'client/main.lua',
    'client/repair.lua',
    'client/performance.lua',
    'client/cosmetic.lua',
    'client/tunerchip.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/*',
    'carcols_gen9.meta',
    'carmodcols_gen9.meta'
}

data_file 'CARCOLS_GEN9_FILE' 'carcols_gen9.meta'
data_file 'CARMODCOLS_GEN9_FILE' 'carmodcols_gen9.meta'
