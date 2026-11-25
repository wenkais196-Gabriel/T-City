fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Industry S1/S2: treasury, ledger, audit, facilities and workstations (server only)'
version '0.2.0'

server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@core-framework/server/db.lua',
    -- 金额格式化只允许 core-framework 的 FormatMoney；Money() 是集中定义的别名。
    '@core-framework/shared/util.lua',
    '@core-framework/shared/money_aliases.lua',
    'config.lua',
    'config/facility.lua',
    'server/treasury.lua',
    'server/audit.lua',
    'server/access.lua',
    'server/facility.lua',
    'server/commands.lua',
    'server/commands_facility.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'core-framework',
}
