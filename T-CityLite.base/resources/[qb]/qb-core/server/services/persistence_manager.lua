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
    local pcoords = GetEntityCoords(ped)

    if ped and ped ~= 0 then
        local phealth = GetEntityHealth(ped)
        if phealth > 0 then
            PlayerData.metadata['health'] = phealth
        end
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

-- ── 公开 API (委托 + fallback) ────────────────────────────────────

local ThinDirtyFlush = {}

function ThinDirtyFlush.MarkDirty(citizenid, dataType)
    local df = getDirtyFlush()
    if df then
        df.MarkDirty(citizenid, dataType)
    else
        -- Fallback: 直接标记 Player.IsDirty
        local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if Player then Player.IsDirty = true end
    end
end

function ThinDirtyFlush.ForceFlush(citizenid)
    local df = getDirtyFlush()
    if df then
        df.ForceFlush(citizenid)
    else
        if citizenid then
            local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
            if Player then Player.IsDirty = true; fallbackFlushSinglePlayer(Player) end
        else
            for _, Player in pairs(QBCore.Players) do
                if Player and Player.PlayerData then
                    Player.IsDirty = true
                    fallbackFlushSinglePlayer(Player)
                end
            end
        end
    end
end

function ThinDirtyFlush.Stats()
    local df = getDirtyFlush()
    if df then return df.Stats() end
    return { dirty_count = 0 }
end

function ThinDirtyFlush.FlushAll()
    local df = getDirtyFlush()
    if df then return df.FlushAll() end
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
