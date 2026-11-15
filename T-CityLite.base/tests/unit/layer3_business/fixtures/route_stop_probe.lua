-- tests/unit/layer3_business/fixtures/route_stop_probe.lua
-- 真加载 custom-quest 的 server/quest_route_validators.lua，用桩跑通
-- 「多站路线」校验器的判定：顺序 / 距离 / 职业 / 在岗 / 载具 / 坏参数。
--
-- 判定顺序即实现顺序：先顺序、再职业、再距离、再载具，最后才写会话。
-- 任何一条不通过都不许推进（否则玩家可以跳站）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    players = {},
    coords = { x = 0.0, y = 0.0, z = 0.0 },
    vehicle = 0,
}

-- ── vector3 桩（实现里用 #(pos - vector3(...)) 算距离）──
local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
vector3 = function(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end

-- ── FiveM / QBCore 桩 ──
GetPlayerPed = function(source) return tonumber(source) or 0 end
GetEntityCoords = function()
    if state.coordsFailed then return nil end
    return vector3(state.coords.x, state.coords.y, state.coords.z)
end
GetVehiclePedIsIn = function() return state.vehicle end

local function makePlayer(source, jobName, duty)
    return {
        PlayerData = {
            source = source, citizenid = 'CID' .. source,
            job = { name = jobName or 'unemployed', onduty = duty and true or false, grade = { level = 0 } },
            gang = { name = 'none', grade = { level = 0 } },
            metadata = {}, items = {},
        },
        Functions = {},
    }
end

QBCore = { Functions = { GetPlayer = function(source) return state.players[tonumber(source) or -1] end } }

-- 资源里用 exports['qb-core']:GetCoreObject() 取核心（不是全局 QBCore），桩要跟上
exports = setmetatable({}, { __index = function(_, key)
    if key == 'qb-core' then
        return { GetCoreObject = function() return QBCore end }
    end
    return nil
end })
state.players[1] = makePlayer(1, 'garbage', true)

-- 加载被测文件：注册表也用**真实实现**（Run 的返回值透传本身也要被测），不造假桩。
QuestValidators = nil
for _, rel in ipairs({ '/server/quest_validators.lua', '/server/quest_route_validators.lua' }) do
    local handle = assert(io.open(RES .. rel, 'r'))
    local source = handle:read('a'); handle:close()
    assert(load(source, '@' .. rel))()
end

local validate = QuestValidators._validators['validate_route_stop']
if not validate then
    OUT[#OUT + 1] = 'REGISTERED|false'
    io.write(table.concat(OUT, '\n'), '\n')
    return
end
emit('REGISTERED', 'true')

local function step(overrides)
    local base = {
        index = 1, radius = 10.0,
        coords = { x = 100.0, y = 200.0, z = 30.0 },
        job = 'garbage', require_duty = true,
        validator_id = 'validate_route_stop',
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return base
end

local questData = { questId = 'garbage_v1_city' }

local function run(overrides, coords, vehicle)
    if coords then state.coords = coords end
    state.vehicle = vehicle or 0
    local ok, code = validate(1, step(overrides), questData)
    return ok, tostring(code)
end

-- ── 1. 顺序正确 + 在站点 + 职业对 + 在岗：过 ──
state.coords = { x = 100.0, y = 200.0, z = 30.0 }
local ok, code = run({}, { x = 101.0, y = 200.0, z = 30.0 })
emit('FIRST_STOP_OK', tostring(ok == true and code == 'ok'))

-- ── 2. 会话已推进：第 2 站过，第 1 站再来被拒（乱序）──
local ok2 = run({ index = 2 })
emit('SECOND_STOP_OK', tostring(ok2 == true))
local ok3, code3 = run({ index = 1 })
emit('REPLAY_STOP_BLOCKED', tostring(ok3 == false and code3:find('out_of_order') ~= nil))

-- ── 3. 跳站（第 5 站，期望第 3 站）：拒 ──
local ok4, code4 = run({ index = 5 })
emit('SKIP_STOP_BLOCKED', tostring(ok4 == false and code4:find('out_of_order') ~= nil))

-- ── 4. 距离过远：拒 ──
local ok5, code5 = run({ index = 3 }, { x = 500.0, y = 200.0, z = 30.0 })
emit('FAR_BLOCKED', tostring(ok5 == false and code5:find('too_far') ~= nil))

-- 距离测试把玩家挪走了，后面几条要拉回站点，否则测到的是 too_far 而不是想测的那条
state.coords = { x = 100.0, y = 200.0, z = 30.0 }

-- ── 5. 职业不符：拒（且不推进会话）──
state.players[1].PlayerData.job = { name = 'trucker', onduty = true, grade = { level = 0 } }
local ok6, code6 = run({ index = 3 })
emit('WRONG_JOB_BLOCKED', tostring(ok6 == false and code6 == 'wrong_job'))

-- ── 6. 职业对但不在岗：拒 ──
state.players[1].PlayerData.job = { name = 'garbage', onduty = false, grade = { level = 0 } }
local ok7, code7 = run({ index = 3 })
emit('OFF_DUTY_BLOCKED', tostring(ok7 == false and code7 == 'off_duty'))

-- ── 7. 恢复在岗后，第 3 站仍然可过（前两次拒绝不该吞掉进度）──
state.players[1].PlayerData.job = { name = 'garbage', onduty = true, grade = { level = 0 } }
local ok8 = run({ index = 3 })
emit('SESSION_SURVIVES_REJECTS', tostring(ok8 == true))

-- ── 8. 需要载具但玩家不在车里：拒；在车里：过（第 4 站）──
local ok9, code9 = run({ index = 4, require_vehicle = true })
emit('NO_VEHICLE_BLOCKED', tostring(ok9 == false and code9 == 'no_vehicle'))
local ok10 = run({ index = 4, require_vehicle = true }, nil, 12345)
emit('VEHICLE_OK', tostring(ok10 == true))

-- ── 9. 坏参数：不抛错、不推进 ──
-- 用「当前该过的站号」测坏坐标，否则先被 out_of_order 拦掉，测不到 no_coords。
-- 注意：{ coords = nil } 在 Lua 里等于"没有这个键"，覆盖不掉默认值，必须显式删。
local badCoordsStep = step({ index = QuestRouteValidators.ExpectedIndex('CID1', 'garbage_v1_city') })
badCoordsStep.coords = nil
local okBadCoords, codeBadCoords = validate(1, badCoordsStep, questData)
emit('NO_COORDS_SAFE', tostring(okBadCoords == false and codeBadCoords == 'no_coords'))
local okBadIndex = validate(1, step({ index = 0 }), questData)
emit('BAD_INDEX_SAFE', tostring(okBadIndex == false))
local okNoPlayer = validate(99, step({ index = 5 }), questData)
emit('NO_PLAYER_SAFE', tostring(okNoPlayer == false))
local okNilStep = validate(1, nil, questData)
emit('NIL_STEP_SAFE', tostring(okNilStep == false))

-- ── 9b. 服务端取不到坐标：拒绝但**不抛错** ──
-- 旧实现是 #(playerCoords - vector3(...))，playerCoords 为 nil 时直接抛错，
-- 经 pcall 只剩一句截断的 "Validator error" —— 真机上就是这么卡住的。
local expectedIdx = QuestRouteValidators.ExpectedIndex('CID1', 'garbage_v1_city')
state.coordsFailed = true
local okNoPc, codeNoPc = validate(1, step({ index = expectedIdx }), questData)
emit('NO_PLAYER_COORDS_SAFE', tostring(okNoPc == false and codeNoPc == 'no_player_coords'))
state.coordsFailed = false

-- ── 9c. QuestValidators.Run 必须把第二返回值（原因）透出 ──
-- 旧实现 `local ok, result = pcall(...)` 会把它丢掉，所有拒绝都变成 'failed'.
state.players[1].PlayerData.job = { name = 'trucker', onduty = true, grade = { level = 0 } }
local runPassed, runMsg = QuestValidators.Run('validate_route_stop', 1,
    step({ index = QuestRouteValidators.ExpectedIndex('CID1', 'garbage_v1_city') }), questData)
emit('RUN_MESSAGE_PASSTHROUGH', tostring(runPassed == false and runMsg == 'wrong_job'))
state.players[1].PlayerData.job = { name = 'garbage', onduty = true, grade = { level = 0 } }

-- ── 10. 不同任务互不影响（会话键带 questId）──
local okOther = validate(1, step({ index = 1 }), { questId = 'bus_v1_loop' })
emit('SESSION_IS_PER_QUEST', tostring(okOther == true))

-- ── 11. 陈旧会话会锁死任务；接单时 ResetSession 必须能解开 ──
-- 场景：玩家在第 3 站放弃/掉线，会话停在 3；重新接单从第 1 站开始。
QuestRouteValidators.Sessions['CID1:garbage_v1_city'] = { index = 4, startedAt = 0 }
local okStale = validate(1, step({ index = 1 }), questData)
emit('STALE_SESSION_BLOCKS_RESTART', tostring(okStale == false))
QuestRouteValidators.ResetSession('CID1', 'garbage_v1_city')
local okRestart = validate(1, step({ index = 1 }), questData)
emit('RESET_SESSION_ALLOWS_RESTART', tostring(okRestart == true))

-- ── 12. 冷启动：没有会话时以当前步的站号为准（重启后不能把任务锁死）──
QuestRouteValidators.ResetSession('CID1', 'garbage_v1_city')
local okCold = validate(1, step({ index = 7 }), questData)
emit('COLD_START_ADOPTS_INDEX', tostring(okCold == true))
-- 之后又回到单调：第 7 站已经过了，再交第 7 站要拒
local okColdReplay = validate(1, step({ index = 7 }), questData)
emit('COLD_START_THEN_MONOTONIC', tostring(okColdReplay == false))

io.write(table.concat(OUT, '\n'), '\n')
