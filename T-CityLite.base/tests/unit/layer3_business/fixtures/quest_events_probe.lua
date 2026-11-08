-- tests/unit/layer3_business/fixtures/quest_events_probe.lua
-- 真加载 custom-quest 的 config + server/main.lua（QuestManager / QuestRegistry / QuestSecurity 用桩）。
-- 覆盖两个客户端可触发、本轮新加校验的事件：
--   * quest:server:aviationHeightMonitorComplete  → 机型识别必须 fail-open（拿不到数据不能拒）
--   * quest:server:registerTrailer                → 非字符串模型必须拒绝

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    players = {},
    active = {},
    registered = {},
    customEvents = {},
    vehicle = 0,
    vehicleClass = 16,
    entity = 0,
    entityModel = 0,
    classThrows = false,
}

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
        GetPlayers = function() return {} end,
        CreateCallback = function() end,
        HasPermission = function() return false end,
        GetDutyCount = function() return 0 end,
        Notify = function() end,
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
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
GetPlayerIdentifiers = function() return { 'license:abc' } end
GetCurrentResourceName = function() return 'custom-quest' end
GetResourceState = function() return 'missing' end
RegisterCommand = function() end
Citizen = { CreateThread = function() end, Wait = function() end, Await = function() end }
ExecuteCommand = function() end
GetInvokingResource = function() return nil end
PerformHttpRequest = function() end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end
GetEntityCoords = function() return vector3(0.0, 0.0, 0.0) end
GetVehiclePedIsIn = function() return state.vehicle end
GetVehicleClass = function()
    if state.classThrows then error('native unavailable') end
    return state.vehicleClass
end
GetEntityModel = function() return state.entityModel end
NetworkGetEntityFromNetworkId = function(netId) return state.entity or netId end
DoesEntityExist = function(entity) return entity ~= 0 end
GetHashKey = function(value) return 'hash:' .. tostring(value) end
joaat = function(value) return 'hash:' .. tostring(value) end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    insert = function() end,
    update = function() end,
}

-- custom-quest 的模块：只保留被测路径用到的部分
QuestRegistry = {
    AutoLoad = function() end,
    GetTemplate = function(questId)
        if questId == 'quest_logistics_1' then return { id = questId, title = 't', steps = {} } end
        return nil
    end,
    GetAll = function() return {} end,
}
QuestManager = {
    GetActiveQuests = function() return state.active end,
    FailQuest = function() end,
    TriggerQuest = function() end,
    AdvanceStep = function() end,
    AbandonQuest = function() end,
    CompleteStep = function() end,
    GetQuestProgress = function() end,
}
QuestSecurity = {
    CheckRateLimit = function() return true end,
    ValidateClientEvent = function() return true end,
    IssueNonce = function() return 'nonce' end,
    ConsumeNonce = function() return true end,
    ValidateNonce = function() return true end,
}
QuestEntityRegistry = {
    Register = function(_, citizenid, questId, kind, netId)
        state.registered[#state.registered + 1] = { citizenid = citizenid, questId = questId, kind = kind, netId = netId }
    end,
    Unregister = function() end,
    Cleanup = function() end,
}
QuestCache = { GetActiveQuests = function() return {} end }
QuestDB = {}
QuestCooldown = {}
QuestAvailability = {}
QuestAddressResolver = {}
Config = Config or {}
Config.Quest = { Enabled = true, Events = { QUEST_ACCEPT = 'quest:server:accept', QUEST_COMPLETED = 'quest:server:completed' } }
Config.QuestTemplates = {}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'custom-quest' then
            return {
                OnCustomEvent = function(_, src, event, payload)
                    state.customEvents[#state.customEvents + 1] = { src = src, event = event, payload = payload }
                end,
            }
        end
        if name == 'custom-logs' then return { LogSecurity = function() end } end
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

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'server/main.lua')

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
state.active = { { quest_id = 'quest_logistics_1', status = 'active' } }

-- ── 1. aviation：在载具里 + 机型未知时**放行**（fail-open）──
emit('SCENARIO', 'aviation')
state.customEvents = {}
state.vehicle = 501
state.vehicleClass = 16                    -- 固定翼
fireAs(1, 'quest:server:aviationHeightMonitorComplete', 'quest_logistics_1')
emit('AVIATION_COPLANE_ALLOWED', tostring(#state.customEvents == 1))

state.customEvents = {}
state.classThrows = true                   -- 原生不可用（pcall 失败）
fireAs(1, 'quest:server:aviationHeightMonitorComplete', 'quest_logistics_1')
state.classThrows = false
emit('AVIATION_NATIVE_MISSING_ALLOWED', tostring(#state.customEvents == 1))

state.customEvents = {}
state.vehicleClass = 0                     -- 原生返回 0（未知）
fireAs(1, 'quest:server:aviationHeightMonitorComplete', 'quest_logistics_1')
emit('AVIATION_CLASS_ZERO_ALLOWED', tostring(#state.customEvents == 1))

state.customEvents = {}
state.vehicleClass = 1                     -- 明确是普通轿车 → 拒
fireAs(1, 'quest:server:aviationHeightMonitorComplete', 'quest_logistics_1')
emit('AVIATION_CAR_BLOCKED', tostring(#state.customEvents == 0))

state.customEvents = {}
state.vehicle = 0                          -- 不在载具里 → 拒
state.vehicleClass = 16
fireAs(1, 'quest:server:aviationHeightMonitorComplete', 'quest_logistics_1')
emit('AVIATION_ON_FOOT_BLOCKED', tostring(#state.customEvents == 0))

state.customEvents = {}
state.vehicle = 501
fireAs(1, 'quest:server:aviationHeightMonitorComplete', 'quest_not_mine')
emit('AVIATION_WRONG_QUEST_BLOCKED', tostring(#state.customEvents == 0))

-- ── 2. registerTrailer：模型必填且必须与实体一致 ──
emit('SCENARIO', 'trailer')
state.registered = {}
state.entity = 777
state.entityModel = 'hash:trailerlogs'
fireAs(1, 'quest:server:registerTrailer', 'quest_logistics_1', 777, nil)
emit('TRAILER_MISSING_MODEL_BLOCKED', tostring(#state.registered == 0))

state.registered = {}
fireAs(1, 'quest:server:registerTrailer', 'quest_logistics_1', 777, 42)
emit('TRAILER_BAD_MODEL_TYPE_BLOCKED', tostring(#state.registered == 0))

state.registered = {}
fireAs(1, 'quest:server:registerTrailer', 'quest_logistics_1', 777, 'trailerlogs')
emit('TRAILER_VALID_MODEL_ALLOWED', tostring(#state.registered == 1))

state.registered = {}
fireAs(1, 'quest:server:registerTrailer', 'quest_logistics_1', 777, 'adder')
emit('TRAILER_MODEL_MISMATCH_BLOCKED', tostring(#state.registered == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
