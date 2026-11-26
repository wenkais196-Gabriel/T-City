fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'T-City'
description 'Industry S1-S5: treasury, facilities, lazy production, demand quotas, sales and the shared UI snapshot (Boss menu + phone app)'
version '0.5.0'

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
    'server/org_id.lua',
    'server/treasury.lua',
    'server/audit.lua',
    'server/access.lua',
    'server/facility.lua',
    'server/production.lua',
    'server/sale.lua',
    'server/ui.lua',
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
