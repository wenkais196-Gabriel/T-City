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
    -- 形态：判定（纯函数）→ 移动锁 → 状态。必须都在 main.lua 之前
    'client/core/surface_rules.lua',
    'client/core/device_lock.lua',
    'client/core/nav.lua',
    'client/core/surface.lua',
    'client/core/events.lua',
    -- diag owns the request-trace + ui-event channel; must load before main.lua
    'client/core/diag.lua',
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/sms.lua',
    -- CityFeed 的纯规则（公告校验/作者归类），main.lua 之前加载
    'server/city_feed.lua',
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
    'server/emergency.lua',
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
