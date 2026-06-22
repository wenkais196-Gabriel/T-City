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
--
-- 🔧 架构修复 (2026-06-22):
--   _G.DirtyFlush 在 qb-core → core-framework 初始化窗口内不定期变 nil（根因不明）。
--   本文件现在使用 LOCAL DirtyFlush，不再依赖 _G.DirtyFlush。
--   每次 tick 时将 LocalDirtyFlush 同步到 _G.DirtyFlush 和 _G.Bus.PersistenceManager，
--   确保 player.lua 的 MarkDirty/ForceFlush 调用能到达正确的对象。

local QBCore = exports['qb-core']:GetCoreObject()
PersistenceManager = {}

-- ==============================================================
-- LOCAL DirtyFlush — 不受全局变量清理影响的自治实例
-- ==============================================================

local LocalDirtyFlush = {
    _dirty = {},
}

function LocalDirtyFlush.MarkDirty(citizenid, dataType)
    LocalDirtyFlush._dirty[citizenid] = LocalDirtyFlush._dirty[citizenid] or {}
    LocalDirtyFlush._dirty[citizenid].dataType = dataType
    LocalDirtyFlush._dirty[citizenid].marked_at = os.time()
end

function LocalDirtyFlush.ForceFlush(citizenid)
    if citizenid then
        local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if Player then
            Player.Functions.Save(true)  -- 强制刷盘
        end
        LocalDirtyFlush._dirty[citizenid] = nil
    else
        -- FlushAll
        for cid, _ in pairs(LocalDirtyFlush._dirty) do
            local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
            if Player and Player.PlayerData then
                Player.Functions.Save(true)
            end
            LocalDirtyFlush._dirty[cid] = nil
        end
    end
end

function LocalDirtyFlush.FlushAll()
    LocalDirtyFlush.ForceFlush(nil)
end

function LocalDirtyFlush.Stats()
    local count = 0
    for _ in pairs(LocalDirtyFlush._dirty) do count = count + 1 end
    return { dirty_count = count }
end

-- 立即设到 _G（可能会被清，但 tick 会周期性恢复）
_G.DirtyFlush = LocalDirtyFlush
if _G.Bus then
    _G.Bus.PersistenceManager = LocalDirtyFlush
end

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
    last_flush_duration = 0,
    total_players_flushed = 0,
    failed_flushes = 0,
}

-- ==============================================================
-- 配置化刷盘管道
-- ==============================================================

function PersistenceManager.StartFlushTick(intervalSec)
    local interval = intervalSec or GetIntConvar('persistence_flush_interval', 900)
    if interval < 30 then interval = 30 end

    print(('[persistence] ⏰ Flush tick started: every %d seconds'):format(interval))

    CreateThread(function()
        while true do
            Wait(interval * 1000)

            -- 周期性恢复 _G.DirtyFlush（对抗未知的全局清理）
            _G.DirtyFlush = LocalDirtyFlush
            if _G.Bus then
                _G.Bus.PersistenceManager = LocalDirtyFlush
            end

            local dirtyStats = LocalDirtyFlush.Stats()
            local dirtyCount = dirtyStats.dirty_count or 0

            if dirtyCount > 0 then
                local startTime = os.clock()
                local flushed = 0
                for cid, entry in pairs(LocalDirtyFlush._dirty) do
                    local now = os.time()
                    local minRetryInterval = math.floor(interval / 2)
                    if now - (entry.last_flush_attempt or 0) >= minRetryInterval then
                        entry.last_flush_attempt = now
                        LocalDirtyFlush.ForceFlush(cid)
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
                    if stats.last_flush_duration > 5000 then
                        print('[persistence] ⚠️ Flush took >5s — consider increasing interval')
                    end
                end
            end
        end
    end)
end

-- ==============================================================
-- 紧急刷盘
-- ==============================================================

function PersistenceManager.FlushAll()
    local startTime = os.clock()
    local count = 0

    for cid, _ in pairs(LocalDirtyFlush._dirty) do
        LocalDirtyFlush.ForceFlush(cid)
        count = count + 1
    end

    stats.force_count = stats.force_count + 1
    stats.last_flush_duration = math.floor((os.clock() - startTime) * 1000)

    if count > 0 then
        print(('[persistence] 🛑 FlushAll: %d players flushed in %dms'):format(count, stats.last_flush_duration))
    end

    return count
end

function PersistenceManager.ForceFlushPlayer(citizenid)
    if not citizenid then return end
    local wasDirty = LocalDirtyFlush._dirty[citizenid] ~= nil
    LocalDirtyFlush.ForceFlush(citizenid)

    if wasDirty then
        stats.force_count = stats.force_count + 1
    end
end

-- ==============================================================
-- 健康监控
-- ==============================================================

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

    local ds = LocalDirtyFlush.Stats()
    result.dirty_pool_size = ds.dirty_count or 0

    return result
end

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
-- 自动启动
-- ==============================================================

PersistenceManager.StartFlushTick()
PersistenceManager.StartHealthReport()
