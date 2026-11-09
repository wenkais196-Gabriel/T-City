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

-- DB 回退的加载状态：同一个人只拉一次，失败后短暂退避，避免缓存一冷就被并发打爆。
local loading = {}
local FAIL_BACKOFF_SEC = 30

--- 把 MySQL timestamp 字符串转成 unix 时间（缓存里统一用数字）。
local function toUnixTime(value)
    if type(value) == 'number' then return value end
    if type(value) ~= 'string' then return nil end
    local year, month, day, hour, min, sec =
        value:match('(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)')
    if not year then return nil end
    return os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    })
end

--- 后台预热缓存。**不阻塞调用方**：DB 回来之前 GetTier 返回缓存里的值（没缓存就是 0）。
local function warm(citizenid, after)
    local entry = tierCache[citizenid]
    if entry and (os.time() - entry.cached_at) < CACHE_TTL_SEC
        and not (entry.expires_at and entry.expires_at < os.time()) then
        if after then after(entry.tier) end
        return
    end
    if loading[citizenid] then
        -- 已经有人在拉了：本次不排队（读不该有隐藏代价）
        if after then after(entry and entry.tier or 0) end
        return
    end
    if entry and entry.failed_at and (os.time() - entry.failed_at) < FAIL_BACKOFF_SEC then
        if after then after(entry.tier) end
        return
    end

    loading[citizenid] = true
    exports.oxmysql:prepare(
        'SELECT tier, expires_at FROM patron_records WHERE citizenid = ?',
        { citizenid },
        function(result)
            loading[citizenid] = nil
            local row = result
            if type(row) == 'table' and row[1] ~= nil and row.tier == nil then row = row[1] end

            if type(row) == 'table' and row.tier ~= nil then
                local tier = tonumber(row.tier) or 0
                local expires_at = toUnixTime(row.expires_at)
                if expires_at and expires_at < os.time() then tier = 0 end
                tierCache[citizenid] = { tier = tier, expires_at = expires_at, cached_at = os.time() }
                if after then after(tier) end
                return
            end

            -- DB 失败/无行：给一个短暂退避的 0，别让每次读都去撞库
            tierCache[citizenid] = {
                tier = 0, expires_at = nil, cached_at = os.time(), failed_at = os.time(),
            }
            if after then after(0) end
        end)
end

--- 获取玩家 Patron 等级 —— **只读缓存，不做 IO**。
---
--- 读路径纪律（与 world_state_service 对齐）：绝不在游戏线程上 Await DB。
--- 旧实现用 `promise.new` + `Citizen.Await` 同步查库，第一次读就把服务端主循环卡住
--- （缓存一冷、DB 一慢，调用方就跟着停）；而 `GetTier` 被 `IsActive` / `GetTierBySource`
--- 这类高频入口调用，代价会扩散到每个玩家。
--- 现在的语义：未命中返回 0（= 非 Patron，保守）并在后台预热；需要"现在就要准确值"的
--- 调用方用 GetTierAsync(citizenid, cb)。
---@param citizenid string
---@return number tier 0=普通用户, 1/2/3=Patron
function PatronService.GetTier(citizenid)
    if not citizenid then return 0 end
    local entry = tierCache[citizenid]
    local now = os.time()
    if entry and (now - entry.cached_at) < CACHE_TTL_SEC then
        if entry.expires_at and entry.expires_at < now then
            tierCache[citizenid] = nil
        else
            return entry.tier
        end
    end
    warm(citizenid, nil)
    return 0
end

--- 确定性读取：缓存命中同步回调，未命中后台加载后回调。
---@param citizenid string
---@param cb fun(tier: number)
---@return boolean ok
function PatronService.GetTierAsync(citizenid, cb)
    if type(cb) ~= 'function' then return false end
    if not citizenid then cb(0) return false end
    local entry = tierCache[citizenid]
    local now = os.time()
    if entry and (now - entry.cached_at) < CACHE_TTL_SEC
        and not (entry.expires_at and entry.expires_at < now) then
        cb(entry.tier)
        return true
    end
    warm(citizenid, cb)
    return true
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
        GetTierAsync = PatronService.GetTierAsync,
        SetTier      = PatronService.SetTier,
        IsActive     = PatronService.IsActive,
        GetTierBySource = PatronService.GetTierBySource,
    })
end

print('[patron_service] 💳 Phase 1 就绪: 内存缓存 + DB 异步读写')
