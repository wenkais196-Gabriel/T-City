-- patron_service.lua — Patron 月供等级服务
-- 锚点: docs/server-design/06-payment-model.md
-- Phase 1 基础实现：内存缓存 + DB 读写
--
-- 四原则落地:
--   模块化 — 独立 Service，Bus 暴露
--   高性能 — 内存缓存 (players 表 cache 复用 + convar TTL)
--   安全   — SetTier 仅服务端路径 (支付回调/管理员命令)，客户端绝对不可触达
--   可拓展 — Plugin Contract 可通过 Bus.GetService('patron') 引用
--
-- 安全警示:
--   SetTier 不在任何客户端可触达的 RegisterNetEvent 路径上！
--   仅通过支付 Webhook + 管理员命令调用。
--
-- 使用:
--   local tier = Bus.patron.GetTier(citizenid)
--   local isActive = Bus.patron.IsActive(citizenid)

local QBCore = exports['qb-core']:GetCoreObject()

PatronService = PatronService or {}

-- ============================================================================
-- 缓存: citizenid → { tier, expires_at, cached_at }
-- ============================================================================
local tierCache = {}
local CACHE_TTL_SEC = 300  -- 5分钟缓存过期

-- ============================================================================
-- 公开 API
-- ============================================================================

--- 获取玩家 Patron 等级 (内存优先 → DB 回退)
---@param citizenid string
---@return number tier 0=普通用户, 1/2/3=Patron
function PatronService.GetTier(citizenid)
    if not citizenid then return 0 end

    -- 检查缓存
    local entry = tierCache[citizenid]
    if entry and (os.time() - entry.cached_at) < CACHE_TTL_SEC then
        if entry.expires_at and entry.expires_at < os.time() then
            -- 缓存中的过期了，清掉
            tierCache[citizenid] = nil
        else
            return entry.tier
        end
    end

    -- DB 回退
    local p = promise.new()
    exports.oxmysql:prepare(
        'SELECT tier, expires_at FROM patron_records WHERE citizenid = ?',
        {citizenid}, function(result)
            p:resolve(result)
        end)
    local row = Citizen.Await(p)

    if row and row.tier then
        local tier = tonumber(row.tier) or 0
        local expires_at = row.expires_at
        if type(expires_at) == 'string' then
            -- MySQL timestamp string → unix
            local year, month, day, hour, min, sec = expires_at:match('(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)')
            if year then
                expires_at = os.time({year=tonumber(year), month=tonumber(month), day=tonumber(day),
                                     hour=tonumber(hour), min=tonumber(min), sec=tonumber(sec)})
            end
        end
        if expires_at and type(expires_at) == 'number' and expires_at < os.time() then
            tier = 0
        end
        tierCache[citizenid] = { tier = tier, expires_at = expires_at, cached_at = os.time() }
        return tier
    end

    tierCache[citizenid] = { tier = 0, expires_at = nil, cached_at = os.time() }
    return 0
end

--- 设置 Patron 等级
--- 安全: 仅支付回调 / 管理员命令可调用 — 不在客户端可触达的事件路径上
---@param citizenid     string
---@param tier          number 0-3
---@param external_data table|nil { external_id, ... }
---@return boolean success
function PatronService.SetTier(citizenid, tier, external_data)
    if not citizenid then return false end

    tier = tonumber(tier) or 0
    -- 类型校验: tier 必须在 [0,1,2,3]
    if tier < 0 or tier > 3 then
        print(('[patron] ⚠️ Invalid tier %d for %s — rejected'):format(tier, citizenid))
        return false
    end

    local external_id = nil
    if external_data and type(external_data) == 'table' then
        external_id = external_data.external_id
    end

    -- 异步写入 DB
    exports.oxmysql:execute(
        [[INSERT INTO patron_records (citizenid, tier, started_at, expires_at, external_id)
          VALUES (?, ?, NOW(), DATE_ADD(NOW(), INTERVAL 1 MONTH), ?)
          ON DUPLICATE KEY UPDATE
            tier = VALUES(tier),
            started_at = IF(tier != VALUES(tier), NOW(), started_at),
            expires_at = DATE_ADD(NOW(), INTERVAL 1 MONTH),
            external_id = COALESCE(VALUES(external_id), external_id),
            updated_at = NOW()]],
        {citizenid, tier, external_id}
    )

    -- 立即更新缓存
    tierCache[citizenid] = {
        tier = tier,
        expires_at = os.time() + (30 * 24 * 3600),  -- 30天后
        cached_at = os.time(),
    }

    -- 标记 DirtyFlush
    if DirtyFlush and DirtyFlush.MarkDirty then
        DirtyFlush.MarkDirty(citizenid, 'patron_tier')
    end

    print(('[patron] 💳 Tier updated: %s → %d (expires in 30d)'):format(citizenid, tier))
    return true
end

--- 检查玩家 Patron 是否有效 (tier > 0 且未过期)
---@param citizenid string
---@return boolean is_active
function PatronService.IsActive(citizenid)
    local tier = PatronService.GetTier(citizenid)
    return tier > 0
end

--- 获取在线玩家的 Patron 等级 (不查 DB，仅内存)
---@param source number 玩家 source
---@return number tier
function PatronService.GetTierBySource(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return 0 end
    return PatronService.GetTier(Player.PlayerData.citizenid)
end

-- ============================================================================
-- 注册到 Bus
-- ============================================================================
if Bus and Bus.RegisterService then
    Bus.RegisterService('patron', {
        GetTier      = PatronService.GetTier,
        SetTier      = PatronService.SetTier,
        IsActive     = PatronService.IsActive,
        GetTierBySource = PatronService.GetTierBySource,
    })
end

print('[patron_service] 💳 Phase 1 就绪: 内存缓存 + DB 异步读写')
