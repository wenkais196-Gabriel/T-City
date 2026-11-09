-- tests/unit/layer3_business/fixtures/patron_probe.lua
-- 真加载 core-framework 的 patron_service.lua。
-- 重点：GetTier 只读缓存、**绝不 Await**；DB 回来之前返回 0 并在后台预热。
--
-- 桩的三处刻意设计（都是 CC 复核点）：
--   * Citizen.Await 直接报错 —— 老实现一走这条路就红；
--   * fake oxmysql 三种模式：正常 / 同步抛错 / 永不回调；
--   * os.time 只有无参时虚拟（可用 state.advance 推进），带表时交给真函数 —— 否则
--     toUnixTime 也会被算错，测出来的东西跟生产不一致。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { queries = 0, pending = {}, mode = 'ok', now = nil }
local realOsTime = os.time
state.now = realOsTime()

Citizen = {
    Await = function()
        error('Citizen.Await would block the game thread', 0)
    end,
    CreateThread = function(fn) return fn end,
    Wait = function() end,
}
promise = { new = function() return { resolve = function() end } end }

os.time = function(table)
    if table then return realOsTime(table) end
    return state.now
end

local function prepare(_, _query, _params, cb)
    state.queries = state.queries + 1
    if state.mode == 'throw' then
        error('oxmysql export is not available', 0)
    end
    if state.mode == 'silent' then
        return
    end
    state.pending[#state.pending + 1] = cb
end

exports = setmetatable({}, {
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return { Functions = { GetPlayer = function() return nil end } } end }
        end
        if name == 'oxmysql' then
            return {
                prepare = prepare,
                execute = function() end,
                insert = function() end,
            }
        end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

Bus = {
    RegisterService = function(name, impl)
        state.service = impl
        state.serviceName = name
    end,
}
DirtyFlush = { MarkDirty = function() end }
print = function() end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/services/patron_service.lua', 'patron_service.lua')

local service = assert(state.service, 'patron 服务没注册到 Bus')

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

local function flush(row)
    local batch = state.pending
    state.pending = {}
    for _, cb in ipairs(batch) do cb(row) end
end

local function advance(seconds)
    state.now = state.now + seconds
end

-- ── 1. 冷缓存：GetTier 立即返回 0，且不 Await、不崩 ──
emit('SCENARIO', 'cold')
local okCold, coldTier = pcall(service.GetTier, 'CID1')
emit('PATRON_COLD_NO_BLOCK', tostring(okCold and coldTier == 0))
emit('PATRON_COLD_ISSUED_QUERY', tostring(state.queries == 1))

-- ── 2. 慢库回调之后：缓存热了，读到真实等级 ──
flush({ tier = 2, expires_at = '2099-01-01 00:00:00' })
emit('PATRON_WARMED_TIER', tostring(safe(service.GetTier, 'CID1') == 2))
emit('PATRON_WARM_NO_EXTRA_QUERY', tostring(state.queries == 1))

-- ── 3. 过期记录 → 0，且只查一次库（不能每读一次都撞库）──
emit('SCENARIO', 'expired')
state.queries = 0
safe(service.GetTier, 'CID2')
flush({ tier = 3, expires_at = '2000-01-01 00:00:00' })
emit('PATRON_EXPIRED_IS_ZERO', tostring(safe(service.GetTier, 'CID2') == 0))
safe(service.GetTier, 'CID2')
emit('PATRON_EXPIRED_SINGLE_QUERY', tostring(state.queries == 1))

-- ── 4. DB 失败：返回 0，退避 30 秒（不是 5 分钟 = CACHE_TTL）──
emit('SCENARIO', 'failure')
state.queries = 0
safe(service.GetTier, 'CID3')
flush(nil)
local afterFail = state.queries
safe(service.GetTier, 'CID3')
emit('PATRON_FAIL_TIER_ZERO', tostring(safe(service.GetTier, 'CID3') == 0))
emit('PATRON_FAIL_BACKOFF_IN_WINDOW', tostring(state.queries == afterFail))

advance(20)
safe(service.GetTier, 'CID3')
emit('PATRON_FAIL_STILL_COOLING_AT_20S', tostring(state.queries == afterFail))

advance(15)   -- 累计 35 秒 > FAIL_BACKOFF_SEC
state.mode = 'ok'
safe(service.GetTier, 'CID3')
emit('PATRON_FAIL_RETRIES_AFTER_30S', tostring(state.queries == afterFail + 1))
flush({ tier = 1, expires_at = '2099-01-01 00:00:00' })
emit('PATRON_RECOVERS_AFTER_BACKOFF', tostring(safe(service.GetTier, 'CID3') == 1))

-- ── 5. 导出同步抛错：不能把 loading 挂住（那个人本来是永久 0）──
emit('SCENARIO', 'sync_error')
state.mode = 'throw'
state.queries = 0
local okThrow, throwTier = pcall(service.GetTier, 'CID4')
emit('PATRON_SYNC_ERROR_NO_CRASH', tostring(okThrow and throwTier == 0))
advance(35)
state.mode = 'ok'
safe(service.GetTier, 'CID4')
emit('PATRON_SYNC_ERROR_RECOVERS', tostring(state.queries == 2))
flush({ tier = 3, expires_at = '2099-01-01 00:00:00' })
emit('PATRON_SYNC_ERROR_TIER', tostring(safe(service.GetTier, 'CID4') == 3))

-- ── 6. 回调永不回来：10 秒看门狗之后允许重试 ──
emit('SCENARIO', 'watchdog')
state.mode = 'silent'
state.queries = 0
safe(service.GetTier, 'CID5')
local firstWatchdog = state.queries
advance(5)
safe(service.GetTier, 'CID5')
emit('PATRON_WATCHDOG_WAITS', tostring(state.queries == firstWatchdog))
advance(10)   -- 累计 15 秒 > LOAD_TIMEOUT_SEC
state.mode = 'ok'
safe(service.GetTier, 'CID5')
emit('PATRON_WATCHDOG_RETRIES', tostring(state.queries == firstWatchdog + 1))

-- ── 7. GetTierAsync：命中同步回调，未命中加载后回调 ──
emit('SCENARIO', 'async')
local hit = nil
safe(service.GetTierAsync, 'CID1', function(tier) hit = tier end)
emit('PATRON_ASYNC_CACHE_HIT', tostring(hit == 2))

local asyncTier = nil
state.queries = 0
safe(service.GetTierAsync, 'CID9', function(tier) asyncTier = tier end)
emit('PATRON_ASYNC_PENDING', tostring(asyncTier == nil and state.queries == 1))
flush({ tier = 1, expires_at = '2099-01-01 00:00:00' })
emit('PATRON_ASYNC_RESOLVED', tostring(asyncTier == 1))

-- ── 8. SetTier 校验仍然有效 ──
emit('SCENARIO', 'set')
emit('PATRON_SET_REJECTS_9', tostring(safe(service.SetTier, 'CID6', 9) == false))
emit('PATRON_SET_ACCEPTS_2', tostring(safe(service.SetTier, 'CID6', 2) == true))
emit('PATRON_SET_CACHE_DIRECT', tostring(safe(service.GetTier, 'CID6') == 2))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
