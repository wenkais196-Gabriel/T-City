-- tests/unit/layer3_business/fixtures/hud_scoreboard_probe.lua
-- 真加载 qb-hud / qb-scoreboard 的 server 脚本。
-- 重点：stress 增量有界（表/字符串不能打崩线程），scoreboard 的 busy 标记只由服务端翻。

local RES = arg[1] or error('need resource dir')
local TARGET = arg[2] or 'hud'

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, metadata = {}, broadcasts = {} }

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', type = 'none', onduty = false, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = state.metadata, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = {
        SetMetaData = function(key, value) state.metadata[key] = value end,
        Notify = function() end,
        SetJob = function() end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetQBPlayers = function() return state.players end,
        HasPermission = function(source, permission) return state.adminId == source and permission == 'admin' end,
        CreateCallback = function() end,
        GetPlayers = function() return {} end,
        GetPlayerData = function() return {} end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }), Jobs = {} },
    Commands = { Add = function() end },
}
QBCore = QBCoreMock

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterCommand = function() end
TriggerClientEvent = function(name, target, arg1, arg2) state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, arg1 = arg1, arg2 = arg2 } end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetCurrentResourceName = function() return TARGET end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return false end
GetPlayers = function() return {} end
GetResourceState = function() return 'started' end
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

local function fire(name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    local ok, err = pcall(handler, ...)
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

for _, source in ipairs({ 1, 2 }) do state.players[source] = makePlayer(source) end
state.adminId = 2

if TARGET == 'hud' then
    load_lua(RES .. '/config.lua', 'config.lua')
    load_lua(RES .. '/server.lua', 'server.lua')

    -- ── 1. 正常增量 ──
    emit('SCENARIO', 'gain-stress')
    state.metadata.stress = 10
    _G.source = 1
    fire('hud:server:GainStress', 3)
    _G.source = nil
    emit('STRESS_GAIN_APPLIED', tostring(state.metadata.stress == 13))

    -- ── 2. 表 / 字符串 / 负数不能打崩，也不能改 ──
    for _, bad in ipairs({ {}, 'abc', -5, 0 }) do
        state.metadata.stress = 10
        _G.source = 1
        fire('hud:server:GainStress', bad)
        _G.source = nil
        if state.metadata.stress ~= 10 then
            emit('STRESS_BAD_STEP_BLOCKED', 'false')
        end
    end
    emit('STRESS_BAD_STEP_BLOCKED', 'true')

    -- ── 3. 超大增量夹到上限 ──
    emit('SCENARIO', 'clamp')
    state.metadata.stress = 0
    _G.source = 1
    fire('hud:server:GainStress', 99999)
    _G.source = nil
    emit('STRESS_GAIN_CLAMPED', tostring(state.metadata.stress == 100))

    state.metadata.stress = 100
    _G.source = 1
    fire('hud:server:RelieveStress', 100)
    _G.source = nil
    emit('STRESS_RELIEVE_APPLIED', tostring(state.metadata.stress == 0))

    state.metadata.stress = 100
    _G.source = 1
    fire('hud:server:RelieveStress', {})
    _G.source = nil
    emit('STRESS_RELIEVE_BAD_STEP_BLOCKED', tostring(state.metadata.stress == 100))
else
    load_lua(RES .. '/config.lua', 'config.lua')
    load_lua(RES .. '/server.lua', 'server.lua')

    local activity = nil
    for name in pairs(Config.IllegalActions or {}) do activity = name break end
    assert(activity, 'Config.IllegalActions 为空')

    -- ── 1. 客户端（source ~= 0）不能翻 busy ──
    emit('SCENARIO', 'busy-guard')
    Config.IllegalActions[activity].busy = false
    state.broadcasts = {}
    _G.source = 1
    fire('qb-scoreboard:server:SetActivityBusy', activity, true)
    _G.source = nil
    emit('BUSY_CLIENT_BLOCKED', tostring(Config.IllegalActions[activity].busy == false and #state.broadcasts == 0))

    -- ── 2. 坏 key / 坏类型不能抛错 ──
    local okBadKey = true
    _G.source = 0
    okBadKey = fire('qb-scoreboard:server:SetActivityBusy', 'not_an_activity', true)
    fire('qb-scoreboard:server:SetActivityBusy', activity, 'yes')
    _G.source = nil
    emit('BUSY_BAD_ARGS_SAFE', tostring(okBadKey and Config.IllegalActions[activity].busy == false))

    -- ── 3. 服务端（source == 0）可以翻 ──
    state.broadcasts = {}
    _G.source = 0
    fire('qb-scoreboard:server:SetActivityBusy', activity, true)
    _G.source = nil
    emit('BUSY_SERVER_ALLOWED', tostring(Config.IllegalActions[activity].busy == true and #state.broadcasts == 1))
end

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
