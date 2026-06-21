-- fxmanifest.lua — custom-quest 通用任务系统
--
-- v0.7.0 — 数据驱动的通用任务基础设施（增强版）
--
-- 核心能力:
--   - 任务状态机 (Not Started → In Progress → Step N → Completed/Failed)
--   - 6 种步骤类型 (reach / collect / script_trigger / custom_event / validator / reward)
--   - 外部脚本联动 API (OnCustomEvent / CompleteStep / RegisterStepValidator / TriggerQuest)
--   - 纵深安全防御 (Nonce Token / Rate Limit / 顺序强制 / 距离校验 / 速度检测 / 全局熔断)
--   - PolyZone 自动 reach 检测 + 客户端重连恢复
--   - 外部配置文件 (config/quests/*.lua)
--   - 步骤事件广播 + 自定义事件反向索引
--
-- 设计原则: 模块化·高性能·安全·可拓展

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Data-driven quest/mission system with state machine, security guards, and external script API'
version '0.7.0'

-- v0.7.0: 声明外部任务配置文件（使其可通过 LoadResourceFile 访问）
files {
    'config/quests/quest_miner.lua',
    'config/quests/quest_chain_miner.lua',
    'config/quests/quest_logistics.lua',
    'config/quests/quest_cartel_initiation.lua',
    'config/quests/quest_cartel_drug_run.lua',
    'config/quests/quest_chain_cartel.lua',
    -- v1.0.0: 乐高积木模板
    'config/quests/lego/bank_escort.lua',
    -- P2: 驾考 + 飞行 + 公共服务 + 民航 + 市井商业
    'config/quests/quest_driver_exam.lua',
    'config/quests/quest_pilot_exam.lua',
    'config/quests/quest_public_services.lua',
    'config/quests/quest_legal_aviation.lua',
    'config/quests/quest_civilian_misc.lua',
    -- v0.8b: 配送地址池
    'config/quests/address_pools.lua',
    -- v0.7 story-engine: 三个序章
    'config/quests/quest_cartel_ch1_first_blood.lua',
    'config/quests/quest_police_ch1_first_shift.lua',
    'config/quests/quest_civilian_ch1_first_dollar.lua',
    -- v0.7 story-engine: Cartel 线 Ch1-Ch3
    'config/quests/quest_cartel_ch2_territory_war.lua',
    'config/quests/quest_cartel_ch3_empire_shadow.lua',
    'config/quests/quest_cartel_ch4_benevolent_king.lua',
    'config/quests/quest_cartel_ch4_fugitive.lua',
    'config/quests/quest_cartel_ch4_tyrant.lua',
    -- v0.7 story-engine: Police 线 Ch1-Ch3
    'config/quests/quest_police_ch2_corruption_web.lua',
    'config/quests/quest_police_ch3_abyss.lua',
    'config/quests/quest_police_ch4_hero.lua',
    'config/quests/quest_police_ch4_silent_guardian.lua',
    'config/quests/quest_police_ch4_martyr.lua',
    -- v0.7 story-engine: Civilian 线 Ch1-Ch3
    'config/quests/quest_civilian_ch2_startup_struggle.lua',
    'config/quests/quest_civilian_ch3_cost_of_empire.lua',
    'config/quests/quest_civilian_ch4_mogul.lua',
    'config/quests/quest_civilian_ch4_artisan.lua',
    'config/quests/quest_civilian_ch4_survivor.lua',
}

shared_scripts {
    'config.lua',
}

server_scripts {
    'server/quest_cache.lua',
    'server/quest_db.lua',
    'server/quest_registry.lua',
    'server/quest_validators.lua',
    'server/quest_logistics_validators.lua',
    'server/quest_entity_tracker.lua',       -- v0.9: 实体追踪（脱钩/下车倒计时）
    'server/quest_entity_registry.lua',       -- v0.10: 实体注册表 + 延迟回收策略
    'server/quest_entity_placement.lua',      -- v0.10: placement 节点服务端
    'server/quest_address_resolver.lua',
    'server/quest_cooldown.lua',
    'server/quest_rewards.lua',
    'server/quest_security.lua',
    -- v1.0.0: 新增模块 — 排他锁 / 组队
    -- ⚠️ quest_nodes.lua removed — replaced by atom_nodes (Event-Driven Node Engine)
    'server/quest_mutex.lua',
    'server/quest_group.lua',
    'server/quest_manager.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
    'client/quest_checkpoint.lua',            -- v0.11: Native Checkpoint 管理器
    'client/quest_pos_collector.lua',         -- v0.11: 航空坐标采集工具
    'client/quest_logistics_client.lua',
    'client/quest_entity_placement.lua',     -- v0.10: placement 节点客户端
    'client/quest_cargo_damage.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
    'core-framework',
    'production-freeze',
}

-- v0.11: 测试套件（仅在 quest_test_mode=1 时加载）
-- 用法: setr quest_test_mode 1; refresh; ensure custom-quest
server_script 'tests/server/quest_flow_test.lua'       -- /quest_flow_test
client_script 'tests/client/quest_client_test.lua'     -- /quest_client_test