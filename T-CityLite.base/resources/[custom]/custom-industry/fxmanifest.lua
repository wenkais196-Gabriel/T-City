fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Industry S1-S7: treasury, facilities, production, quotas, sales, UI snapshot, 4-phase cycle and settlement'
version '0.7.0'

client_scripts {
    -- 加载期包含必须排第一（CLI-01）：错误上报 + 就绪信标。
    '@core-framework/client/shared.lua',
    -- 金额格式化只允许 core-framework 的 FormatMoney；Money() 是集中定义的别名。
    '@core-framework/shared/util.lua',
    '@core-framework/shared/money_aliases.lua',
    'client/main.lua',
}

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
    'config/cycle.lua',
    'server/org_id.lua',
    'server/treasury.lua',
    'server/audit.lua',
    'server/access.lua',
    'server/announce.lua',
    'server/cycle.lua',
    'server/settlement.lua',
    'server/facility.lua',
    'server/production.lua',
    'server/sale.lua',
    'server/ui.lua',
    'server/commands.lua',
    'server/commands_facility.lua',
    'server/commands_production.lua',
    'server/commands_sales.lua',
    'server/commands_cycle.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'core-framework',
}
