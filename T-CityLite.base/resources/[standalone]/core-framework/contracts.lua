-- contracts.lua — Service Contract 注册 (Phase 0-3 分层管理)
-- 所有权引擎 Service 的接口契约定义
-- 设计依据: docs/server-design/07-architecture-integration.md §2.3
--
-- 四原则落地:
--   模块化 — 每个 Service 独立命名空间，通过 Bus 暴露，无耦合
--   高性能 — 契约只定义签名，实现层可自由选择同步/异步/DirtyFlush
--   安全   — Patron 的写操作明确标记 "仅服务端路径"
--   可拓展 — Plugin Contract 可通过 Bus.GetService() 获取任意 Service 引用
--
-- 实现状态:
--   ✅ Phase 1 已实现: world_state (→ services/world_state_service.lua)
--   ✅ Phase 1 已实现: patron      (→ services/patron_service.lua)
--   ⛔ Phase 2-3 占位服务不注册（S2a 退役）:
--      reputation / chronicle / governance / cosmetics / funnel
--      没有真实调用方；注册它们只会让 BusStatus 出现"有服务、无实现"的假象。
--
-- 使用: Bus.GetService('world_state').GetRegionState(region_id, key)

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
-- 2. PatronService — 养服 ✅ Phase 1 已实现
--    → core-framework/services/patron_service.lua
--    → Bus.RegisterService('patron', ...) 在服务文件中注册
--
--    读语义：GetTier / IsActive 只读缓存、**不做 IO**，未命中返回 0（= 非 Patron，保守）
--    并后台预热；需要"现在就要准确值"的地方用 GetTierAsync(citizenid, cb)。
--    不要在这些入口上 Await DB：它们被高频调用，慢库会把处理该事件的协程一起拖住。
-- ============================================================================

print('[contracts] ✅ Phase 1: world_state + patron 已由各自服务文件注册; planned 服务不注册')
