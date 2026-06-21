-- persistence_manager.lua — 高性能持久化编排器
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 配置化定时刷盘管道（默认 15 分钟，可通过 Convar 动态调整）
--   2. 玩家下线/断线 → ForceFlush 紧急刷盘
--   3. txAdmin 关闭/重启 → 全量刷盘
--   4. 资源停止 → 全量刷盘保护
--   5. 健康监控 → 脏玩家池统计 + 刷盘延迟告警
--
-- 数据流:
--   所有写操作 → 内存 (MarkDirty) → 定时批量刷盘 → DB
--   playerDropped → ForceFlush (单个)
--   txAdmin stop → FlushAll (全量)
--   resource stop → FlushAll (全量)
--
-- 绝不回档保障:
--   - 刷盘失败不清理 dirty 标记 → 下次重试
--   - 断线立即刷盘 → 零数据丢失
--   - 服务器关闭前全量刷盘 → 零数据丢失
--   - 批量 UPDATE 单条 SQL → 原子性

local QBCore = exports['qb-core']:GetCoreObject()
PersistenceManager = {}

-- ==============================================================
-- 配置（可通过 Convar 动态调整）
-- ==============================================================

local function GetIntConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return math.floor(tonumber(val) or default) end
    return default
end

-- ==============================================================
-- 统计信息
-- ==============================================================

local stats = {
    flush_count = 0,
    force_count = 0,
    last_flush_time = 0,
    last_flush_duration = 0, -- ms
    total_players_flushed = 0,
    failed_flushes = 0,
}

-- ==============================================================
-- 配置化刷盘管道
-- ==============================================================

--- 启动可配置的定时刷盘 Tick
---@param intervalSec number|nil 刷盘间隔（秒），nil 时从 Convar 读取，默认 900 (15 分钟)
function PersistenceManager.StartFlushTick(intervalSec)
    local interval = intervalSec or GetIntConvar('persistence_flush_interval', 900)
    if interval < 30 then interval = 30 end  -- 最小 30 秒，防止过于频繁

    print(('[persistence] ⏰ Flush tick started: every %d seconds'):format(interval))

    CreateThread(function()
        while true do
            Wait(interval * 1000)

            if not DirtyFlush then
                print('[persistence] ⚠️ DirtyFlush not available, skipping tick')
                goto continue
            end

            local startTime = os.clock()
            local dirtyStats = DirtyFlush.Stats()
            local dirtyCount = dirtyStats.dirty_count or 0

            if dirtyCount > 0 then
                local flushed = 0
                for cid, entry in pairs(DirtyFlush._dirty) do
                    -- 避免频繁重试（同一玩家在 interval/2 秒内只刷一次）
                    local now = os.time()
                    local minRetryInterval = math.floor(interval / 2)
                    if now - (entry.last_flush_attempt or 0) >= minRetryInterval then
                        entry.last_flush_attempt = now
                        DirtyFlush.ForceFlush(cid)
                        flushed = flushed + 1
                    end
                end

                stats.flush_count = stats.flush_count + 1
                stats.total_players_flushed = stats.total_players_flushed + flushed
                stats.last_flush_duration = math.floor((os.clock() - startTime) * 1000)

                if flushed > 0 then
                    print(('[persistence] ⏰ Tick flushed %d/%d dirty players in %dms'):format(
                        flushed, dirtyCount, stats.last_flush_duration
                    ))

                    -- 延迟告警
                    if stats.last_flush_duration > 5000 then
                        print(('[persistence] ⚠️ Flush took >5s — consider increasing interval or reducing dirty pool'))
                    end
                end
            end

            ::continue::
        end
    end)
end

-- ==============================================================
-- 紧急刷盘
-- ==============================================================

--- 强制刷盘所有脏玩家（用于服务器关闭/txAdmin 重启/资源停止）
---@return number flushedCount
function PersistenceManager.FlushAll()
    if not DirtyFlush then return 0 end

    local startTime = os.clock()
    local count = 0

    for cid, _ in pairs(DirtyFlush._dirty) do
        DirtyFlush.ForceFlush(cid)
        count = count + 1
    end

    stats.force_count = stats.force_count + 1
    stats.last_flush_duration = math.floor((os.clock() - startTime) * 1000)

    if count > 0 then
        print(('[persistence] 🛑 FlushAll: %d players flushed in %dms'):format(count, stats.last_flush_duration))
    end

    return count
end

--- 强制刷盘单个玩家（用于断线/退出）
---@param citizenid string
function PersistenceManager.ForceFlushPlayer(citizenid)
    if not DirtyFlush or not citizenid then return end
    local wasDirty = DirtyFlush._dirty[citizenid] ~= nil
    DirtyFlush.ForceFlush(citizenid)

    if wasDirty then
        stats.force_count = stats.force_count + 1
    end
end

-- ==============================================================
-- 健康监控
-- ==============================================================

--- 获取持久化统计
---@return table
function PersistenceManager.Stats()
    local result = {
        flush_count = stats.flush_count,
        force_count = stats.force_count,
        last_flush_time = stats.last_flush_time,
        last_flush_duration = stats.last_flush_duration,
        total_players_flushed = stats.total_players_flushed,
        failed_flushes = stats.failed_flushes,
        dirty_pool_size = 0,
    }

    if DirtyFlush then
        local ds = DirtyFlush.Stats()
        result.dirty_pool_size = ds.dirty_count or 0
    end

    return result
end

--- 定期输出健康报告（每 15 分钟）
function PersistenceManager.StartHealthReport()
    CreateThread(function()
        while true do
            Wait(15 * 60 * 1000)

            local s = PersistenceManager.Stats()
            print(('[persistence] 📊 Health Report | Dirty: %d | Flushes: %d | Forces: %d | Total: %d | Last: %dms'):format(
                s.dirty_pool_size, s.flush_count, s.force_count, s.total_players_flushed, s.last_flush_duration
            ))
        end
    end)
end

-- ==============================================================
-- 生命周期钩子
-- ==============================================================
-- ⚠️ playerDropped + txAdmin 关机钩子已由 dirty_flush.lua 统一处理
--    此处不再重复注册，避免双重 ForceFlush + 双轮询循环

-- 1. 资源停止时的全量刷盘保护
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        print('[persistence] ⚠️ Resource stopping, flushing all dirty players...')
        PersistenceManager.FlushAll()
        print('[persistence] ✅ Resource stop flush complete')
    end
end)

-- ==============================================================
-- 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('persistence', {
        StartFlushTick      = PersistenceManager.StartFlushTick,
        FlushAll            = PersistenceManager.FlushAll,
        ForceFlushPlayer    = PersistenceManager.ForceFlushPlayer,
        Stats               = PersistenceManager.Stats,
        StartHealthReport   = PersistenceManager.StartHealthReport,
    })
end

-- ==============================================================
-- 自动启动（默认 15 分钟 tick）
-- ==============================================================

PersistenceManager.StartFlushTick()
PersistenceManager.StartHealthReport()

-- persistence startup prints removed (production mode)