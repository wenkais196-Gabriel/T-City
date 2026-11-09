-- tests/unit/layer3_business/fixtures/patron_probe.lua
-- 真加载 core-framework 的 patron_service.lua。
-- 重点：GetTier 只读缓存、**绝不 Await**；DB 回来之前返回 0 并在后台预热。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { queries = 0, pending = {}, now = 1700000000 }

-- 老实现会走 Citizen.Await 查库：这里直接当"会卡主线程"报错。
-- 新实现不碰它，所以本桩永远不该被调用。
Citizen = {
    Await = function()
        error('Citizen.Await would block the game thread', 0)
    end,
    CreateThread = function(fn) return fn end,
    Wait = function() end,
}
promise = {
    new = function()
        return { resolve = function() end, value = nil }
    end,
}

-- 不覆盖 os.time：真实时间 + 远过去/远未来的日期字符串就够区分「过期/未过期」，
-- 覆盖它会顺带把 toUnixTime 也算错，测出来的东西跟生产不一致。

local QBCoreMock = {
    Functions = { GetPlayer = function() return nil end },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'oxmysql' then
            return {
                prepare = function(_, query, params, cb)
                    state.queries = state.queries + 1
                    state.pending[#state.pending + 1] = { query = query, params = params, cb = cb }
                    -- 注意：故意**不立刻回调**，模拟慢库
                end,
                execute = function() end,
                insert = function() end,
            }
        end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

Bus = { RegisterService = function(name, impl) state.service = impl; state.serviceName = name end }
DirtyFlush = { MarkDirty = function() end }
print = function() end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/services/patron_service.lua', 'patron_service.lua')

local service = assert(Bus.patron or state.service, 'patron 服务没注册到 Bus')

-- 老实现会 Await 而报错：所有直接调用都包一层，保证探针输出完整矩阵而不是中途崩掉
local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

local function flushPending(row)
    local batch = state.pending
    state.pending = {}
    for _, entry in ipairs(batch) do
        entry.cb(row)
    end
end

-- ── 1. 冷缓存：GetTier 立即返回 0，且不 Await、不崩 ──
emit('SCENARIO', 'cold')
local okCold, coldTier = pcall(service.GetTier, 'CID1')
emit('PATRON_COLD_NO_BLOCK', tostring(okCold and coldTier == 0))
emit('PATRON_COLD_ISSUED_QUERY', tostring(state.queries == 1))

-- ── 2. 慢库回调之后：缓存热了，读到真实等级 ──
flushPending({ tier = 2, expires_at = '2099-01-01 00:00:00' })
emit('PATRON_WARMED_TIER', tostring(safe(service.GetTier, 'CID1') == 2))
emit('PATRON_WARM_NO_EXTRA_QUERY', tostring(state.queries == 1))

-- ── 3. 过期记录 → 0 ──
emit('SCENARIO', 'expired')
safe(service.GetTier, 'CID2')
flushPending({ tier = 3, expires_at = '2000-01-01 00:00:00' })
emit('PATRON_EXPIRED_IS_ZERO', tostring(safe(service.GetTier, 'CID2') == 0))

-- ── 4. DB 失败：返回 0 并退避（再读不撞库）──
emit('SCENARIO', 'failure')
state.queries = 0
safe(service.GetTier, 'CID3')
flushPending(nil)
local afterFail = state.queries
safe(service.GetTier, 'CID3')
emit('PATRON_FAIL_TIER_ZERO', tostring(safe(service.GetTier, 'CID3') == 0))
emit('PATRON_FAIL_BACKOFF', tostring(state.queries == afterFail))

-- ── 5. GetTierAsync：命中同步回调，未命中加载后回调 ──
emit('SCENARIO', 'async')
local hit = nil
safe(service.GetTierAsync, 'CID1', function(tier) hit = tier end)
emit('PATRON_ASYNC_CACHE_HIT', tostring(hit == 2))

local asyncTier = nil
state.queries = 0
safe(service.GetTierAsync, 'CID4', function(tier) asyncTier = tier end)
emit('PATRON_ASYNC_PENDING', tostring(asyncTier == nil and state.queries == 1))
flushPending({ tier = 1, expires_at = '2099-01-01 00:00:00' })
emit('PATRON_ASYNC_RESOLVED', tostring(asyncTier == 1))

-- ── 6. SetTier 校验仍然有效 ──
emit('SCENARIO', 'set')
emit('PATRON_SET_REJECTS_9', tostring(safe(service.SetTier, 'CID5', 9) == false))
emit('PATRON_SET_ACCEPTS_2', tostring(safe(service.SetTier, 'CID5', 2) == true))
emit('PATRON_SET_CACHE_DIRECT', tostring(safe(service.GetTier, 'CID5') == 2))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
