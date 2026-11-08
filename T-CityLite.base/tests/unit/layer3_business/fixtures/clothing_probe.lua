-- tests/unit/layer3_business/fixtures/clothing_probe.lua
-- 真加载 qb-clothing 的 config.lua + server/main.lua。
-- 重点：皮肤数据的有界校验、服装条数上限、OnPlayerUnload 的来源判定、Player 为 nil 时不崩。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    inserts = 0,
    deletes = 0,
    queries = 0,
    scalarValue = 0,
    notified = 0,
    players = {},
    callbacks = {},
}

local function makePlayer(source, citizenid)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = citizenid or ('CID' .. source),
        license = 'LIC' .. source, job = { name = 'unemployed', onduty = false },
        metadata = {}, money = { cash = 1000, bank = 1000 },
    }
    player.Functions = { SetMetaData = function() end }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name)
    if name == 'QBCore:Notify' then state.notified = state.notified + 1 end
end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetCurrentResourceName = function() return 'qb-clothing' end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = {
    encode = function(value)
        -- 粗略的长度估算：真机是 JSON，这里只要能看到"很大"就够了
        local count = 0
        if type(value) == 'table' then
            for _ in pairs(value) do count = count + 1 end
        end
        return string.rep('x', count * 32)
    end,
    decode = function() return {} end,
}
-- oxmysql 的 query 既可 await 也可当函数调（回调式）
local queryMock = { await = function() state.queries = state.queries + 1; return {} end }
MySQL = {
    query = setmetatable(queryMock, {
        __call = function(_, _sql, _params, cb)
            state.queries = state.queries + 1
            if type(cb) == 'function' then cb({}) end
        end,
    }),
    single = { await = function() return nil end },
    scalar = { await = function() return state.scalarValue end },
    insert = function() state.inserts = state.inserts + 1 end,
    update = function() end,
    prepare = function() end,
    Async = { execute = function() end },
}
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end
vector2 = function(x, y) return { x = x or 0.0, y = y or 0.0 } end
vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'main.lua')

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

state.players[1] = makePlayer(1)
state.players[2] = makePlayer(2)

local function skinCacheOf(handlerName)
    local handler = handlers[handlerName]
    for index = 1, 60 do
        local name, value = debug.getupvalue(handler, index)
        if not name then break end
        if name == 'skinCache' then return value end
    end
    return nil
end

-- ── 1. saveSkin：正常写入 / 超大表拒绝 / 非表拒绝 ──
emit('SCENARIO', 'save-skin')
local cache = assert(skinCacheOf('qb-clothing:saveSkin'), 'skinCache 取不到')
local okGood = fireAs(1, 'qb-clothing:saveSkin', 'mp_m_freemode_01', { skin = 1, hair = 2 })
emit('SKIN_SAVE_OK', tostring(okGood and cache['CID1'] ~= nil))

local huge = {}
for index = 1, 200 do huge['k' .. index] = 'v' end
cache['CID1'] = nil
fireAs(1, 'qb-clothing:saveSkin', 'mp_m_freemode_01', huge)
emit('SKIN_HUGE_REJECTED', tostring(cache['CID1'] == nil))

cache['CID1'] = nil
fireAs(1, 'qb-clothing:saveSkin', 'mp_m_freemode_01', 'not-a-table')
emit('SKIN_BAD_TYPE_REJECTED', tostring(cache['CID1'] == nil))

cache['CID1'] = nil
fireAs(1, 'qb-clothing:saveSkin', string.rep('m', 500), { skin = 1 })
emit('SKIN_BAD_MODEL_REJECTED', tostring(cache['CID1'] == nil))

-- ── 2. OnPlayerUnload：客户端触发必须被拒 ──
emit('SCENARIO', 'unload')
cache['CID2'] = { model = 'mp_m_freemode_01', skin = { skin = 1 }, isDirty = true }
local insertsBefore = state.inserts
fireAs(1, 'QBCore:Server:OnPlayerUnload', 2)
emit('UNLOAD_CLIENT_BLOCKED', tostring(state.inserts == insertsBefore))
fireAs(0, 'QBCore:Server:OnPlayerUnload', 2)
emit('UNLOAD_SERVER_ALLOWED', tostring(state.inserts > insertsBefore))

-- ── 3. saveOutfit：Player 为 nil 不崩 / 条数上限 / 皮肤结构 ──
emit('SCENARIO', 'save-outfit')
emit('OUTFIT_MISSING_PLAYER_SAFE', tostring(fireAs(99, 'qb-clothes:saveOutfit', 'x', 'mp_m_freemode_01', { skin = 1 })))

state.scalarValue = 0
state.inserts = 0
fireAs(1, 'qb-clothes:saveOutfit', 'casual', 'mp_m_freemode_01', { skin = 1, hair = 2 })
emit('OUTFIT_SAVED', tostring(state.inserts == 1))

state.scalarValue = 100     -- 已经超过上限
state.inserts = 0
fireAs(1, 'qb-clothes:saveOutfit', 'casual2', 'mp_m_freemode_01', { skin = 1 })
emit('OUTFIT_LIMIT_ENFORCED', tostring(state.inserts == 0))

state.scalarValue = 0
state.inserts = 0
local hugeSkin = {}
for index = 1, 200 do hugeSkin['k' .. index] = 'v' end
fireAs(1, 'qb-clothes:saveOutfit', 'huge', 'mp_m_freemode_01', hugeSkin)
emit('OUTFIT_HUGE_SKIN_REJECTED', tostring(state.inserts == 0))

state.inserts = 0
fireAs(1, 'qb-clothes:saveOutfit', string.rep('n', 200), 'mp_m_freemode_01', { skin = 1 })
emit('OUTFIT_LONG_NAME_REJECTED', tostring(state.inserts == 0))

-- ── 4. removeOutfit：Player 为 nil 不崩 ──
emit('SCENARIO', 'remove-outfit')
emit('OUTFIT_REMOVE_MISSING_PLAYER_SAFE', tostring(fireAs(99, 'qb-clothing:server:removeOutfit', 'casual', 'outfit-1-1234')))

-- ── 5. getOutfits 回调：Player 不存在时不崩 ──
emit('SCENARIO', 'get-outfits')
local callback = state.callbacks['qb-clothing:server:getOutfits']
local okCb, cbErr = pcall(callback, 99, function() end)
emit('GETOUTFITS_MISSING_PLAYER_SAFE', tostring(okCb))
if not okCb then OUT[#OUT + 1] = 'HANDLER_ERROR|getOutfits|' .. tostring(cbErr) end

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
