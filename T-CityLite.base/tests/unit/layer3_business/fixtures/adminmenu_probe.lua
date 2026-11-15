-- tests/unit/layer3_business/fixtures/adminmenu_probe.lua
-- 真加载 qb-adminmenu 的 server 脚本。重点：全服玩家位置（blips 数据）只给管理员。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, broadcasts = {}, callbacks = {}, adminId = nil, aceAllowed = false }

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
        position = { x = 1.0, y = 2.0, z = 3.0 },
    }
    player.Functions = {
        SetMetaData = function() end, Notify = function() end, SetJob = function() end,
        RemoveItem = function() return true end, AddItem = function() return true end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetQBPlayers = function() return state.players end,
        GetPlayers = function() return {} end,
        HasPermission = function(source, permission) return state.adminId == source and permission == 'admin' end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        GetIdentifier = function() return 'license:abc' end,
        IsWhitelisted = function() return true end,
        DropPlayer = function() end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }), Jobs = {}, Vehicles = {} },
    Commands = { Add = function() end },
}
QBCore = QBCoreMock

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterCommand = function() end
RegisterPermission = function() end
TriggerClientEvent = function(name, target, arg1)
    state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, arg1 = arg1 }
end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetCurrentResourceName = function() return 'qb-adminmenu' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return state.aceAllowed end
GetPlayers = function() return {} end
GetResourceState = function() return 'started' end
DropPlayer = function() end
GetPlayerPed = function(source) return tonumber(source) or 0 end
GetEntityCoords = function() return vector3(1.0, 2.0, 3.0) end
GetHashKey = function(value) return 'hash:' .. tostring(value) end
joaat = function(value) return 'hash:' .. tostring(value) end
GetConvarInt = function(_, default) return tonumber(default) or 0 end
GetConvarBool = function(_, default) return default == true end

vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end

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

for _, source in ipairs({ 1, 2 }) do state.players[source] = makePlayer(source) end

load_lua(RES .. '/server/server.lua', 'server/server.lua')

local function fire(src, name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

-- ── 1. 普通玩家拿不到全服位置 ──
emit('SCENARIO', 'blips')
state.adminId = 2                 -- 只有 2 号是管理员
state.broadcasts = {}
fire(1, 'qb-admin:server:GetPlayersForBlips')
emit('BLIPS_CIVILIAN_BLOCKED', tostring(#state.broadcasts == 0))

-- ── 2. 管理员能拿到 ──
state.broadcasts = {}
fire(2, 'qb-admin:server:GetPlayersForBlips')
local showBroadcast = state.broadcasts[1]
emit('BLIPS_ADMIN_ALLOWED', tostring(#state.broadcasts == 1
    and showBroadcast.name == 'qb-admin:client:Show'
    and showBroadcast.target == 2
    and type(showBroadcast.arg1) == 'table'))

-- ── 3. ACE 权限（command）也算管理员 ──
state.adminId = nil
state.aceAllowed = true
state.broadcasts = {}
fire(1, 'qb-admin:server:GetPlayersForBlips')
emit('BLIPS_ACE_ALLOWED', tostring(#state.broadcasts == 1))
state.aceAllowed = false

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
