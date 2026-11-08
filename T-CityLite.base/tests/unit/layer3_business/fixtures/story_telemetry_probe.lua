-- tests/unit/layer3_business/fixtures/story_telemetry_probe.lua
-- 真加载 story-engine 的 server/main.lua（DecisionEngine / StoryDB 用桩）。
-- 重点：`tcity:client:telemetry` 会写库，事件名/payload 大小/频率必须由服务端定。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { players = {}, inserts = {}, now = 1000 }

local function makePlayer(source)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, name = 'p' .. source, license = 'LIC' .. source,
        job = { name = 'unemployed', type = 'none', onduty = false, grade = { level = 0 } },
        gang = { name = 'none', grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'T', lastname = 'P' },
    }
    player.Functions = { SetMetaData = function() end, Notify = function() end }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetPlayers = function() return {} end,
        HasPermission = function() return false end,
        CreateCallback = function() end,
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
TriggerClientEvent = function() end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return state.now end
GetCurrentResourceName = function() return 'story-engine' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetConvar = function(_, default) return default end
IsPlayerAceAllowed = function() return false end
LoadResourceFile = function(_, filename)
    local handle = io.open(RES .. '/' .. filename, 'r')
    if not handle then return nil end
    local content = handle:read('a')
    handle:close()
    return content
end
SaveResourceFile = function() return true end
Citizen = { CreateThread = function() end, Wait = function() end, Await = function() end }

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function(value) return 'ENC:' .. tostring(#tostring(value)) end, decode = function() return {} end }
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
        if name == 'custom-logs' then return { LogSecurity = function() end, LogGeneric = function() end } end
        if name == 'oxmysql' then
            return {
                execute = function(_, sql, params)
                    state.inserts[#state.inserts + 1] = { sql = sql, params = params }
                    return true
                end,
            }
        end
        return setmetatable({}, { __index = function() return function(...) return true end end })
    end,
})

-- story-engine 的模块
DecisionEngine = {
    _pending = {},
    RegisterAll = function() return 0 end,
    Register = function() return true end,
    MakeChoice = function() return false, 'stub' end,
    Resolve = function() return true end,
    GetArcChoices = function() end,
    GetAllChoices = function() end,
    CheckChoiceCondition = function() end,
}
StoryDB = {
    GetPlayerChoices = function() end,
    Query = function() end,
}
QuestNodes = { Register = function() end, Get = function() end }
Bus = { RegisterService = function() end, Emit = function() end }

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
    source = source:gsub('(%w+)%s*%+=%s*%1%s*%+%s*', '%1 = %1 + ')
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/server/main.lua', 'server/main.lua')

local function fire(src, name, ...)
    local handler = handlers[name] or error('handler 未注册: ' .. name)
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

state.players[1] = makePlayer(1)

-- ── 1. 正常心跳/普通事件 ──
emit('SCENARIO', 'telemetry')
fire(1, 'tcity:client:telemetry', 'nui_focus', { ok = true })
fire(1, 'tcity:client:telemetry', 'heartbeat', {})
emit('TELEMETRY_VALID_ACCEPTED', 'true')

-- ── 2. 坏参数一律丢弃（不能抛错）──
local okBadEvent = fire(1, 'tcity:client:telemetry', nil, {})
local okLongEvent = fire(1, 'tcity:client:telemetry', string.rep('x', 500), {})
local okBadData = fire(1, 'tcity:client:telemetry', 'nui_focus', 'not-a-table')
local okNumberData = fire(1, 'tcity:client:telemetry', 'nui_focus', 42)
emit('TELEMETRY_BAD_ARGS_SAFE', tostring(okBadEvent and okLongEvent and okBadData and okNumberData))

-- ── 3. 频率上限：窗口内 120 条之后丢弃 ──
emit('SCENARIO', 'rate-limit')
state.now = 20000
local allowed = 0
for _ = 1, 200 do
    local before = #state.inserts
    fire(1, 'tcity:client:telemetry', 'spam', {})
    if #state.inserts > before then allowed = allowed + 1 end
end
emit('TELEMETRY_RATE_LIMITED', tostring(allowed > 0 and allowed <= 120))

-- 窗口滑动后恢复
state.now = 20000 + 61000
local before = #state.inserts
fire(1, 'tcity:client:telemetry', 'spam', {})
emit('TELEMETRY_WINDOW_RESETS', tostring(#state.inserts > before))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
