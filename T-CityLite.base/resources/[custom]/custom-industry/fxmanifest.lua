fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'S1 organisation treasury: balance + idempotent ledger + audit (console commands only)'
version '0.1.0'

server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@core-framework/server/db.lua',
    -- 金额格式化只允许 core-framework 的 FormatMoney；Money() 是集中定义的别名。
    '@core-framework/shared/util.lua',
    '@core-framework/shared/money_aliases.lua',
    'config.lua',
    'server/treasury.lua',
    'server/audit.lua',
    'server/commands.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'core-framework',
}
