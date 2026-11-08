-- tests/unit/layer3_business/fixtures/multicharacter_probe.lua
-- 真加载 qb-multicharacter 的 config.lua + server/main.lua。
-- 重点：cData / data / citizenid 这些客户端参数的类型校验，以及 charinfo 收敛。
-- 归属校验在 qb-core（license 比对），这里用桩代替并记录调用。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    logins = {},
    deletes = {},
    players = {},
    dropped = {},
    logs = {},
}

-- handler 表要在 QBCoreMock 之前声明：Login 桩里要派发 QBCore:Server:PlayerLoaded
local handlers = {}

local QBCoreMock = {
    Player = {
        Login = function(src, citizenid, newData)
            state.logins[#state.logins + 1] = { src = src, citizenid = citizenid, newData = newData }
            -- 模拟 qb-core 载入完成后派发 PlayerLoaded（handler 里会把预载标记置真）
            local loaded = handlers['QBCore:Server:PlayerLoaded']
            if loaded then loaded({ PlayerData = { source = src } }) end
            return true
        end,
        DeleteCharacter = function(src, citizenid)
            state.deletes[#state.deletes + 1] = { src = src, citizenid = citizenid }
        end,
    },
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetIdentifier = function() return 'license:abc' end,
        CreateCallback = function() end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }), StarterItems = { { item = 'phone' } } },
    Commands = { Refresh = function() end, Add = function() end },
}

RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function(name, ...)
    if name == 'qb-log:server:CreateLog' then state.logs[#state.logs + 1] = { ... } end
end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetResourceState = function() return 'missing' end
GetCurrentResourceName = function() return 'qb-multicharacter' end
LoadResourceFile = function() return '{}' end
GetInvokingResource = function() return nil end
DropPlayer = function(src) state.dropped[#state.dropped + 1] = src end
SetPlayerRoutingBucket = function() end
GetPlayerPed = function(source) return source end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return { x = 1, y = 2, z = 3 } end }
MySQL = {
    query = { await = function(sql)
        if type(sql) == 'string' and sql:find('COUNT', 1, true) then return { { count = 0 } } end
        return {}
    end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    insert = function() end,
    update = function() end,
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
vector2 = function(x, y) return { x = x, y = y } end
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

-- Config.SkipSelection=false 时 login 后会进入 spawn 流程；这里只关心参数校验，
-- 所以先把它关掉避免走到 qb-spawn。
Config.SkipSelection = false

-- ── 1. loadUserData：缺参数 / 坏类型不能抛错 ──
emit('SCENARIO', 'load')
emit('LOAD_NIL_SAFE', tostring(fireAs(1, 'qb-multicharacter:server:loadUserData')))
emit('LOAD_NOT_TABLE_SAFE', tostring(fireAs(1, 'qb-multicharacter:server:loadUserData', 42)))
emit('LOAD_BAD_CITIZENID_SAFE', tostring(fireAs(1, 'qb-multicharacter:server:loadUserData', { citizenid = 12345 })))
emit('LOAD_EMPTY_CITIZENID_SAFE', tostring(fireAs(1, 'qb-multicharacter:server:loadUserData', { citizenid = '' })))

state.logins = {}
fireAs(1, 'qb-multicharacter:server:loadUserData', { citizenid = 'ABC12345', position = '{"x":1,"y":2,"z":3}' })
emit('LOAD_VALID_REACHES_LOGIN', tostring(#state.logins == 1 and state.logins[1].citizenid == 'ABC12345'))

-- ── 2. createCharacter：charinfo 白名单收敛 ──
emit('SCENARIO', 'create')
state.logins = {}
fireAs(1, 'qb-multicharacter:server:createCharacter', {
    firstname = 'John', lastname = 'Doe', birthdate = '1990-01-01',
    gender = 0, nationality = 'FR', cid = '3',
    -- 下面这些都不该进新角色数据
    isAdmin = true, money = 9999999, items = { { name = 'goldbar', amount = 99 } },
    hugeblob = string.rep('x', 5000),
})
local created = state.logins[1] and state.logins[1].newData or nil
local charinfo = created and created.charinfo or {}
emit('CREATE_REACHES_LOGIN', tostring(created ~= nil))
emit('CREATE_STRIPS_UNKNOWN_FIELDS', tostring(charinfo.isAdmin == nil and charinfo.money == nil and charinfo.items == nil and charinfo.hugeblob == nil))
emit('CREATE_KEEPS_WHITELIST', tostring(charinfo.firstname == 'John' and charinfo.lastname == 'Doe'))
emit('CREATE_CID_NUMERIC', tostring(created ~= nil and created.cid == 3))

state.logins = {}
fireAs(1, 'qb-multicharacter:server:createCharacter', 'not-a-table')
emit('CREATE_BAD_DATA_SAFE', tostring(#state.logins == 0))

state.logins = {}
fireAs(1, 'qb-multicharacter:server:createCharacter', { lastname = 'Doe' })
emit('CREATE_MISSING_FIRSTNAME_REJECTED', tostring(#state.logins == 0))

-- ── 3. deleteCharacter：citizenid 类型校验 ──
emit('SCENARIO', 'delete')
state.deletes = {}
fireAs(1, 'qb-multicharacter:server:deleteCharacter', 42)
emit('DELETE_BAD_TYPE_REJECTED', tostring(#state.deletes == 0))
fireAs(1, 'qb-multicharacter:server:deleteCharacter', 'ABC12345')
emit('DELETE_VALID_REACHES_CORE', tostring(#state.deletes == 1))

-- ── 4. disconnect：只能踢自己 ──
emit('SCENARIO', 'disconnect')
state.dropped = {}
fireAs(7, 'qb-multicharacter:server:disconnect')
emit('DISCONNECT_DROPS_SELF', tostring(#state.dropped == 1 and state.dropped[1] == 7))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
