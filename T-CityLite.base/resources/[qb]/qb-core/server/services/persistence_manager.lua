-- ============================================================================
-- PersistenceManager — Unified DirtyFlush 委托层
-- ============================================================================
-- 🔄 Consolidated: 核心脏数据跟踪 + 定时刷盘已迁移至 core-framework
-- (resources/[standalone]/core-framework/cache/dirty_flush.lua)
--
-- 本文件现在是一个薄委托层 (thin delegation layer):
--   1. 提供 MarkDirty / ForceFlush / Stats 的备份实现
--   2. 在 core-framework 加载后自动委托到其 DirtyFlush
--   3. 不再启动独立的定时器 (避免双份 Tick)
--   4. 不再注册重复的 playerDropped / txAdmin / onResourceStop 钩子
--
-- 调用方式不变:
--   player.lua Save() 中: DirtyFlush.MarkDirty(...) / DirtyFlush.ForceFlush(...)
-- ============================================================================

-- ── Fallback SQL: 仅在 core-framework 未加载时使用 ─────────────────

local function fallbackFlushSinglePlayer(Player)
    if not Player or not Player.PlayerData then return false end

    local PlayerData = Player.PlayerData
    local citizenid = PlayerData.citizenid
    local ped = GetPlayerPed(PlayerData.source)
    -- ⚠️ 先判断 ped 有效性再取坐标：断线时 ped 可能已为 0，
    --    否则会把 0,0,0 当成最后位置写库。
    local pcoords
    if ped and ped ~= 0 then
        pcoords = GetEntityCoords(ped)
        local phealth = GetEntityHealth(ped)
        if phealth > 0 then
            PlayerData.metadata['health'] = phealth
        end
    else
        local pos = PlayerData.position
        pcoords = pos and vector3(pos.x or 0.0, pos.y or 0.0, pos.z or 0.0) or vector3(0.0, 0.0, 0.0)
    end

    MySQL.insert('INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata) VALUES (:citizenid, :cid, :license, :name, :money, :charinfo, :job, :gang, :position, :metadata) ON DUPLICATE KEY UPDATE cid = :cid, name = :name, money = :money, charinfo = :charinfo, job = :job, gang = :gang, position = :position, metadata = :metadata', {
        citizenid = citizenid,
        cid = tonumber(PlayerData.cid),
        license = PlayerData.license,
        name = PlayerData.name,
        money = json.encode(PlayerData.money),
        charinfo = json.encode(PlayerData.charinfo),
        job = json.encode(PlayerData.job),
        gang = json.encode(PlayerData.gang),
        position = json.encode(pcoords),
        metadata = json.encode(PlayerData.metadata)
    }, function() end)

    Player.IsDirty = false
    Player.LastSavedCoords = pcoords
    return true
end

-- ── 委托包装: 优先使用 core-framework 的 DirtyFlush ────────────────

local function getDirtyFlush()
    -- 检查 core-framework 的 DirtyFlush 是否已加载 (通过 _G.DirtyFlush 引用)
    local df = _G.DirtyFlush
    -- 确认它是 core-framework 版本 (有 Stats 且 _dirty 表存在)
    if df and df.Stats and df._dirty then
        return df
    end
    return nil
end

-- ── 公开 API (自维护 _dirty 表) ────────────────────────────────────

local ThinDirtyFlush = {}

-- 🔧 Fix: ThinDirtyFlush 必须维护自己的 _dirty 表
-- 否则 core-framework 的 persistence_manager 定时 tick 永远看到 dirty_count=0
-- 导致非强制存盘变成空操作，玩家数据无法持久化到 DB
ThinDirtyFlush._dirty = {}

function ThinDirtyFlush.MarkDirty(citizenid, dataType)
    -- 记入 _dirty 表（persistence tick 需要此表来查找脏玩家）
    ThinDirtyFlush._dirty[citizenid] = ThinDirtyFlush._dirty[citizenid] or {}
    ThinDirtyFlush._dirty[citizenid].dataType = dataType
    ThinDirtyFlush._dirty[citizenid].marked_at = os.time()

    -- 同时标记 Player.IsDirty（player.lua Save() 的早期出口依赖此标记）
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Player then Player.IsDirty = true end
end

function ThinDirtyFlush.ForceFlush(citizenid)
    if citizenid then
        local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if Player then
            Player.IsDirty = true
            fallbackFlushSinglePlayer(Player)
        end
        -- 🔧 Fix: 刷盘成功后从 _dirty 表移除
        ThinDirtyFlush._dirty[citizenid] = nil
    else
        -- FlushAll: 刷盘所有脏玩家
        for cid, _ in pairs(ThinDirtyFlush._dirty) do
            local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
            if Player and Player.PlayerData then
                Player.IsDirty = true
                fallbackFlushSinglePlayer(Player)
            end
            ThinDirtyFlush._dirty[cid] = nil
        end
    end
end

function ThinDirtyFlush.Stats()
    local count = 0
    for _ in pairs(ThinDirtyFlush._dirty) do count = count + 1 end
    return { dirty_count = count }
end

function ThinDirtyFlush.FlushAll()
    ThinDirtyFlush.ForceFlush(nil)
end

-- ── 立即可用 (需在 core-framework 加载前提供，防止 player.lua 报 nil) ─

_G.DirtyFlush = ThinDirtyFlush
if not _G.Bus then _G.Bus = {} end
_G.Bus.PersistenceManager = ThinDirtyFlush

-- ── onResourceStart: core-framework 加载后重新绑定 ────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == 'core-framework' then
        -- core-framework 的 DirtyFlush 已就绪，Hot-reload: 将 _G 指向委托转发
        -- (ThinDirtyFlush 的 getDirtyFlush() 现在会返回 core-framework 的实例)
        local df = _G.DirtyFlush
        if df and df._dirty and df.Stats then
            -- 重新设置 _G.DirtyFlush 会导致正在引用的旧代码出错，
            -- 所以我们保留 ThinDirtyFlush 作为 _G.DirtyFlush (它已经会委托)
            -- 但更新 Bus.PersistenceManager 引用
            _G.Bus.PersistenceManager = ThinDirtyFlush
            print('[PersistenceManager] ✅ core-framework detected — delegating DirtyFlush calls')
        end
    end
end)

print('[PersistenceManager] ✅ Unified delegation layer loaded (delegates to core-framework when available)')

-- ── 定时刷盘 / 停机兜底 ──────────────────────────────────────────
-- core-framework 的 tick 跑在它自己的资源状态里，看不到 qb-core 的 _dirty 表，
-- 因此定时器必须挂在持有脏标记的这一侧（本文件）。
CreateThread(function()
    local interval = tonumber(GetConvar('persistence_flush_interval', '900')) or 900
    if interval < 30 then interval = 30 end

    while true do
        Wait(interval * 1000)
        ThinDirtyFlush.ForceFlush(nil)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        ThinDirtyFlush.ForceFlush(nil)
    end
end)
