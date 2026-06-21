-- metadata_service.lua — 玩家元数据内存服务（Public API 层）
--
-- 架构分层:
--   core-framework/services/*  = Public API (source-based, Bus-registered, external-facing)
--   qb-core/server/services/*  = Engine Room (citizenid-based, low-level, internal)
--   本文件是 core-framework 层 — 供第三方模组通过 Bus 调用
--
-- 管理 job/gang/metadata 的内存缓存 + dirty 标记
--
-- 使用:
--   MetadataService.GetJob(source)       → 获取玩家职业
--   MetadataService.SetJob(source, job)  → 设置职业 + 标记 dirty
--   MetadataService.GetGang(source)      → 获取帮派
--   MetadataService.SaveAll(source)      → 强制刷盘

local QBCore = exports['qb-core']:GetCoreObject()

MetadataService = MetadataService or {}

-- 内存缓存: citizenid → { job, gang, metadata, last_updated }
local cache = {}

-- ==============================================================
-- 内部辅助
-- ==============================================================

local function getPlayer(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return nil end
    local cid = Player.PlayerData.citizenid
    if not cache[cid] then
        cache[cid] = {
            job      = Player.PlayerData.job,
            gang     = Player.PlayerData.gang,
            metadata = Player.PlayerData.metadata,
            dirty    = {},
            last_updated = os.time(),
        }
    end
    return Player, cid, cache[cid]
end

-- ==============================================================
-- 公共 API
-- ==============================================================

--- 获取玩家职业（内存优先）
function MetadataService.GetJob(source)
    local Player, cid, entry = getPlayer(source)
    if not Player then return nil end
    return entry.job or Player.PlayerData.job
end

--- 设置玩家职业
function MetadataService.SetJob(source, job, reason)
    local Player, cid, entry = getPlayer(source)
    if not Player then return false end
    entry.job = job
    entry.dirty.job = true
    entry.last_updated = os.time()
    Player.PlayerData.job = job
    if DirtyFlush then DirtyFlush.MarkDirty(cid, 'metadata') end
    return true
end

--- 获取帮派（内存优先）
function MetadataService.GetGang(source)
    local Player, cid, entry = getPlayer(source)
    if not Player then return nil end
    return entry.gang or Player.PlayerData.gang
end

--- 获取元数据字段（内存优先）
function MetadataService.GetMetadata(source, key)
    local Player, cid, entry = getPlayer(source)
    if not Player then return nil end
    if key then
        return (entry.metadata or Player.PlayerData.metadata)[key]
    end
    return entry.metadata or Player.PlayerData.metadata
end

--- 设置元数据字段
function MetadataService.SetMetadata(source, key, value)
    local Player, cid, entry = getPlayer(source)
    if not Player then return false end
    if not entry.metadata then
        entry.metadata = Player.PlayerData.metadata
    end
    entry.metadata[key] = value
    entry.dirty.metadata = true
    entry.last_updated = os.time()
    if DirtyFlush then DirtyFlush.MarkDirty(cid, 'metadata') end
    return true
end

--- 强制刷新玩家到数据库
function MetadataService.SaveAll(source)
    local Player, cid, entry = getPlayer(source)
    if not Player then return false end
    if Player.Functions.Save then
        Player.Functions.Save()
    end
    entry.dirty = {}
    return true
end

--- 清除玩家缓存（下线时调用）
function MetadataService.ClearCache(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    cache[Player.PlayerData.citizenid] = nil
end

-- ==============================================================
-- 注册到 Bus
-- ==============================================================
if Bus and Bus.RegisterService then
    Bus.RegisterService('metadata', {
        GetJob      = MetadataService.GetJob,
        SetJob      = MetadataService.SetJob,
        GetGang     = MetadataService.GetGang,
        GetMetadata = MetadataService.GetMetadata,
        SetMetadata = MetadataService.SetMetadata,
        SaveAll     = MetadataService.SaveAll,
    })
end

-- metadata-service startup prints removed (production mode)
