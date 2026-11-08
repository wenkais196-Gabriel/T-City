-- tests/unit/layer3_business/fixtures/ambulance_probe.lua
-- 真加载 qb-ambulancejob 的 config.lua + server/main.lua，直接调用事件 handler。
-- 覆盖：EMS 储物柜、床位释放、饥饿重置窗口、呼叫 EMS/医生、急救回执、医生计数、伤情夹取。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local clock = 1000000
os = setmetatable({ time = function() return clock end, date = os.date, clock = os.date }, { __index = os })

local state = {
    inventoryOpened = nil,
    broadcasts = {},
    players = {},
}

local function makePlayer(source, jobName, onduty, citizenid)
    -- qb-core 的 Functions.* 是闭包（用点调用，没有 self），mock 也必须闭包在 player 上
    local player = {}
    player.PlayerData = {
        source = source,
        citizenid = citizenid or ('CID' .. source),
        license = 'LIC' .. source,
        job = { name = jobName, onduty = onduty },
        -- 生产环境里 metadata 一定有 injail（否则 RespawnAtHospital 里 `> 0` 会崩）
        metadata = { injail = 0 },
        money = { cash = 5000, bank = 5000 },
    }
    player.Functions = {
        SetMetaData = function(key, value) player.PlayerData.metadata[key] = value end,
        RemoveMoney = function() return true end,
        ClearInventory = function() player.PlayerData.metadata = {} end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetQBPlayers = function()
            local list = {}
            for _, player in pairs(state.players) do list[#list + 1] = player end
            return list
        end,
        HasItem = function(source, item) return state.hasItem == true and item == 'firstaid' end,
        CreateCallback = function(name, fn) state.callbacks = state.callbacks or {}; state.callbacks[name] = fn end,
        SetPlayerMetaData = function() end,
        Notify = function() end,
        GetDutyCount = function() return 0 end,
        CreateUseableItem = function() end,
        CreateUseableItemServer = function() end,
    },
    Shared = { Items = setmetatable({}, { __index = function(_, key) return { label = tostring(key) } end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, args = { ... } }
end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function(_, fn) end
Wait = function() end
GetGameTimer = function() return clock end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
GetEntityCoords = function(entity) return vector3(entity or 0, 0, 0) end
GetInvokingResource = function() return 'test' end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
-- FiveM 的 vector3 支持 `a - b` 和 `#a`（距离校验用），mock 必须带上这两个元方法
local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
vector3 = function(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    update = function() return 1 end,
    insert = function() return 1 end,
    Async = { execute = function() end },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'qb-inventory' then
            return {
                OpenInventory = function(_, source, stash) state.inventoryOpened = { source = source, stash = stash } end,
                RemoveItem = function() return true end,
            }
        end
        if name == 'custom-career' then return { GetPlayerIdentity = function() return nil end } end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Z][A-Z0-9_]*)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

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

-- 玩家：1 号平民、2 号在班 EMS、3 号下班 EMS、4 号平民（病人）
state.players[1] = makePlayer(1, 'unemployed', false)
state.players[2] = makePlayer(2, 'ambulance', true)
state.players[3] = makePlayer(3, 'ambulance', false)
state.players[4] = makePlayer(4, 'unemployed', false)

local function readUpvalue(handlerName, wanted)
    local handler = handlers[handlerName]
    if not handler then return nil end
    for index = 1, 80 do
        local name, value = debug.getupvalue(handler, index)
        if not name then break end
        if name == wanted then return value end
    end
    return nil
end

-- ── 1. EMS 储物柜：平民 / 下班 EMS / 在班 EMS ──
emit('SCENARIO', 'stash')
state.inventoryOpened = nil
fireAs(1, 'qb-ambulancejob:server:stash')
emit('STASH_CIVILIAN_BLOCKED', tostring(state.inventoryOpened == nil))
state.inventoryOpened = nil
fireAs(3, 'qb-ambulancejob:server:stash')
emit('STASH_OFFDUTY_BLOCKED', tostring(state.inventoryOpened == nil))
state.inventoryOpened = nil
fireAs(2, 'qb-ambulancejob:server:stash')
emit('STASH_EMS_ALLOWED', tostring(state.inventoryOpened ~= nil and state.inventoryOpened.stash:find('ambulancestash_', 1, true) ~= nil))

-- ── 2. 床位释放：别人不能放，占用者能放，EMS 能收 ──
emit('SCENARIO', 'leave-bed')
-- 4 号被放进 1 号院 1 号床（走 SendToBed）
fireAs(4, 'hospital:server:SendToBed', 1, false, 1)
local bedOccupant = readUpvalue('hospital:server:LeaveBed', 'BedOccupant')
emit('BED_OCCUPIED', tostring(bedOccupant and bedOccupant['1:1'] == 4))
local before = #state.broadcasts
fireAs(1, 'hospital:server:LeaveBed', 1, 1)          -- 平民 1 号想放 4 号的床
local freedBy = 0
for index = before + 1, #state.broadcasts do
    if state.broadcasts[index].name == 'hospital:client:SetBed' then freedBy = freedBy + 1 end
end
emit('BED_RELEASED_BY_STRANGER', tostring(freedBy))
before = #state.broadcasts
fireAs(4, 'hospital:server:LeaveBed', 1, 1)          -- 占用者本人
local freedSelf = 0
for index = before + 1, #state.broadcasts do
    if state.broadcasts[index].name == 'hospital:client:SetBed' then freedSelf = freedSelf + 1 end
end
emit('BED_RELEASED_BY_OCCUPANT', tostring(freedSelf))

-- ── 3. 饥饿/口渴重置：窗口外拒绝，窗口内放行 ──
emit('SCENARIO', 'hunger')
fireAs(1, 'hospital:server:resetHungerThirst')
emit('HUNGER_OUTSIDE_WINDOW_BLOCKED', tostring(state.players[1].PlayerData.metadata['hunger'] == nil))
fireAs(1, 'hospital:server:RespawnAtHospital', 1)     -- 走一次合法的进院流程
fireAs(1, 'hospital:server:resetHungerThirst')
emit('HUNGER_AFTER_RESPAWN_ALLOWED', tostring(state.players[1].PlayerData.metadata['hunger'] == 100))

-- ── 4. 呼叫 EMS：文案类型 + 冷却 + 截断 ──
emit('SCENARIO', 'alert')
clock = clock + 1000
local b = #state.broadcasts
fireAs(1, 'hospital:server:ambulanceAlert', { evil = true })
emit('ALERT_NON_STRING_IGNORED', tostring(#state.broadcasts == b))
fireAs(1, 'hospital:server:ambulanceAlert', string.rep('A', 500))
local delivered = nil
for index = b + 1, #state.broadcasts do
    local entry = state.broadcasts[index]
    if entry.name == 'hospital:client:ambulanceAlert' and entry.target == 2 then
        delivered = entry.args[2]
    end
end
emit('ALERT_TO_ONDUTY_EMS', tostring(delivered ~= nil))
emit('ALERT_TEXT_TRUNCATED', tostring(delivered ~= nil and #delivered == 200))
local b2 = #state.broadcasts
fireAs(1, 'hospital:server:ambulanceAlert', 'again')
emit('ALERT_COOLDOWN_BLOCKED', tostring(#state.broadcasts == b2))

-- ── 5. 呼叫医生：伪造院名必须被拒 ──
emit('SCENARIO', 'doctor-call')
clock = clock + 60
b = #state.broadcasts
fireAs(1, 'hospital:server:SendDoctorAlert', 'not-a-hospital')
emit('DOCTOR_ALERT_FAKE_NAME_IGNORED', tostring(#state.broadcasts == b))

-- ── 6. 急救回执：没有 pending 就回答必须无效 ──
emit('SCENARIO', 'can-help')
b = #state.broadcasts
fireAs(1, 'hospital:server:CanHelp', 2, true)
emit('CANHELP_WITHOUT_PENDING', tostring(#state.broadcasts == b))
state.hasItem = true                                 -- 4 号背包里有 firstaid
fireAs(4, 'hospital:server:UseFirstAid', 1)           -- 4 号（持 firstaid）救 1 号
-- 从"合法的 CanHelp 之前"开始数，避免把上面那次无回执的调用算进来
local b2 = #state.broadcasts
fireAs(1, 'hospital:server:CanHelp', 4, true)         -- 1 号回答
local helped = 0
for index = b2 + 1, #state.broadcasts do
    if state.broadcasts[index].name == 'hospital:client:HelpPerson' then helped = helped + 1 end
end
emit('CANHELP_WITH_PENDING', tostring(helped == 1))

-- ── 7. 医生计数：只有被服务端登记过的在班 EMS 能减 ──
emit('SCENARIO', 'doctor-count')
-- doctorCount 是数字型 upvalue：每次读都要重新取（读出来的是快照）
local function doctorCountNow()
    return readUpvalue('hospital:server:RemoveDoctor', 'doctorCount') or 0
end
fireAs(2, 'hospital:server:AddDoctor', 'ambulance')
emit('DOCTOR_COUNT_AFTER_ADD', tostring(doctorCountNow()))
fireAs(1, 'hospital:server:RemoveDoctor', 'ambulance')  -- 平民想减
emit('DOCTOR_COUNT_AFTER_CIVILIAN', tostring(doctorCountNow()))
fireAs(2, 'hospital:server:RemoveDoctor', 'ambulance')
emit('DOCTOR_COUNT_AFTER_EMS', tostring(doctorCountNow()))

-- ── 8. 伤情同步：越界值必须被夹 ──
emit('SCENARIO', 'injuries')
fireAs(1, 'hospital:server:SyncInjuries', 'not-a-table')
emit('INJURIES_NON_TABLE_IGNORED', tostring(state.players[1].PlayerData.metadata['injuries'] == nil))
fireAs(1, 'hospital:server:SyncInjuries', { limbs = {}, isBleeding = 999999 })
local injuries = state.players[1].PlayerData.metadata['injuries']
emit('INJURIES_BLEEDING_CLAMPED', tostring(injuries ~= nil and injuries.isBleeding == 100))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
