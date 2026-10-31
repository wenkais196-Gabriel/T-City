-- server/p0.lua — 警情/单位体系的核心：常量、状态机真值表、共享助手、`PoliceDispatch` 本体。
--
-- 这个文件原先有 1224 行，2026-10-26 拆成五个模块（纯搬迁，零行为变化）：
--
--   p0.lua            本文件：常量 + SM-02 转移表 + 共享助手 + P 表
--   p0_units.lua      单位：值班、状态、指派、单位→警情进度派生
--   p0_lifecycle.lua  申领 / 到场（nonce + 服务端复算）/ 判定表 / 路线推送
--   p0_incidents.lua  建单、合并、投影、状态机执行、stale 清扫、911 入口
--   p0_read.lua       读取面：警情板、公民/车辆/审计查询
--
-- 模块之间**不共享 local**：共享的东西一律挂在 `P.internal`（资源内部表，不是导出面），
-- 各模块加载时按名字绑定、调用时解析，所以加载顺序只影响「定义」，不影响「调用」。
-- 跨模块调用写成同名懒包装（`local function foo(...) return I.foo(...) end`），
-- 这样函数体一个字都不用改，搬迁前后能逐行 diff。
--
-- 每个模块自己登记自己的 exports（谁实现谁登记），别集中到一个 exports 文件：
-- 那样 FIT-04 的「导出必须校验权限」就查不到实现体，闸门会变成装饰。

local QBCore = exports['qb-core']:GetCoreObject()

local P = {}
-- 资源内部共享表（不是导出面）
P.internal = {}

local VALID_STATUS = {
    off_duty = true, available = true, busy = true, unavailable = true,
    assigned = true, enroute = true, on_scene = true,
}

local INCIDENT_STATUS = {
    -- draft 是 agent 解析出来的 call 卡草稿：上板但不响铃、不指派，等警员采纳
    draft = true,
    open = true, assigned = true, enroute = true, on_scene = true,
    cleared = true, closed = true,
}

-- SM-02 transition table. `cleared` only exists for rows written before the
-- guard landed; new closes store `closed` directly, so it can only move on to
-- `closed`. A same-status call is an idempotent retry, not a transition.
local INCIDENT_TRANSITIONS = {
    -- 草稿只有两条出路：采纳（open）或丢弃（closed）。不能直接被指派。
    draft = { open = true, closed = true },
    open = { assigned = true, closed = true },
    assigned = { enroute = true, open = true, closed = true },
    enroute = { on_scene = true, assigned = true, closed = true },
    on_scene = { closed = true },
    cleared = { closed = true },
    closed = {},
}

local INCIDENT_DISPOSITIONS = {
    cleared = true, cancelled = true, false_alarm = true, stale = true, arrest = true,
}

-- GetIncidents is a live queue/board read; callers may filter by an active
-- status, but `closed` is never listed (archived calls live in cases/audit).
local INCIDENT_LIST_STATUS = {
    open = true, assigned = true, enroute = true, on_scene = true,
}

local function pd(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or type(player.PlayerData) ~= 'table' then return nil end
    return player.PlayerData
end

local function isPolice(data)
    return PolicePolicy.IsPolice(data)
end

local function grade(data)
    return PolicePolicy.Grade(data)
end

--- Notifications are owned by custom-phone (FIT-02). Enqueue through the outbox
--- in p2_system (loaded later, so the global is resolved at call time); fall
--- back to the owner export only if that layer is missing.
local function notifyOfficer(citizenid, title, content, appId)
    local payload = { citizenid = citizenid, title = title, content = content, app_id = appId }
    if type(Outbox) == 'table' and type(Outbox.Enqueue) == 'function' then
        return Outbox.Enqueue('notification', payload)
    end
    pcall(function()
        exports['custom-phone']:Notify(citizenid, title, content, appId)
    end)
    return false
end

local function audit(actorCid, action, target, detail, actorKind)
    -- 唯一写者见 server/audit.lua（这里只保留同名包装，调用点不用改）
    return PoliceAudit.Write(actorCid, action, target, detail, actorKind)
end

local function trim(v)
    return type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
end

--- server/main.lua 比本文件先加载，所以它只能在**运行时**通过这个全局拿到派单 API。
--- （locals 在 main.lua 里根本看不到，exports 自调用虽然可行但会把内部路径变成公共契约。）
PoliceDispatch = P

-- 资源内部共享（供兄弟模块加载时取名字；不是导出面）
P.internal.pd, P.internal.isPolice, P.internal.grade = pd, isPolice, grade
P.internal.notifyOfficer, P.internal.audit, P.internal.trim = notifyOfficer, audit, trim
P.internal.VALID_STATUS = VALID_STATUS
P.internal.INCIDENT_STATUS = INCIDENT_STATUS
P.internal.INCIDENT_TRANSITIONS = INCIDENT_TRANSITIONS
P.internal.INCIDENT_DISPOSITIONS = INCIDENT_DISPOSITIONS
P.internal.INCIDENT_LIST_STATUS = INCIDENT_LIST_STATUS

print('[custom-police] p0 core ready (5 modules)')
