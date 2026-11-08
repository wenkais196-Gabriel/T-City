-- tests/unit/layer3_business/fixtures/interactsound_probe.lua
-- 真加载 interact-sound 的 server/main.lua。
-- 覆盖：全服/指定玩家播放只允许服务端触发、声音参数白名单、按人限流、距离上限。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { broadcasts = {}, timer = 1000, peds = {} }

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    state.broadcasts[#state.broadcasts + 1] = { name = name, target = target, args = { ... } }
end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return state.timer end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
GetEntityCoords = function(entity) return vector3(entity or 0, 0, 0) end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. chunkname))()
end

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

local function countSince(before, clientEvent)
    local n = 0
    for index = before + 1, #state.broadcasts do
        if state.broadcasts[index].name == clientEvent then n = n + 1 end
    end
    return n
end

-- ── 1. PlayOnAll / PlayOnOne：客户端触发必须无效 ──
emit('SCENARIO', 'global-sounds')
local b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnAll', 'Cuff', 0.5)
emit('ALL_FROM_CLIENT_BLOCKED', tostring(countSince(b, 'InteractSound_CL:PlayOnAll') == 0))
fireAs(0, 'InteractSound_SV:PlayOnAll', 'Cuff', 0.5)
emit('ALL_FROM_SERVER_ALLOWED', tostring(countSince(b, 'InteractSound_CL:PlayOnAll') == 1))

b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnOne', 2, 'Cuff', 0.5)
emit('ONE_FROM_CLIENT_BLOCKED', tostring(countSince(b, 'InteractSound_CL:PlayOnOne') == 0))

-- ── 2. PlayOnSource：参数白名单 + 限流 ──
emit('SCENARIO', 'play-on-source')
b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnSource', 'Cuff', 0.5)
emit('SOURCE_VALID_ALLOWED', tostring(countSince(b, 'InteractSound_CL:PlayOnOne') == 1))

b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnSource', 'Cuff', 0.5)      -- 同一 tick：被 100ms 限流
emit('SOURCE_RATE_LIMITED', tostring(countSince(b, 'InteractSound_CL:PlayOnOne') == 0))

state.timer = state.timer + 200
b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnSource', 'Cuff', 0.5)
emit('SOURCE_ALLOWED_AFTER_WINDOW', tostring(countSince(b, 'InteractSound_CL:PlayOnOne') == 1))

b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnSource', 'http://evil/x.mp3', 0.5)
emit('SOURCE_BAD_FILENAME_BLOCKED', tostring(countSince(b, 'InteractSound_CL:PlayOnOne') == 0))

b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayOnSource', 'Cuff', 42)
emit('SOURCE_BAD_VOLUME_BLOCKED', tostring(countSince(b, 'InteractSound_CL:PlayOnOne') == 0))

-- ── 3. PlayWithinDistance：距离上限 ──
emit('SCENARIO', 'distance')
state.timer = state.timer + 500
b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayWithinDistance', 5000, 'IndicatorOn', 0.2)
emit('DISTANCE_OVER_LIMIT_BLOCKED', tostring(countSince(b, 'InteractSound_CL:PlayWithinDistance') == 0))

state.timer = state.timer + 500
b = #state.broadcasts
fireAs(1, 'InteractSound_SV:PlayWithinDistance', 5.0, 'IndicatorOn', 0.2)
emit('DISTANCE_VALID_ALLOWED', tostring(countSince(b, 'InteractSound_CL:PlayWithinDistance') == 1))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
