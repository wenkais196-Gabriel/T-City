fx_version 'cerulean'
game 'gta5'

author 'Custom Server'
description 'High-Performance Phone-First Custom Phone System for T-City Lite'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua'
}

client_scripts {
    -- 客户端共享助手（加载期包含）：CFShared.Report 上报、就绪信标、LoadModel/DrawText3D
    '@core-framework/client/shared.lua',
    'client/core/bridge.lua',
    'client/core/focus.lua',
    'client/core/events.lua',
    -- diag owns the request-trace + ui-event channel; must load before main.lua
    'client/core/diag.lua',
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/sms.lua',
    -- core must load before the registry and main.lua
    'server/core/identity.lua',
    'server/core/rate_limit.lua',
    -- diag depends on PhoneRateLimit (trace bucket); loads before main.lua
    'server/core/diag.lua',
    'server/core/events.lua',
    'server/core/notify.lua',
    'server/phone_apps.lua',
    'server/apps/police_mdt.lua',
    'server/apps/quests.lua',
    'server/qb_phone_compat.lua',
    'server/main.lua',
    'server/banking.lua',
    'server/jobboard.lua',
    'server/faction.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/assets/*',
    'html/assets/audio/*'
}

dependencies {
    'qb-core',
    'oxmysql',
    'core-framework',
}
