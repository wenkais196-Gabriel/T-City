-- tests/unit/layer3_business/fixtures/dashboard_probe.lua
-- 真加载 tcity-dashboard 的 server/police_api.lua。
-- 重点：车牌标记/取消/追踪器只认在职警察；plate/reason 参数有界。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, broadcasts = {}, logs = {}, flagged = {}, db = {} }

local function makePlayer(source, jobName, jobType, onduty)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = jobName or 'unemployed', type = jobType or 'none', onduty = onduty == true, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = {
        RemoveItem = function() return true end, AddItem = function() return true end,
        Notify = function() end, SetMetaData = function() end, SetJob = function() end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetPlayers = function() return {} end,
        HasPermission = function() return false end,
        CreateCallback = function() end,
        Notify = function() end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }) },
    Commands = { Add = function() end },
}
QBCore = QBCoreMock

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterCommand = function() end
TriggerClientEvent = function(name, target, ...) state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, args = { ... } } end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetCurrentResourceName = function() return 'tcity-dashboard' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return false end
GetPlayerPed = function(source) return tonumber(source) or 0 end
GetHashKey = function(value) return 'hash:' .. tostring(value) end
joaat = function(value) return 'hash:' .. tostring(value) end
GetConvarInt = function(_, default) return tonumber(default) or 0 end
GetConvarBool = function(_, default) return default == true end

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
    insert = function(_, query, params) state.db[#state.db + 1] = { query = query, params = params } end,
    update = function() end,
}
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'custom-logs' then
            return {
                LogSecurity = function(_, title, text) state.logs[#state.logs + 1] = { title = title, text = text } end,
                LogGeneric = function() end,
            }
        end
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

load_lua(RES .. '/server/police_api.lua', 'server/police_api.lua')

local function fire(src, name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

state.players[1] = makePlayer(1, 'unemployed', 'none', false)                 -- 路人
state.players[2] = makePlayer(2, 'police', 'leo', true)                       -- 在职警察
state.players[3] = makePlayer(3, 'police', 'leo', false)                      -- 警察但下班

-- ── 1. 车牌标记：只认在职警察 ──
emit('SCENARIO', 'flag-plate')
state.broadcasts = {}
fire(1, 'tcity-dashboard:server:flagPlate', 'ABC123', '测试')
emit('FLAG_CIVILIAN_BLOCKED', tostring(#state.broadcasts == 0))

state.broadcasts = {}
fire(3, 'tcity-dashboard:server:flagPlate', 'ABC123', '测试')
emit('FLAG_OFFDUTY_BLOCKED', tostring(#state.broadcasts == 0))

state.broadcasts = {}
fire(2, 'tcity-dashboard:server:flagPlate', 'abc123', '测试')
emit('FLAG_LEO_ALLOWED', tostring(#state.broadcasts == 1))

-- ── 2. 坏参数不能抛错 ──
local okNil = fire(2, 'tcity-dashboard:server:flagPlate', nil, nil)
local okNumber = fire(2, 'tcity-dashboard:server:flagPlate', 12345)
local okLong = fire(2, 'tcity-dashboard:server:flagPlate', string.rep('X', 200))
emit('FLAG_BAD_PLATE_SAFE', tostring(okNil and okNumber and okLong))

-- ── 3. 取消标记 ──
state.broadcasts = {}
fire(1, 'tcity-dashboard:server:unflagPlate', 'ABC123')
emit('UNFLAG_CIVILIAN_BLOCKED', tostring(#state.broadcasts == 0))

state.broadcasts = {}
local okUnflagNil = fire(2, 'tcity-dashboard:server:unflagPlate', nil)
emit('UNFLAG_BAD_PLATE_SAFE', tostring(okUnflagNil))

-- ── 4. 追踪器 ──
state.broadcasts = {}
fire(1, 'tcity-dashboard:server:setTracker', 2)
emit('TRACKER_CIVILIAN_BLOCKED', tostring(#state.broadcasts == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
