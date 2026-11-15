-- tests/unit/layer3_business/fixtures/apartments_probe.lua
-- 真加载 qb-apartments 的 config.lua + server/main.lua，触发建/改公寓事件。
-- 关键点：CreateApartment 的形参原来叫 `type`，遮蔽全局 type() → 一触发就
-- `attempt to call a string value (local 'type')`，公寓永远建不出来。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { inserts = {}, updates = {}, clientEvents = {} }

local player = {
    PlayerData = { source = 1, citizenid = 'TESTCID', charinfo = { firstname = 'Test', lastname = 'Cid' } },
    Functions = { SetMetaData = function() end },
}

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return source == 1 and player or nil end,
        GetPlayerByCitizenId = function() return player end,
        CreateCallback = function() end,
        SetPlayerBucket = function() end,
        GetPlayers = function() return {} end,
    },
    Commands = { Add = function() end },
    Shared = { Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }) },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    state.clientEvents[#state.clientEvents + 1] = { name = name, target = target, args = { ... } }
end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return 0 end
GetConvar = function(_, default) return default end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
json = { encode = function() return 'encoded' end, decode = function() return {} end }
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }

local function dbRunner(kind)
    return function(...)
        local args = { ... }
        state[kind][#state[kind] + 1] = args
        return 1
    end
end

MySQL = setmetatable({}, {
    __index = function(_, method)
        local runner = dbRunner(method == 'insert' and 'inserts' or 'updates')
        return setmetatable({}, {
            __call = function(_, ...) return runner(...) end,
            __index = function(_, key)
                if key == 'await' then
                    return function(sql, params)
                        if method == 'scalar' then return 'TESTCID' end
                        return runner(sql, params)
                    end
                end
                return function() return 1 end
            end,
        })
    end,
})

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCoreMock end }
        end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
    return ok
end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([%w_]+)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'main.lua')

-- ── 场景 1：正常建公寓（合法 type）──
emit('SCENARIO', 'create-apartment')
local insertsBefore = #state.inserts
fireAs(1, 'apartments:server:CreateApartment', 'apartment1', 'My Place', false)
emit('INSERTED', #state.inserts - insertsBefore)

-- ── 场景 2：非法 type 必须被拒，不写库 ──
emit('SCENARIO', 'create-bad-type')
local insertsBefore2 = #state.inserts
fireAs(1, 'apartments:server:CreateApartment', 'not_a_real_type', 'X', false)
fireAs(1, 'apartments:server:CreateApartment', 42, 'X', false)
emit('INSERTED_BAD', #state.inserts - insertsBefore2)

-- ── 场景 3：改公寓 ──
emit('SCENARIO', 'update-apartment')
local updatesBefore = #state.updates
fireAs(1, 'apartments:server:UpdateApartment', 'apartment1', 'Renamed', false)
emit('UPDATED', #state.updates - updatesBefore)
fireAs(1, 'apartments:server:UpdateApartment', 'bogus', 'X', false)
emit('UPDATED_BAD', #state.updates - updatesBefore - 1)

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
