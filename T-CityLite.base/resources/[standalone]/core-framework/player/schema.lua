-- schema.lua — 玩家元数据完整 Schema 定义
-- 设计依据: docs/server-design/07-architecture-integration.md §2.1
-- Phase 0 只定义，不全量实现 —— 所有所有权引擎的 key 在这里预留
--
-- 使用:
--   local schema = load(LoadResourceFile(GetCurrentResourceName(), 'player/schema.lua'))()
--   或直接在服务端 require schema 文件
--
-- 四原则落地:
--   模块化 — 每个 key 属于明确的锚点系统
--   高性能 — 纯 Schema 定义，不产生运行时开销
--   安全   — 类型声明明确，可做运行时类型校验 (Phase 1+)
--   可拓展 — 新增 key 只需追加定义，不破坏向后兼容

local PlayerSchema = {
    -- ══════════════════════════════════════════════════════════
    -- 现有字段 (QBCore 原生，不动)
    -- ══════════════════════════════════════════════════════════
    money       = { type = 'number',   system = 'qb-core',   description = '现金' },
    bank        = { type = 'number',   system = 'qb-core',   description = '银行存款' },
    job         = { type = 'table',    system = 'qb-core',   description = '职业数据' },
    gang        = { type = 'table',    system = 'qb-core',   description = '帮派数据' },
    charinfo    = { type = 'table',    system = 'qb-core',   description = '角色基本信息' },
    inventory   = { type = 'table',    system = 'qb-core',   description = '背包数据' },
    metadata    = { type = 'table',    system = 'qb-core',   description = '扩展元数据容器' },
    position    = { type = 'table',    system = 'qb-core',   description = '最后位置' },

    -- ══════════════════════════════════════════════════════════
    -- Phase 0 新增: 所有权引擎预留 key
    -- 这些 key 在当前阶段全部返回 nil/空表
    -- ══════════════════════════════════════════════════════════

    -- 锚点: 不可替代性 + 声誉 (03-irreplaceability-reputation.md)
    -- 信任图中的所有入边 / 出边
    -- Phase 2 实现
    reputation_graph = {
        type        = 'table',
        system      = 'reputation',
        phase       = 2,
        description = '玩家信任图摘要: { reliability, combat, trade, teaching → avg_weight }',
        default     = {},
    },

    -- 锚点: 不可替代性 (03) — 技能位阶
    -- Phase 3 实现
    skill_ranks = {
        type        = 'table',
        system      = 'reputation',
        phase       = 3,
        description = '当前活跃技能位阶: { mechanic_engine = "master", ... }',
        default     = {},
    },

    -- 锚点: 付费模型 (06-payment-model.md)
    -- 养服月供等级: 0=普通, 1/2/3=Patron
    -- Phase 2 实现
    patron_tier = {
        type        = 'number',
        system      = 'patron',
        phase       = 2,
        description = 'Patron 月供等级: 0/1/2/3',
        default     = 0,
    },

    -- 锚点: 世界痕迹 (02-world-traces.md)
    -- 该玩家造成的世界变化列表
    -- Phase 1 实现
    world_traces = {
        type        = 'table',
        system      = 'world_state',
        phase       = 1,
        description = '玩家对世界的痕迹: [{region_id, state_key, when}, ...]',
        default     = {},
    },

    -- 锚点: 预设→涌现漏斗 (01-preset-to-emergent-funnel.md)
    -- 社交信号累积
    -- Phase 3 实现
    social_signals = {
        type        = 'table',
        system      = 'funnel',
        phase       = 3,
        description = '漏斗社交信号: {gang_joined, mentor_matched, quest_coop, ...}',
        default     = {},
    },

    -- 锚点: 叙事所有权 (05-narrative-ownership.md)
    -- 该玩家参与的重要叙事事件
    -- Phase 2 实现
    chronicle = {
        type        = 'table',
        system      = 'chronicle',
        phase       = 2,
        description = '个人传记: [{event_id, title, my_role, when}, ...]',
        default     = {},
    },

    -- 锚点: 共治系统 (04-co-governance.md)
    -- Phase 3 实现
    council_votes = {
        type        = 'table',
        system      = 'governance',
        phase       = 3,
        description = '共治投票记录: { proposal_id: "for"|"against", ... }',
        default     = {},
    },

    -- 锚点: 付费模型 (06) — 外观商城
    -- Phase 2 实现
    cosmetic_loadout = {
        type        = 'table',
        system      = 'cosmetics',
        phase       = 2,
        description = '当前装备的外观: { badge_id, name_color, outfit_id, vehicle_skin }',
        default     = {},
    },

    -- 锚点: 付费模型 (06) — 成就追踪
    -- Phase 1-2 实现
    achievements = {
        type        = 'table',
        system      = 'chronicle',
        phase       = 1,
        description = '成就列表: { achievement_id: {unlocked_at, tier, is_active} }',
        default     = {},
    },
}

-- ============================================================================
-- Utility: 获取某字段的默认值 (不创建表，仅返回引用)
-- ============================================================================
function PlayerSchema.GetDefault(system)
    local defaults = {}
    for key, def in pairs(PlayerSchema) do
        if type(def) == 'table' and def.system == system and def.default ~= nil then
            defaults[key] = def.default
        end
    end
    return defaults
end

-- ============================================================================
-- Utility: 列出某个 Phase 的所有字段
-- ============================================================================
function PlayerSchema.GetKeysByPhase(phase)
    local keys = {}
    for key, def in pairs(PlayerSchema) do
        if type(def) == 'table' and def.phase == phase then
            table.insert(keys, key)
        end
    end
    return keys
end

-- ============================================================================
-- Utility: 列出某个锚点系统的所有字段
-- ============================================================================
function PlayerSchema.GetKeysBySystem(system)
    local keys = {}
    for key, def in pairs(PlayerSchema) do
        if type(def) == 'table' and def.system == system then
            table.insert(keys, key)
        end
    end
    return keys
end

-- ============================================================================
-- Utility: 类型校验 — 检查 value 是否符合 Schema 定义
-- ============================================================================
function PlayerSchema.Validate(key, value)
    local def = PlayerSchema[key]
    if not def then return false, 'Unknown field: ' .. tostring(key) end
    if type(def) ~= 'table' then return true end  -- non-schema keys pass through

    local expectedType = def.type
    if expectedType == 'table' then
        if type(value) ~= 'table' then
            return false, ('%s expected table, got %s'):format(key, type(value))
        end
    elseif expectedType == 'number' then
        if type(value) ~= 'number' then
            return false, ('%s expected number, got %s'):format(key, type(value))
        end
        -- 安全: NaN/Inf 拒绝
        if value ~= value or value == math.huge or value == -math.huge then
            return false, ('%s invalid number (NaN/Inf)'):format(key)
        end
    -- 'array' type alias maps to table
    elseif expectedType == 'array' then
        if type(value) ~= 'table' then
            return false, ('%s expected array, got %s'):format(key, type(value))
        end
    end
    return true
end

return PlayerSchema
