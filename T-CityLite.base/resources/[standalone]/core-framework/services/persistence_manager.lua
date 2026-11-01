-- persistence_manager.lua — 持久化的**委托层**（delegate），不是写者
--
-- 2026-11-01（P1-1 / P1-2）：存档的脏池、定时器、SQL 写入全部收回到 qb-core
-- （server/services/persistence_manager.lua 的 Store）。本文件只做转发：
--
--   * 不再持有脏池（以前有一份 LocalDirtyFlush，和 qb-core 那份互相看不见）
--   * 不再起定时器（以前 900s 跑两次，其中一次刷的是 air）
--   * 不再回调 qb-core 的玩家保存入口（Save(true)）：那等于把刷盘接回环上
--     —— 那条链是环：core-framework 的 ForceFlush → Save(true) → DirtyFlush.ForceFlush。
--        两份实现装进同一个 Lua state 就能复现无限递归（离线测试钉住了这一点）。
--
-- 为什么保留这个文件：Bus 的 `service_persistence_*` 导出、`DirtyFlush*` 导出、
-- 以及 `Bus.persistence` 的调用方都还在这里。删文件会改依赖方向，
-- 那是下一个阶段的事；本阶段只把它降级为纯转发。

local OWNER_RESOURCE = 'qb-core'

PersistenceManager = {}

--- 惰性解析写者。qb-core 是 core-framework 的 dependency，正常加载顺序下已经启动；
--- 万一没起来，返回 nil 而不是抛错——存档失败要留证据，不能让调用方炸掉。
local function owner()
    local ok, target = pcall(function() return exports[OWNER_RESOURCE] end)
    if not ok or not target then return nil end
    return target
end

local function callOwner(method, ...)
    local target = owner()
    if not target then
        print(('[persistence] ⚠️ owner %s 不可用，%s 被跳过'):format(OWNER_RESOURCE, method))
        return nil
    end
    local fn = target[method]
    if type(fn) ~= 'function' then
        print(('[persistence] ⚠️ owner 没有导出 %s —— 版本不匹配'):format(method))
        return nil
    end
    local ok, result = pcall(fn, ...)
    if not ok then
        print(('[persistence] ❌ owner.%s 抛错: %s'):format(method, tostring(result)))
        return nil
    end
    return result
end

-- ==============================================================
-- 对外 API：全部转发，没有一个自有实现
-- ==============================================================

function PersistenceManager.MarkDirty(citizenid, dataType)
    if not citizenid then return false end
    return callOwner('StoreMarkDirty', citizenid, dataType) == true
end

function PersistenceManager.SaveNow(citizenid, reason)
    if not citizenid then return false, 'no_target' end
    return callOwner('StoreSaveNow', citizenid, reason or 'delegate') or false
end

function PersistenceManager.ForceFlushPlayer(citizenid)
    if not citizenid then return false end
    return callOwner('StoreSaveNow', citizenid, 'force_player') or false
end

--- 刷盘：返回 owner 的 ack（{ reason, attempted, ok, failed, duration_ms }）。
function PersistenceManager.FlushAll(reason, ignoreBackoff)
    local ack = callOwner('StoreFlushAll', reason or 'delegate', ignoreBackoff)
    if ack then return ack end
    return {
        reason = reason or 'delegate',
        attempted = 0, ok = 0, failed = 0, duration_ms = 0,
        owner = 'unavailable',
    }
end

function PersistenceManager.Stats()
    local stats = callOwner('StoreStats')
    if type(stats) ~= 'table' then
        return {
            flush_count = 0, force_count = 0, last_flush_time = 0, last_flush_duration = 0,
            total_players_flushed = 0, failed_flushes = 0, dirty_pool_size = 0,
            owner = 'unavailable',
        }
    end
    stats.owner = OWNER_RESOURCE
    return stats
end

--- 定时器归 qb-core。保留这个入口只是为了不改 Bus 的方法表。
function PersistenceManager.StartFlushTick()
    print('[persistence] ℹ️ StartFlushTick 是 no-op —— 定时刷盘只在 qb-core 起一次')
    return false
end

function PersistenceManager.StartHealthReport()
    print('[persistence] ℹ️ StartHealthReport 是 no-op —— 健康报告由 qb-core 出')
    return false
end

-- ==============================================================
-- 兼容：`_G.DirtyFlush`（bus.lua 的 DirtyFlush* 导出读它）与 Bus 方法表
-- ==============================================================

local Delegate = {
    owner = OWNER_RESOURCE,
    MarkDirty = function(citizenid, dataType) return PersistenceManager.MarkDirty(citizenid, dataType) end,
    SaveNow = function(citizenid, reason) return PersistenceManager.SaveNow(citizenid, reason) end,
    ForceFlush = function(citizenid)
        if citizenid then return PersistenceManager.ForceFlushPlayer(citizenid) end
        return PersistenceManager.FlushAll('force_all', true)
    end,
    FlushAll = function(reason, ignoreBackoff) return PersistenceManager.FlushAll(reason, ignoreBackoff) end,
    Stats = function() return PersistenceManager.Stats() end,
}

_G.DirtyFlush = Delegate
if not _G.Bus then _G.Bus = {} end
_G.Bus.PersistenceManager = Delegate

if Bus and Bus.RegisterService then
    Bus.RegisterService('persistence', {
        MarkDirty = PersistenceManager.MarkDirty,
        SaveNow = PersistenceManager.SaveNow,
        ForceFlush = Delegate.ForceFlush,
        ForceFlushPlayer = PersistenceManager.ForceFlushPlayer,
        FlushAll = PersistenceManager.FlushAll,
        Stats = PersistenceManager.Stats,
        StartFlushTick = PersistenceManager.StartFlushTick,
        StartHealthReport = PersistenceManager.StartHealthReport,
    })
end

local resolved = (owner() ~= nil) and 'resolved' or 'MISSING'
print(('[persistence] ✅ delegate loaded (owner=%s: %s)'):format(OWNER_RESOURCE, resolved))
