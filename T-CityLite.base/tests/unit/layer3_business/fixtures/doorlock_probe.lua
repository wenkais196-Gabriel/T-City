-- tests/unit/layer3_business/fixtures/doorlock_probe.lua
-- 真加载 qb-doorlock 的 config（如果有）+ server/main.lua。
-- 重点：`updateState` 的鉴权对象必须是**调用者本人**，不能被客户端塞参数指定。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, broadcasts = {}, does = {}, coords = nil }

local function makePlayer(source, jobName, grade)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = jobName or 'unemployed', onduty = false, grade = { level = grade or 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = {
        RemoveItem = function(name, amount) state.does[#state.does + 1] = { name = name, amount = amount } return true end,
        Notify = function() end,
        SetMetaData = function() end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        HasPermission = function(source, permission) return state.permissions and state.permissions[permission] == source end,
        GetIdentifier = function() return 'license:abc' end,
        CreateCallback = function() end,
        GetPlayers = function() return {} end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterCommand = function() end
TriggerClientEvent = function(name, target, playerId, doorId, locked) state.broadcasts[#state.broadcasts + 1] = { name = name, playerId = playerId, doorId = doorId, locked = locked } end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function(_, fn) end
Wait = function() end
GetCurrentResourceName = function() return 'qb-doorlock' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return false end
GetGameTimer = function() return 1000 end

vec2 = function(x, y) return { x = x, y = y } end
vec3 = function(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end
GetEntityCoords = function() return vector3(0.0, 0.0, 0.0) end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
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
    source = source:gsub('(%w+)%s*%+=%s*', '%1 = %1 + ')
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'server/main.lua')

local function fire(name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    local ok, err = pcall(handler, ...)
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
end

-- 找一个警察门和一个需要钥匙的门
local copDoorId, copDoor
for id, door in pairs(Config.DoorList or {}) do
    if door.authorizedJobs and door.authorizedJobs['police'] then copDoorId, copDoor = id, door break end
end
if not copDoorId then
    for id, door in pairs(Config.DoorList or {}) do copDoorId, copDoor = id, door break end
end
assert(copDoorId ~= nil, 'config 里没有门')

state.players[1] = makePlayer(1, 'unemployed', 0)     -- 普通玩家
state.players[2] = makePlayer(2, 'police', 5)         -- 在线警察

-- ── 1. 普通玩家塞 sentSource = 警察 id，想借警察的权限 ──
emit('SCENARIO', 'forged-sent-source')
state.broadcasts = {}
_G.source = 1
fire('qb-doorlock:server:updateState', copDoorId, false, false, false, false, false, false, 2)
_G.source = nil
emit('FORGED_SOURCE_BLOCKED', tostring(#state.broadcasts == 0))

-- ── 2. 警察本人开门（不传 sentSource）应该放行 ──
state.broadcasts = {}
_G.source = 2
fire('qb-doorlock:server:updateState', copDoorId, false, false, false, false, true, true)
_G.source = nil
emit('COP_OPEN_ALLOWED', tostring(#state.broadcasts == 1 and state.broadcasts[1].playerId == 2))

-- ── 3. 普通玩家无权开门 ──
state.broadcasts = {}
_G.source = 1
fire('qb-doorlock:server:updateState', copDoorId, false, false, false, false, false, false)
_G.source = nil
emit('CIVILIAN_OPEN_BLOCKED', tostring(#state.broadcasts == 0))

-- ── 4. 开锁器白名单 ──
emit('SCENARIO', 'lockpick')
state.does = {}
_G.source = 1
fire('qb-doorlock:server:removeLockpick', 'advancedlockpick')
fire('qb-doorlock:server:removeLockpick', 'lockpick')
fire('qb-doorlock:server:removeLockpick', 'water_bottle')
fire('qb-doorlock:server:removeLockpick', 42)
_G.source = nil
emit('LOCKPICK_WHITELIST', tostring(#state.does == 2))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
