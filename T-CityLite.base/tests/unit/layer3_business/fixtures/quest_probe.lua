-- tests/unit/layer3_business/fixtures/quest_probe.lua
-- 真加载 custom-quest 的 quest_logistics_validators.lua（货运损伤上报）。
-- 飞行高度监控那支依赖 QuestManager/实体 API，单独在 main.lua 里做静态+逻辑核对成本过高，
-- 这里覆盖能离线跑的那一半：参数校验与数值夹取。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, logs = {} }

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = { SetMetaData = function() end }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        CreateCallback = function() end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end
GetEntityCoords = function() return vec3(0.0, 0.0, 0.0) end

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
        if name == 'custom-logs' then
            return { LogSecurity = function(_, title, text) state.logs[#state.logs + 1] = { title = title, text = text } end }
        end
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
joaat = function(value) return 'joaat:' .. tostring(value) end
GetEntityModel = function() return 'hash:x' end
GetVehiclePedIsIn = function() return 0 end
GetVehicleClass = function() return 0 end
GetPedInVehicleSeat = function() return 0 end
GetEntityHeightAboveGround = function() return 0.0 end
NetworkGetEntityFromNetworkId = function() return 0 end
DoesEntityExist = function() return false end

load_lua(RES .. '/server/quest_logistics_validators.lua', 'quest_logistics_validators.lua')

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

local function readRecord(questId)
    local handler = handlers['quest:server:cargoDamageResult']
    if not handler then return nil end
    for index = 1, 40 do
        local name, value = debug.getupvalue(handler, index)
        if not name then break end
        if name == 'CargoDamageRecords' then
            local record = value['CID1'] and value['CID1'][questId]
            return record
        end
    end
    return nil
end

-- ── 1. 坏参数不崩 ──
emit('SCENARIO', 'bad-payload')
emit('DAMAGE_NIL_SAFE', tostring(fireAs(1, 'quest:server:cargoDamageResult')))
emit('DAMAGE_NOT_TABLE_SAFE', tostring(fireAs(1, 'quest:server:cargoDamageResult', 42)))
emit('DAMAGE_BAD_QUESTID_SAFE', tostring(fireAs(1, 'quest:server:cargoDamageResult', { questId = 123 })))

-- ── 2. 正常上报 ──
emit('SCENARIO', 'normal')
fireAs(1, 'quest:server:cargoDamageResult', {
    questId = 'quest_logistics_1', collisionCount = 3, damagePct = 12,
    bodyHealthDelta = 40, engineHealthDelta = 5,
})
local record = readRecord('quest_logistics_1')
emit('DAMAGE_RECORDED', tostring(record ~= nil and record.collisionCount == 3 and record.damagePct == 12))

-- ── 3. 越界数值必须夹取 ──
fireAs(1, 'quest:server:cargoDamageResult', {
    questId = 'quest_logistics_2', collisionCount = 99999, damagePct = -50,
    bodyHealthDelta = 1e9, engineHealthDelta = 'not-a-number',
})
local clamped = readRecord('quest_logistics_2')
emit('DAMAGE_CLAMPED', tostring(clamped ~= nil
    and clamped.collisionCount == 500
    and clamped.damagePct == 0
    and clamped.bodyHealthDelta == 2000
    and clamped.engineHealthDelta == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
