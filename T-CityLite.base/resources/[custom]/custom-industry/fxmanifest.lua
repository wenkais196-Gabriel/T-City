fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Industry S1-S4: treasury, ledger, audit, facilities, workstations, lazy production, demand quotas and sales (server only)'
version '0.4.0'

server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@core-framework/server/db.lua',
    -- 金额格式化只允许 core-framework 的 FormatMoney；Money() 是集中定义的别名。
    '@core-framework/shared/util.lua',
    '@core-framework/shared/money_aliases.lua',
    'config.lua',
    'config/facility.lua',
    'config/production.lua',
    'config/sales.lua',
    'server/org_id.lua',
    'server/treasury.lua',
    'server/audit.lua',
    'server/access.lua',
    'server/facility.lua',
    'server/production.lua',
    'server/sale.lua',
    'server/commands.lua',
    'server/commands_facility.lua',
    'server/commands_production.lua',
    'server/commands_sales.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'core-framework',
}
