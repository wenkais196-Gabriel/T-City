-- fxmanifest.lua — T-City Dashboard v2.0
--
-- 全载具多模态智能中控系统
-- 六原则: 模块化·高性能·安全·可拓展·数据驱动·按需销毁
--
-- 核心能力:
--   - 6类载具动态模板 (跑车/商用/紧急/飞机/直升机/船只)
--   - 按 class 启动/销毁的独立轮询器 (零下车 CPU 开销)
--   - Vue 3 + TailwindCSS 工业级 NUI
--   - 服务端权威鉴权 (驾驶席/职业/所有权/RateLimit)
--   - 100% Convar 驱动配置

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Universal Multi-Modal Vehicle Dashboard — Vue 3 NUI, 6-class templates, event-driven, zero-idle overhead. v2.1: Police console + ANPR/radar/tracker/CCTV/plate system.'
version '2.1.0'

-- NUI: Vite 构建产物
ui_page 'nui/dist/index.html'
files {
    'nui/dist/index.html',
    'nui/dist/assets/*.css',
    'nui/dist/assets/*.js',
}

shared_scripts {
    'config/vehicles.lua',
    'config/themes.lua',
}

server_scripts {
    '@core-framework/bus.lua',
    '@oxmysql/lib/MySQL.lua',
    'server/security.lua',
    'server/compat.lua',
    'server/police_api.lua',
    'server/main.lua',
}

client_scripts {
    -- 客户端共享助手（加载期包含，零调用开销；必须排在其它 client 脚本之前）
    '@core-framework/client/shared.lua',
    'client/poller.lua',
    'client/controller.lua',
    'client/police.lua',
    'client/main.lua',
}

dependencies {
    'qb-core',
    'core-framework',
    -- 不再硬依赖 custom-police：对它的唯一用法是服务端 pcall 调 GetIncidentsPublic，
    -- 而硬依赖意味着 `restart custom-police` 会把车机整个停掉还不拉回来
    -- （2026-10-31 真机：警情页"又坏了"，其实是资源根本没起）。
    -- 资源不在时查询返回 upstream_unavailable，界面照常打开。
}
