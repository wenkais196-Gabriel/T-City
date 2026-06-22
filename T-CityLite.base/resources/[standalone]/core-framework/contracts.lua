-- contracts.lua — Service Contract 注册 (Phase 0-3 分层管理)
-- 所有权引擎 Service 的接口契约定义 + 占位注册
-- 设计依据: docs/server-design/07-architecture-integration.md §2.3
--
-- 四原则落地:
--   模块化 — 每个 Service 独立命名空间，通过 Bus 暴露，无耦合
--   高性能 — 契约只定义签名，实现层可自由选择同步/异步/DirtyFlush
--   安全   — Patron/Cosmetics 的写操作明确标记 "仅服务端路径"
--   可拓展 — Plugin Contract 可通过 Bus.GetService() 获取任意 Service 引用
--
-- 实现状态:
--   ✅ Phase 1 已实现: world_state (→ services/world_state_service.lua)
--   ✅ Phase 1 已实现: patron      (→ services/patron_service.lua)
--   ⏳ Phase 2 占位:  reputation, chronicle
--   ⏳ Phase 3 占位:  governance, cosmetics, funnel
--
-- 使用: Bus.GetService('world_state').GetRegionState(region_id, key)
--        Bus.SafeCall('reputation', 'GetTrustSummary', citizenid)

if not Bus or not Bus.RegisterService then
    print('[contracts] ⚠️ Bus not loaded — contracts deferred')
    return
end

-- ============================================================================
-- 1. WorldStateService — 世界状态 ✅ Phase 1 已实现
--    → core-framework/services/world_state_service.lua
--    → Bus.RegisterService('world_state', ...) 在服务文件中注册
-- ============================================================================

-- ============================================================================
-- 2. ReputationService — 信任图
-- ============================================================================
-- 锚点: 03-irreplaceability-reputation.md
-- 7天交互门槛 · 同IP检测 · 每人每天最多3条 · Phase 2 实现
Bus.RegisterService('reputation', {
    --- 添加信任边
    ---@param from_citizen string 评价者
    ---@param to_citizen   string 被评价者
    ---@param category     string 信任类别: reliability, combat, trade, teaching
    ---@param weight       number [-1.0, 1.0]
    ---@param reason       string 关联事件
    ---@return boolean success
    ---@return string|nil error
    AddTrustEdge = function(from_citizen, to_citizen, category, weight, reason)
        return false, 'Phase 2'  -- Phase 2
    end,

    --- 获取玩家的信任摘要
    ---@param citizenid string
    ---@return table|nil { reliability, combat, trade, teaching → avg_weight }
    GetTrustSummary = function(citizenid)
        return nil  -- Phase 2
    end,

    --- 检查两个玩家是否有足够交互历史 (门槛校验)
    ---@param from_citizen string
    ---@param to_citizen   string
    ---@return boolean has_interaction
    CheckInteractionHistory = function(from_citizen, to_citizen)
        return false  -- Phase 2
    end,
})

-- ============================================================================
-- 3. ChronicleService — 编年史
-- ============================================================================
-- 锚点: 05-narrative-ownership.md
-- 记录全服事件 → 编年史 + Discord推送 + 上线通知 · Phase 2 实现
Bus.RegisterService('chronicle', {
    --- 记录一个世界事件
    ---@param event_data table { event_type, severity, title, description?, participants?, location? }
    ---@return boolean success
    ---@return number|nil event_id
    RecordEvent = function(event_data)
        return false, nil  -- Phase 2
    end,

    --- 获取玩家个人编年史
    ---@param citizenid string
    ---@return table|nil 事件列表
    GetPlayerChronicle = function(citizenid)
        return nil  -- Phase 2
    end,

    --- 获取服务器的赛季编年史 (Phase 3)
    ---@param season_id string|nil (nil=当前赛季)
    ---@return table|nil
    GetSeasonChronicle = function(season_id)
        return nil  -- Phase 3
    end,
})

-- ============================================================================
-- 4. GovernanceService — 共治
-- ============================================================================
-- 锚点: 04-co-governance.md
-- 完整生命周期: draft→cosigning→voting→passed/rejected/executed · Phase 3 实现
Bus.RegisterService('governance', {
    --- 创建提案
    ---@param scope       string 'organization'|'server'
    ---@param scope_id    string|nil 组织ID
    ---@param proposal_type string
    ---@param title       string
    ---@param description string
    ---@param proposed_by string citizenid
    ---@return boolean success
    ---@return number|nil proposal_id
    CreateProposal = function(scope, scope_id, proposal_type, title, description, proposed_by)
        return false, nil  -- Phase 3
    end,

    --- 投票
    ---@param proposal_id number
    ---@param citizenid   string
    ---@param vote        string 'for'|'against'
    ---@return boolean success
    ---@return string|nil error
    Vote = function(proposal_id, citizenid, vote)
        return false, 'Phase 3'  -- Phase 3
    end,

    --- 获取提案详情
    ---@param proposal_id number
    ---@return table|nil
    GetProposal = function(proposal_id)
        return nil  -- Phase 3
    end,

    --- 获取组织的有效提案列表
    ---@param scope string
    ---@param scope_id string|nil
    ---@return table 提案列表
    GetActiveProposals = function(scope, scope_id)
        return {}  -- Phase 3
    end,
})

-- ============================================================================
-- 5. PatronService — 养服 ✅ Phase 1 已实现
--    → core-framework/services/patron_service.lua
--    → Bus.RegisterService('patron', ...) 在服务文件中注册
-- ============================================================================

-- ============================================================================
-- 6. CosmeticsService — 外观商城
-- ============================================================================
-- 锚点: 06-payment-model.md
-- 绑成就 · 卖美观 · 不卖数值 · Phase 2-3 实现
Bus.RegisterService('cosmetics', {
    --- 获取玩家可解锁的外观列表
    ---@param citizenid string
    ---@return table { item_id, item_name, price, required_achievement, unlocked }
    GetUnlockable = function(citizenid)
        return {}  -- Phase 2
    end,

    --- 购买外观 (成就验证在服务端完成)
    ---@param citizenid string
    ---@param item_id   string
    ---@return boolean success
    ---@return string|nil error
    Purchase = function(citizenid, item_id)
        return false, 'Phase 2'  -- Phase 2
    end,

    --- 装备/卸下外观
    ---@param citizenid string
    ---@param item_id   string
    ---@param equip     boolean
    ---@return boolean success
    Equip = function(citizenid, item_id, equip)
        return false  -- Phase 2
    end,

    --- 获取玩家当前装备的外观
    ---@param citizenid string
    ---@return table|nil { item_id, item_type, ... }
    GetEquipped = function(citizenid)
        return nil  -- Phase 2
    end,
})

-- ============================================================================
-- 7. FunnelService — 预设→涌现漏斗
-- ============================================================================
-- 锚点: 01-preset-to-emergent-funnel.md
-- 社交信号累积 → 阈值触发 → 推荐 · Phase 3 实现
Bus.RegisterService('funnel', {
    --- 记录社交信号
    ---@param citizenid   string
    ---@param signal_type string 信号类型: gang_joined, mentor_matched, trade_completed, quest_coop
    ---@param data        table  附带数据
    ---@return boolean success
    RecordSocialSignal = function(citizenid, signal_type, data)
        return false  -- Phase 3
    end,

    --- 获取玩家的推荐
    ---@param citizenid string
    ---@return table|nil { organization, mentor, activity } 推荐列表
    GetRecommendations = function(citizenid)
        return nil  -- Phase 3
    end,

    --- 检查玩家当前漏斗层级
    ---@param citizenid string
    ---@return string 'tutorial'|'bridging'|'emergent'
    GetFunnelStage = function(citizenid)
        return 'tutorial'  -- Phase 3
    end,
})

print(('[contracts] ✅ Phase 1: world_state + patron 已由各自服务文件注册; 5 个 Phase 2-3 占位保留'))
