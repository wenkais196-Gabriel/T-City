-- event_types.lua — 所有权引擎事件类型全局枚举
-- 设计依据: docs/server-design/07-architecture-integration.md §2.4
-- 使用: RegisterNetEvent(EventTypes.WORLD.TERRITORY_CHANGED)
--       Bus.Plugin.Subscribe(EventTypes.CHRONICLE.EVENT_RECORDED, handler, 'my_plugin')
--
-- 四原则落地:
--   模块化 — 事件命名空间隔离 (WORLD / CHRONICLE / REPUTATION / GOVERNANCE / FUNNEL)
--   高性能 — 纯常量表，零运行时开销，仅做发射/消费双方的契约对齐
--   安全   — 所有新增事件均为服务端发射/消费，不暴露客户端写事件
--   可拓展 — 第三方模组可通过 Bus.Plugin.Subscribe 订阅任意事件

-- 注册到全局 _G 供所有资源可访问（与 Bus 注册模式一致）
_G.EventTypes = _G.EventTypes or {}
EventTypes = _G.EventTypes

-- ============================================================================
-- WORLD — 世界痕迹事件
-- ============================================================================
EventTypes.WORLD = {
    -- 领土变更: 帮派战结算 (P0 — Phase 1 插入发射点)
    TERRITORY_CHANGED  = 'world:territory_changed',

    -- 市场涌现: 非正式市场形成 (P1)
    MARKET_EMERGED     = 'world:market_emerged',

    -- 声望更新: 区域安全评级变动 (P1)
    REPUTATION_UPDATED = 'world:reputation_updated',

    -- 经济异常: 单种商品价格波动 >30% (P1)
    ECONOMIC_ANOMALY   = 'world:economic_anomaly',

    -- 通用状态变更 (P1)
    STATE_CHANGED      = 'world:state_changed',
}

-- ============================================================================
-- CHRONICLE — 叙事/编年史事件
-- ============================================================================
EventTypes.CHRONICLE = {
    -- 事件已记录 (P1)
    EVENT_RECORDED     = 'chronicle:event_recorded',

    -- 玩家为事件添加注解 (Phase 2)
    ANNOTATION_ADDED   = 'chronicle:annotation_added',

    -- 赛季结束 (Phase 3)
    SEASON_ENDED       = 'chronicle:season_ended',

    -- 成就首位达成 (P1)
    ACHIEVEMENT_FIRST  = 'chronicle:achievement_first',
}

-- ============================================================================
-- REPUTATION — 信任/声誉事件
-- ============================================================================
EventTypes.REPUTATION = {
    -- 信任边被创建 (Phase 2)
    TRUST_EDGE_ADDED   = 'reputation:trust_edge_added',

    -- 信任边被撤销 (Phase 2)
    TRUST_EDGE_REVOKED = 'reputation:trust_edge_revoked',

    -- 技能位阶变更 (Phase 3)
    SKILL_RANK_CHANGED = 'reputation:skill_rank_changed',

    -- 师徒关系建立 (Phase 2)
    MENTOR_BOND_FORMED = 'reputation:mentor_bond_formed',
}

-- ============================================================================
-- GOVERNANCE — 共治事件
-- ============================================================================
EventTypes.GOVERNANCE = {
    -- 提案已创建 (Phase 3)
    PROPOSAL_CREATED   = 'governance:proposal_created',

    -- 提案已通过 (Phase 3)
    PROPOSAL_PASSED    = 'governance:proposal_passed',

    -- 提案已否决 (Phase 3)
    PROPOSAL_REJECTED  = 'governance:proposal_rejected',

    -- 组织领导人变更 (Phase 2-3)
    LEADER_CHANGED     = 'governance:leader_changed',

    -- 组织规则变更 (Phase 3)
    RULE_CHANGED       = 'governance:rule_changed',
}

-- ============================================================================
-- FUNNEL — 漏斗社交信号事件
-- ============================================================================
EventTypes.FUNNEL = {
    -- 社交信号 (P0 — Phase 1 插入发射点: 加入组织/完成任务)
    SOCIAL_SIGNAL      = 'funnel:social_signal',

    -- 系统推荐 (Phase 3)
    RECOMMENDATION     = 'funnel:recommendation',

    -- 漏斗阶段前进 (Phase 3)
    STAGE_ADVANCED     = 'funnel:stage_advanced',
}

-- ============================================================================
-- 事件发射辅助函数
-- ============================================================================

--- 安全发射事件 (封装 Bus.Plugin.Publish 的 pcall)
--- 使用此函数而非直接 Bus.Plugin.Publish，确保一个订阅者出错不影响其他订阅者
---@param eventName string EventTypes.WORLD.* / CHRONICLE.* / ...
---@param ... any 事件参数
function EventTypes.Publish(eventName, ...)
    if not eventName then return end
    -- 同时发射到 Bus.Plugin.Publish (订阅者) 和 FiveM RegisterNetEvent (跨资源)
    if Bus and Bus.Plugin and Bus.Plugin.Publish then
        Bus.Plugin.Publish(eventName, ...)
    end
    -- 同时通过 FiveM 原生事件系统发射，保证不依赖 Bus 的消费者也能收到
    TriggerEvent(eventName, ...)
end

--- 列出所有已定义的事件类型
---@return table { namespace = { key = event_string } }
function EventTypes.ListAll()
    return {
        WORLD       = EventTypes.WORLD,
        CHRONICLE   = EventTypes.CHRONICLE,
        REPUTATION  = EventTypes.REPUTATION,
        GOVERNANCE  = EventTypes.GOVERNANCE,
        FUNNEL      = EventTypes.FUNNEL,
    }
end

print(('[event_types] ✅ 5 个命名空间 / %d 个事件类型已注册'):format(
    (function()
        local count = 0
        for _, ns in pairs({EventTypes.WORLD, EventTypes.CHRONICLE, EventTypes.REPUTATION,
                            EventTypes.GOVERNANCE, EventTypes.FUNNEL}) do
            for _ in pairs(ns) do count = count + 1 end
        end
        return count
    end)()
))
