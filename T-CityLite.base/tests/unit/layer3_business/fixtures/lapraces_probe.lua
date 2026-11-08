-- tests/unit/layer3_business/fixtures/lapraces_probe.lua
-- 真加载 qb-lapraces 的 config.lua + server/main.lua，按客户端真实顺序触发事件。
-- 关注三件事：
--   1) 未开放 / 未开赛 / 圈数不符 / 0.001 最佳圈 / 大于平均圈的最佳圈 → 都不能写成绩；
--   2) 合法成绩只写一次，且最佳圈原样保留；
--   3) 全员完赛后比赛要真的被清掉（可以用"作者能否重新开放同一条赛道"来观察）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { now = 0, inserts = {}, updates = {}, clientEvents = {}, lastEncoded = nil }

local function mkplayer(source, cid)
    return {
        PlayerData = { source = source, citizenid = cid, charinfo = { firstname = 'Test', lastname = cid } },
        Functions = { SetMetaData = function() end },
    }
end

local players = { [1] = mkplayer(1, 'HOSTCID'), [2] = mkplayer(2, 'RACERCID'), [3] = mkplayer(3, 'RACER3CID') }

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return players[source] end,
        GetPlayerByCitizenId = function(cid)
            for _, p in pairs(players) do
                if p.PlayerData.citizenid == cid then return p end
            end
            return nil
        end,
        GetPermission = function() return 'user' end,
        CreateCallback = function() end,
        CreateUseableItem = function() end,
    },
    Commands = { Add = function() end },
    ServerCallbacks = {},
    Shared = { Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }) },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCoreMock end }
        end
        return setmetatable({}, { __index = function() return function() end end })
    end,
})

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
GetGameTimer = function() return state.now end
GetConvar = function(_, default) return default end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
json = { encode = function(value) state.lastEncoded = value; return 'encoded' end, decode = function() return {} end }

local function dbRunner(kind)
    return function(...)
        state[kind][#state[kind] + 1] = { ... }
        return 1
    end
end

MySQL = setmetatable({}, {
    __index = function(_, method)
        local runner = dbRunner(method == 'insert' and 'inserts' or 'updates')
        return setmetatable({}, {
            __call = function(_, ...) return runner(...) end,
            __index = function(_, key)
                if key == 'await' then return function(sql, params) return runner(sql, params) end end
                return function() return 1 end
            end,
        })
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
Config.WhitelistedCreators = { 'HOSTCID' }
load_lua(RES .. '/server/main.lua', 'main.lua')

local function joinEvents()
    local n = 0
    for _, event in ipairs(state.clientEvents) do
        if event.name == 'qb-lapraces:client:JoinRace' then n = n + 1 end
    end
    return n
end

-- ── 准备：保存一条 10 圈的赛道 ──
fireAs(1, 'qb-lapraces:server:SaveRace', {
    RaceName = 'Probe Circuit',
    Checkpoints = { [1] = { offset = { x = 0, y = 0, z = 0 }, coords = { x = 1, y = 2, z = 3 } } },
    RaceDistance = 1234,
})
local raceId = state.inserts[#state.inserts][2][5]
emit('RACE_ID', raceId ~= nil)

-- ── 1. 未开放的赛道不能加入 ──
emit('SCENARIO', 'join-not-open')
local joinsBefore = joinEvents()
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
emit('JOINED_WHEN_CLOSED', joinEvents() - joinsBefore)

-- ── 2. 没开赛不能报成绩 ──
emit('SCENARIO', 'finish-without-start')
fireAs(1, 'qb-lapraces:server:SetupRace', raceId, 10)
local updatesBefore = #state.updates
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 18)
emit('RECORD_WRITES_WITHOUT_START', #state.updates - updatesBefore)

-- ── 3. 开赛后加入 ──
emit('SCENARIO', 'race-running')
fireAs(1, 'qb-lapraces:server:StartRace', raceId)
fireAs(3, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
emit('JOIN_WORKS_AFTER_START', joinEvents() > joinsBefore)
state.now = 205 * 1000

-- ── 4. 各类伪造成绩必须被拒 ──
emit('SCENARIO', 'cheat-payloads')
local b = #state.updates
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 0.001)
emit('RECORD_WRITES_CHEAT', #state.updates - b)
b = #state.updates
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 45)  -- 45 > 平均 20
emit('RECORD_WRITES_BESTLAP_OVER_AVERAGE', #state.updates - b)
b = #state.updates
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 2, 18)   -- 圈数不符
emit('RECORD_WRITES_LAPS_MISMATCH', #state.updates - b)

-- ── 5. 合法成绩（10 圈 / 200 秒 / 最佳圈 18 秒）──
emit('SCENARIO', 'finish-normal')
b = #state.updates
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 18)
emit('RECORD_WRITES_NORMAL', #state.updates - b)
emit('RECORD_TIME', (state.lastEncoded and state.lastEncoded.Time) or 'nil')

-- ── 6. 重复结算（还有第三名车手未完赛）──
emit('SCENARIO', 'finish-replay')
b = #state.updates
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 18)
emit('RECORD_WRITES_REPLAY', #state.updates - b)

-- ── 7. 全员完赛 → 比赛必须被清掉（用"作者能否重新开放同一条赛道"观察）──
emit('SCENARIO', 'all-finished-cleanup')
fireAs(3, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 18)
local joinsAfterSettle = joinEvents()
fireAs(1, 'qb-lapraces:server:SetupRace', raceId, 10)
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
emit('REOPEN_AFTER_SETTLE', joinEvents() > joinsAfterSettle)

-- ── 8. 反序离开：未完赛者先走（DNF），已完赛者后走 → 仍要清掉比赛 ──
emit('SCENARIO', 'leave-reverse-order')
fireAs(1, 'qb-lapraces:server:StartRace', raceId)
fireAs(3, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
state.now = state.now + 205 * 1000
fireAs(2, 'qb-lapraces:server:LeaveRace', { RaceId = raceId })                 -- 未完赛：DNF
fireAs(3, 'qb-lapraces:server:FinishPlayer', { RaceId = raceId }, 200, 10, 18)
fireAs(3, 'qb-lapraces:server:LeaveRace', { RaceId = raceId })                 -- 已完赛：不补 DNF，但要清理
local joinsAfterLeave = joinEvents()
fireAs(1, 'qb-lapraces:server:SetupRace', raceId, 10)
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
emit('REOPEN_AFTER_LEAVE', joinEvents() > joinsAfterLeave)

-- ── 9. 坏包 ──
emit('SCENARIO', 'bad-payloads')
fireAs(2, 'qb-lapraces:server:CancelRace', {})
fireAs(2, 'qb-lapraces:server:UpdateRacerData', 12345, 1, 1, false)
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = 12345 }, 1, 1, 1)
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = 'LR-0000' })
fireAs(2, 'qb-lapraces:server:LeaveRace', { RaceId = 'LR-0000' })
emit('SCENARIO', 'done')

io.write(table.concat(OUT, '\n'), '\n')
