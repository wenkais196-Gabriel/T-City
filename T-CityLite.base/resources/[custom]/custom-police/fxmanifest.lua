fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Provides police tools, evidence, job and more functionality for players to use as a cop'
version '1.7.0'

shared_scripts {
	'config.lua',
	'shared/policy.lua',
	'shared/charges.lua',
	'shared/insert_id.lua',
	'shared/npc_budget.lua',
	'shared/npc_callouts.lua',
	'@qb-core/shared/locale.lua',
	'locales/en.lua',
	'locales/*.lua'
}

client_scripts {
    '@core-framework/client/shared.lua',  -- 客户端共享助手（加载期包含，零调用开销）
	'@PolyZone/client.lua',
	'@PolyZone/BoxZone.lua',
	'@PolyZone/ComboZone.lua',
	'client/main.lua',
	'client/camera.lua',
	'client/interactions.lua',
	'client/job.lua',
	'client/heli.lua',
	'client/anpr.lua',
	'client/evidence.lua',
	'client/objects.lua',
	'client/tracker.lua',
	'client/stolen_radar.lua',
	'client/p0.lua',
	'client/backup.lua',
	'client/npc_callouts.lua',
}

dependencies {
	'qb-core',
	'qb-inventory',
	'custom-career',
	'custom-certificates',
	'custom-documents',
	'core-framework',
}

server_scripts {

	'@oxmysql/lib/MySQL.lua',
    -- 审计的唯一写者：必须排在所有调用它的文件之前
    'server/audit.lua',
	'server/main.lua',
	'server/npc_budget.lua',
	'server/p0.lua',
	'server/p1.lua',
	'server/p2_evidence.lua',
	'server/p3_cases.lua',
	'server/p2_system.lua',
	'server/commands.lua',
	'server/interactions.lua',
	'server/evidence.lua',
	'server/objects.lua',
	'server/vehicle.lua',
	'server/p4_npc.lua',
}

ui_page 'html/index.html'

files {
	'html/index.html',
	'html/vue.min.js',
	'html/script.js',
	'html/tablet-frame.png',
	'html/fingerprint.png',
	'html/main.css',
	'html/vcr-ocd.ttf',
	'html/vendor/*.js',
	'html/vendor/*.css'
}
