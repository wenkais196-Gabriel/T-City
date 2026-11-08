-- tests/unit/layer3_business/fixtures/lapraces_probe.lua
-- 真加载 qb-lapraces 的 config.lua + server/main.lua，mock FiveM 运行时，
-- 按客户端真实顺序触发事件，检查「正常完赛会不会结算 / 坏包会不会崩 / 0.001 能不能刷记录」。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { now = 0, inserts = {}, updates = {}, notifications = {}, clientEvents = {} }

local function mkplayer(source, cid)
    return {
        PlayerData = {
            source = source,
            citizenid = cid,
            charinfo = { firstname = 'Test', lastname = cid },
        },
        Functions = { SetMetaData = function() end },
    }
end

local host = mkplayer(1, 'HOSTCID')
local racer = mkplayer(2, 'RACERCID')
local players = { [1] = host, [2] = racer }

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
AddEventHandler = function(name, fn) if name == 'onResourceStart' then return end handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    local args = { ... }
    state.clientEvents[#state.clientEvents + 1] = { name = name, target = target, args = args }
    if name == 'QBCore:Notify' and args[1] then
        state.notifications[#state.notifications + 1] = tostring(args[1])
    end
end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return state.now end
GetConvar = function(_, default) return default end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
json = {
    encode = function(value) return 'encoded' end,
    decode = function(value) return {} end,
}

local function record(table_, key) return state[table_][key] end
MySQL = setmetatable({}, {
    __index = function(_, method)
        local function runner(...)
            local args = { ... }
            if method == 'insert' then
                state.inserts[#state.inserts + 1] = args
                return #state.inserts
            elseif method == 'update' then
                state.updates[#state.updates + 1] = args
                return 1
            end
            return 1
        end
        -- 同时支持 MySQL.insert(...) 与 MySQL.insert.await(...)
        return setmetatable({}, {
            __call = function(_, ...) return runner(...) end,
            __index = function(_, key)
                if key == 'await' then return runner end
                return function() return 1 end
            end,
        })
    end,
})

local function fire(name, ...)
    _G.source = select(1, ...) ~= nil and 1 or 1
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
    return ok
end

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
-- 让 HOSTCID 通过 IsWhitelisted
Config.WhitelistedCreators = { 'HOSTCID' }
load_lua(RES .. '/server/main.lua', 'main.lua')

-- ── 场景 1：保存赛道 → 从 MySQL.insert 的参数里掏出真实 raceid ──
local checkpoints = {
    [1] = { offset = { x = 0.0, y = 0.0, z = 0.0 }, coords = { x = 1.0, y = 2.0, z = 3.0 } },
}
fireAs(1, 'qb-lapraces:server:SaveRace', {
    RaceName = 'Probe Circuit',
    Checkpoints = checkpoints,
    RaceDistance = 1234,
})
local insertArgs = state.inserts[#state.inserts]
local raceId = insertArgs and insertArgs[2] and insertArgs[2][5]
emit('RACE_ID', raceId ~= nil)
-- 内存与 DB 的 raceid 必须一致（原来 GenerateRaceId 调了两次，两边不同）
emit('RACE_ID_MATCHES_DB', raceId ~= nil and insertArgs[2][5] == raceId)

-- ── 场景 2：未开放的赛道不能 Join（原来先改 Waiting 再 nil 索引崩）──
emit('SCENARIO', 'join-not-open')
local ok2 = fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
emit('JOIN_OK', ok2)

-- ── 场景 3：作者 SetupRace → 车手 Join → 开始 ──
emit('SCENARIO', 'host-open-and-join')
fireAs(1, 'qb-lapraces:server:SetupRace', raceId, 2)
local joinsBefore = 0
for _, event in ipairs(state.clientEvents) do
    if event.name == 'qb-lapraces:client:JoinRace' then joinsBefore = joinsBefore + 1 end
end
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = raceId })
local joinsAfter = 0
for _, event in ipairs(state.clientEvents) do
    if event.name == 'qb-lapraces:client:JoinRace' then joinsAfter = joinsAfter + 1 end
end
-- 只有赛道真的被打开，Join 才会把车手加进去并回包
emit('JOIN_WORKS_AFTER_SETUP', joinsAfter > joinsBefore)
fireAs(1, 'qb-lapraces:server:StartRace', raceId)
state.now = 200 * 1000 -- 服务端计时推进 200 秒

-- ── 场景 4：0.001 刷记录必须被拒 ──
emit('SCENARIO', 'cheat-bestlap')
local updatesBefore = #state.updates
fireAs(2, 'qb-lapraces:server:UpdateRacerData', raceId, 10, 2, true)
fireAs(2, 'qb-lapraces:server:FinishPlayer', {
    RaceId = raceId,
    RaceName = 'Probe Circuit',
}, 250, 2, 0.001)
emit('RECORD_WRITES_AFTER_CHEAT', #state.updates - updatesBefore)

-- ── 场景 5：正常完赛（客户端顺序：UpdateRacerData(true) 再 FinishPlayer）──
emit('SCENARIO', 'finish-normal')
local updatesBefore2 = #state.updates
fireAs(2, 'qb-lapraces:server:UpdateRacerData', raceId, 10, 2, true)
fireAs(2, 'qb-lapraces:server:FinishPlayer', {
    RaceId = raceId,
    RaceName = 'Probe Circuit',
}, 200, 2, 95)
emit('RECORD_WRITES_AFTER_NORMAL', #state.updates - updatesBefore2)

-- ── 场景 6：重复 FinishPlayer 不能二次结算 ──
emit('SCENARIO', 'finish-replay')
local updatesBefore3 = #state.updates
fireAs(2, 'qb-lapraces:server:FinishPlayer', {
    RaceId = raceId,
    RaceName = 'Probe Circuit',
}, 200, 2, 95)
emit('RECORD_WRITES_AFTER_REPLAY', #state.updates - updatesBefore3)

-- ── 场景 7：坏包 ──
emit('SCENARIO', 'bad-payloads')
fireAs(2, 'qb-lapraces:server:CancelRace', {})            -- 原来在类型检查之前就 `'..' .. raceId`
fireAs(2, 'qb-lapraces:server:UpdateRacerData', 12345, 1, 1, false)
fireAs(2, 'qb-lapraces:server:FinishPlayer', { RaceId = 12345 }, 1, 1, 1)
fireAs(2, 'qb-lapraces:server:JoinRace', { RaceId = 'LR-0000' })
fireAs(2, 'qb-lapraces:server:LeaveRace', { RaceId = 'LR-0000' })
emit('SCENARIO', 'done')

io.write(table.concat(OUT, '\n'), '\n')
