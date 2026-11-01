-- persistence_manager.lua — 玩家存档的**唯一写者**（P1-1 / P1-2，2026-11-01）
--
-- 为什么重写（见 docs/engineering/2026-11-foundation-plan.md）:
--   1. 环：core-framework 的 ForceFlush 调 `Player.Functions.Save(true)`，而 Save(true)
--      又会 `DirtyFlush.ForceFlush`。两套实现一旦指向同一个脏池就是无限递归
--      （离线复现：399,964 层栈，见 tests/unit/layer1_core/test_persistence_single_owner.py）。
--      本文件**不再从刷盘路径回调 Save**。
--   2. 双写者：qb-core 与 core-framework 各有一个脏池 + 各有一个 900s 定时器，
--      互相看不见。core-framework 那份已降级为 delegate，池子只剩这里一份。
--   3. 失败即清：以前无论 `MySQL.insert` 成不成，脏标记都清。现在只有写成功才清，
--      失败保留 + 指数退避 + `failed_flushes` 计数，重试时用 PlayerData 快照
--      （玩家已下线也能补写）。
--
-- 对外契约（player.lua / core-framework / Bus 都按这个调）:
--   Store.MarkDirty(citizenid, dataType[, PlayerData])
--   Store.SaveNow(playerOrCitizenId, reason) -> ok, err
--   Store.ForceFlush(citizenid|nil) -> 单人或全员（忽略退避）
--   Store.FlushAll(reason[, ignoreBackoff]) -> ack { attempted, ok, failed, duration_ms, reason }
--   Store.Stats() -> { dirty_pool_size, failed_flushes, ... }
-- 兼容别名：`_G.DirtyFlush` / `Bus.PersistenceManager` 都指向 Store。

-- qb-core 的 QBCore 全局由 server/main.lua 建立，而本文件在它之前加载 →
-- 只能在**调用时**解析，不能在文件顶层取（否则重启时整份脚本在这一行就中断）。
local function core()
    if _G.QBCore then return _G.QBCore end
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok then return obj end
    return nil
end

local INSERT_SQL = 'INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata) VALUES (:citizenid, :cid, :license, :name, :money, :charinfo, :job, :gang, :position, :metadata) ON DUPLICATE KEY UPDATE cid = :cid, name = :name, money = :money, charinfo = :charinfo, job = :job, gang = :gang, position = :position, metadata = :metadata'

--- 墙钟毫秒。TS-8：不要用 os.clock 冒充阻塞时长（它测的是 CPU 时间，await 的等待不计入）。
local function wallMs()
    if GetGameTimer then return math.floor(GetGameTimer()) end
    return math.floor(os.clock() * 1000)
end

local BACKOFF_MIN_SEC = 15
local BACKOFF_MAX_SEC = 3600

local Store = {
    _dirty = {},
    _tick_started = false,
    _stats = {
        flush_count = 0,
        force_count = 0,
        last_flush_time = 0,
        last_flush_duration = 0,
        total_players_flushed = 0,
        failed_flushes = 0,
        last_error = nil,
    },
}

-- ==============================================================
-- 配置
-- ==============================================================

local function flushInterval()
    local interval = tonumber(GetConvar('persistence_flush_interval', '900')) or 900
    if interval < 30 then interval = 30 end
    return interval
end

--- 失败后的退避秒数：interval/2 起步，按尝试次数翻倍，封顶 1 小时。
function Store.BackoffSeconds(attempts)
    local base = math.max(BACKOFF_MIN_SEC, math.floor(flushInterval() / 2))
    local backoff = base * (2 ^ math.max(0, (attempts or 1) - 1))
    if backoff > BACKOFF_MAX_SEC then backoff = BACKOFF_MAX_SEC end
    return math.floor(backoff)
end

-- ==============================================================
-- 快照：DB 行要什么，这里就取什么
-- ==============================================================

--- 坐标/血量：ped 不在（下线、断线）时回落到上次持久化位置，绝不写 0,0,0。
function Store.ResolveCoords(PlayerData)
    local src = PlayerData and PlayerData.source
    local ped = (src and src ~= 0) and GetPlayerPed(src) or 0
    if ped and ped ~= 0 then
        local coords = GetEntityCoords(ped)
        local health = GetEntityHealth(ped)
        if health and health > 0 and PlayerData.metadata then
            PlayerData.metadata['health'] = health
        end
        return coords
    end
    local pos = PlayerData and PlayerData.position
    if pos then
        return vector3(pos.x or 0.0, pos.y or 0.0, pos.z or 0.0)
    end
    return vector3(0.0, 0.0, 0.0)
end

local function buildParams(PlayerData, coords)
    return {
        citizenid = PlayerData.citizenid,
        cid = tonumber(PlayerData.cid),
        license = PlayerData.license,
        name = PlayerData.name,
        money = json.encode(PlayerData.money),
        charinfo = json.encode(PlayerData.charinfo),
        job = json.encode(PlayerData.job),
        gang = json.encode(PlayerData.gang),
        position = json.encode(coords),
        metadata = json.encode(PlayerData.metadata),
    }
end

-- ==============================================================
-- 写库：唯一出口
-- ==============================================================

--- 同步写一行，返回 ok, err。只有 oxmysql 的 `.await` 能给出确定的成功/失败，
--- 其它驱动（回调式、失败不回调）一律视为**未确认**，脏标记保留。
local function writeRow(params)
    local driver = MySQL and MySQL.insert
    if not driver then return false, 'mysql_unavailable' end
    local awaitFn = driver.await
    if awaitFn then
        local ok, err = pcall(awaitFn, INSERT_SQL, params)
        if not ok then return false, tostring(err) end
        return true, nil
    end
    if type(driver) == 'function' then
        driver(INSERT_SQL, params, function() end)
        return false, 'async_driver_no_ack'
    end
    return false, 'mysql_insert_unavailable'
end

local function playerFor(citizenid)
    local qb = core()
    if not qb or not qb.Functions then return nil end
    return qb.Functions.GetPlayerByCitizenId(citizenid)
end

-- rev 是脏条目的版本号：写库期间（await 会让出）玩家可能又被改了，
-- 那种情况下这次写进去的不是最新状态 —— 条目必须留着，否则新改动被静默吞掉。
local function noteSuccess(entry, coords, rev)
    Store._stats.total_players_flushed = Store._stats.total_players_flushed + 1
    Store._stats.last_flush_time = os.time()

    entry.attempts = 0
    entry.next_attempt = 0
    entry.last_error = nil

    if (entry.rev or 0) ~= (rev or 0) then
        -- 写库期间又被标脏：保留条目交给下一轮，IsDirty 也不要清
        return false
    end

    Store._dirty[entry.citizenid] = nil

    local Player = playerFor(entry.citizenid)
    if Player then
        Player.IsDirty = false
        if coords then Player.LastSavedCoords = coords end
    end

    return true
end

local function noteFailure(entry, err)
    entry.attempts = (entry.attempts or 0) + 1
    entry.last_error = tostring(err)
    entry.next_attempt = os.time() + Store.BackoffSeconds(entry.attempts)

    Store._stats.failed_flushes = Store._stats.failed_flushes + 1
    Store._stats.last_error = entry.last_error

    print(('[persistence] ❌ Flush failed for %s (attempt %d): %s — retry in %ds')
        :format(entry.citizenid, entry.attempts, entry.last_error, Store.BackoffSeconds(entry.attempts)))
end

-- ==============================================================
-- 公开 API
-- ==============================================================

--- 标脏。dataType 只用于诊断；PlayerData 快照让玩家离线后仍能补写。
function Store.MarkDirty(citizenid, dataType, PlayerData)
    if not citizenid then return false end

    local Player = playerFor(citizenid)
    local snapshot = PlayerData or (Player and Player.PlayerData)
    local entry = Store._dirty[citizenid]

    -- 既没有快照也没有在线玩家 → 不是玩家 key（例如 world_state 的 `region:key`），
    -- 本 Store 写的是 players 表，收进来只会变成永远写不掉、也永远退避的僵尸条目。
    if not entry and not snapshot then
        return false
    end

    if not entry then
        entry = { citizenid = citizenid, attempts = 0, next_attempt = 0 }
        Store._dirty[citizenid] = entry
    end

    entry.dataType = dataType or entry.dataType or 'all'
    entry.marked_at = os.time()
    entry.rev = (entry.rev or 0) + 1
    if snapshot then entry.PlayerData = snapshot end
    if Player then Player.IsDirty = true end

    return true
end

--- 立即写一个玩家（**不经过 Player.Functions.Save**，这是拆环的关键）。
---@param target table|string Player 对象或 citizenid
---@param reason string 'save_force' | 'player_drop' | 'tick' | 'resource_stop' | ...
---@return boolean ok, string|nil err
function Store.SaveNow(target, reason)
    reason = reason or 'manual'

    local citizenid, PlayerData
    if type(target) == 'table' then
        PlayerData = target.PlayerData
        citizenid = PlayerData and PlayerData.citizenid
    elseif type(target) == 'string' then
        citizenid = target
    end
    if not citizenid then return false, 'no_target' end

    local Player = (type(target) == 'table') and target or playerFor(citizenid)
    local entry = Store._dirty[citizenid]

    PlayerData = PlayerData or (entry and entry.PlayerData) or (Player and Player.PlayerData)
    if not PlayerData then
        -- 没有快照也没有在线玩家：不是本 Store 管得着的 key，别建僵尸条目
        return false, 'no_playerdata'
    end

    if not entry then
        entry = { citizenid = citizenid, attempts = 0, next_attempt = 0, dataType = 'all' }
        Store._dirty[citizenid] = entry
    end
    entry.PlayerData = PlayerData

    local coords = Store.ResolveCoords(PlayerData)
    local rev = entry.rev or 0
    local ok, err = writeRow(buildParams(PlayerData, coords))

    if ok then
        local clean = noteSuccess(entry, coords, rev)
        return true, clean and nil or 'rewritten_while_flushing'
    end

    noteFailure(entry, err)
    return false, entry.last_error
end

--- 兼容旧入口：`DirtyFlush.ForceFlush(cid)`（忽略退避）；nil = 刷全部。
function Store.ForceFlush(citizenid)
    if citizenid then return Store.SaveNow(citizenid, 'force') end
    return Store.FlushAll('force_all', true)
end

--- 批量刷盘。ack 是**可读的**：谁、刷了几个、成几个、花多久。
---@param reason string
---@param ignoreBackoff boolean|nil 停服/资源停止时传 true
---@return table ack
function Store.FlushAll(reason, ignoreBackoff)
    reason = reason or 'manual'
    local started = wallMs()
    local now = os.time()

    local due = {}
    local seen = {}
    for citizenid, entry in pairs(Store._dirty) do
        seen[citizenid] = true
        if ignoreBackoff or (entry.next_attempt or 0) <= now then
            due[#due + 1] = citizenid
        end
    end

    -- 兜底：`IsDirty = true` 但没进池子的玩家（economy_service / metadata_service 只标
    -- IsDirty，不 MarkDirty）。没有这一条，他们的钱和 metadata 只会在下线时才落库。
    -- 已经在池子里的不重复加：池子里的退避优先级更高。
    local qb = core()
    if qb and qb.Players then
        for _, Player in pairs(qb.Players) do
            local PlayerData = Player and Player.PlayerData
            local citizenid = PlayerData and PlayerData.citizenid
            if citizenid and not seen[citizenid] and Player.IsDirty then
                Store._dirty[citizenid] = {
                    citizenid = citizenid, attempts = 0, next_attempt = 0,
                    dataType = 'isdirty_scan', marked_at = now, PlayerData = PlayerData,
                }
                seen[citizenid] = true
                due[#due + 1] = citizenid
            end
        end
    end
    table.sort(due)

    local ack = { reason = reason, attempted = 0, ok = 0, failed = 0, duration_ms = 0 }

    for _, citizenid in ipairs(due) do
        ack.attempted = ack.attempted + 1
        local ok = Store.SaveNow(citizenid, reason)
        if ok then ack.ok = ack.ok + 1 else ack.failed = ack.failed + 1 end
    end

    ack.duration_ms = wallMs() - started

    Store._stats.flush_count = Store._stats.flush_count + 1
    Store._stats.force_count = Store._stats.force_count + 1
    Store._stats.last_flush_duration = ack.duration_ms
    Store._stats.last_flush_time = os.time()

    if ack.attempted > 0 then
        print(('[persistence] 💾 FlushAll(%s): attempted=%d ok=%d failed=%d in %dms | pending=%d')
            :format(reason, ack.attempted, ack.ok, ack.failed, ack.duration_ms, Store.DirtyCount()))
        if ack.failed > 0 then
            print(('[persistence] ⚠️ %d player(s) stayed dirty after %s — 下次 tick 退避重试')
                :format(Store.DirtyCount(), reason))
        end
    end

    return ack
end

function Store.DirtyCount()
    local count = 0
    for _ in pairs(Store._dirty) do count = count + 1 end
    return count
end

function Store.Stats()
    local stats = Store._stats
    return {
        flush_count = stats.flush_count,
        force_count = stats.force_count,
        last_flush_time = stats.last_flush_time,
        last_flush_duration = stats.last_flush_duration,
        total_players_flushed = stats.total_players_flushed,
        failed_flushes = stats.failed_flushes,
        last_error = stats.last_error,
        dirty_pool_size = Store.DirtyCount(),
        -- 兼容旧字段：bus.lua 的 DirtyFlushStats 以前返回 dirty_count，
        -- custom-testing/stress_test.lua 与 tests/architecture_stress_test.lua 还在读它。
        dirty_count = Store.DirtyCount(),
    }
end

-- ==============================================================
-- 唯一的定时器
-- ==============================================================

function Store.StartFlushTick(intervalSec)
    if Store._tick_started then return false end
    Store._tick_started = true

    local interval = intervalSec or flushInterval()
    if interval < 30 then interval = 30 end

    print(('[persistence] ⏰ Flush tick started: every %d seconds (owner=qb-core)'):format(interval))

    CreateThread(function()
        while true do
            Wait(interval * 1000)
            Store.FlushAll('tick')
        end
    end)

    return true
end

function Store.StartHealthReport()
    CreateThread(function()
        while true do
            Wait(15 * 60 * 1000)
            local s = Store.Stats()
            print(('[persistence] 📊 Health | dirty=%d flushes=%d failed=%d total=%d last=%dms')
                :format(s.dirty_pool_size, s.flush_count, s.failed_flushes,
                        s.total_players_flushed, s.last_flush_duration))
        end
    end)
end

-- ==============================================================
-- 生命周期：停服刷盘要有 ack
-- ==============================================================

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    print('[persistence] ⚠️ qb-core stopping — flushing dirty players before unload')
    local ack = Store.FlushAll('resource_stop', true)
    print(('[persistence] ✅ resource_stop flush complete: ok=%d failed=%d pending=%d')
        :format(ack.ok, ack.failed, Store.DirtyCount()))
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    local ack = Store.FlushAll('server_shutdown', true)
    print(('[persistence] ✅ server_shutdown flush complete: ok=%d failed=%d')
        :format(ack.ok, ack.failed))
end)

-- ==============================================================
-- 对外暴露：全局 / Bus / exports
-- ==============================================================

-- qb-core 没有 include core-framework 的 bus.lua（Bus 只是一个普通的 _G 表），
-- 所以这里不注册 Bus 服务：`service_persistence_*` 由 core-framework 的 delegate 提供。
_G.DirtyFlush = Store
_G.PlayerStore = Store
if not _G.Bus then _G.Bus = {} end
_G.Bus.PersistenceManager = Store

exports('StoreMarkDirty', Store.MarkDirty)
exports('StoreSaveNow', Store.SaveNow)
exports('StoreForceFlush', Store.ForceFlush)
exports('StoreFlushAll', Store.FlushAll)
exports('StoreStats', Store.Stats)

print('[persistence] ✅ single owner store loaded (dirty pool / timer / SQL writer)')

Store.StartFlushTick()
Store.StartHealthReport()
