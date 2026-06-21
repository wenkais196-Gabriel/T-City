-- fxmanifest.lua — story-engine 剧情引擎
--
-- v0.7.0 — 决策树 + 玩家抉择追踪 + NUI 决策弹窗
--
-- 核心能力:
--   - 决策节点定义与注册
--   - 选项白名单校验（防注入）
--   - player_choices 异步持久化
--   - 客户端 NUI 决策弹窗
--   - 通过 Bus 暴露服务接口
--
-- 设计原则: 模块化·高性能·安全·可拓展

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Story engine with decision trees and player choice tracking'
version '0.7.0'

files {
    'config/story_arcs.lua',
    'config/decisions.lua',
    'config/arc_finales.lua',
}

shared_scripts {
    'shared/config.lua',
}

server_scripts {
    'server/story_db.lua',
    'server/decision_engine.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'client/decision_nui.html'

dependencies {
    'qb-core',
    'oxmysql',
    'core-framework',
    'custom-quest',
}
