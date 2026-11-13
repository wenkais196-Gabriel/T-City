-- tests/unit/layer3_business/fixtures/route_integration_probe.lua
-- 接得上吗？—— 配置 → QuestStepGate.ValidatorPayload → validate_route_stop 的整条链。
--
-- 为什么需要这条：`ValidatorPayload` 只给校验器 `validator_data` + 白名单 meta，
-- **`coords` 不在白名单里**。配置里把坐标只写在顶层 `data.coords`（客户端要用），
-- 校验器那边就拿到 nil，每站都判 `no_coords` —— 任务在真机上表现为"到了点没反应"。
-- 这条把整条链跑一遍，防止两边各写各的。

local RES = arg[1] or error('need resource dir')
local CONFIG = arg[2] or 'quest_garbage.lua'

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

-- ── 桩 ──
local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
vector3 = function(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end

local state = { coords = { x = 0.0, y = 0.0, z = 0.0 }, job = 'garbage' }
GetPlayerPed = function(source) return tonumber(source) or 0 end
GetEntityCoords = function() return vector3(state.coords.x, state.coords.y, state.coords.z) end
GetVehiclePedIsIn = function() return 0 end
GetConvar = function(_, default) return default end

QBCore = {
    Functions = {
        GetPlayer = function(source)
            if tonumber(source) ~= 1 then return nil end
            return { PlayerData = { citizenid = 'CID1', job = { name = state.job, onduty = true, grade = { level = 0 } } }, Functions = {} }
        end,
    },
}
QuestValidators = { _validators = {}, Register = function(id, fn) QuestValidators._validators[id] = fn end }

local function load_file(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. chunkname))()
end

load_file(RES .. '/server/quest_step_gate.lua', 'quest_step_gate.lua')
load_file(RES .. '/server/quest_route_validators.lua', 'quest_route_validators.lua')

local handle = assert(io.open(RES .. '/config/quests/' .. CONFIG, 'r'))
local source = handle:read('a')
handle:close()
local quests = assert(load(source, '@' .. CONFIG))()

local quest = quests[1]
local step = nil
for _, candidate in ipairs(quest.steps or {}) do
    if candidate.type == 'validator' then step = candidate break end
end
if not step then
    emit('HAS_VALIDATOR_STEP', 'false')
    io.write(table.concat(OUT, '\n'), '\n')
    return
end
emit('HAS_VALIDATOR_STEP', 'true')
-- 职业取自配置本身（不同配置文件服务不同职业）
for _, candidate in ipairs(quest.steps or {}) do
    if candidate.type == 'validator' and candidate.data and candidate.data.validator_data
        and type(candidate.data.validator_data.job) == 'string' then
        state.job = candidate.data.validator_data.job
        break
    end
end
emit('CONFIG_JOB', state.job)

-- 1. 载荷里到底有没有服务端坐标
local payload = QuestStepGate.ValidatorPayload(step)
emit('PAYLOAD_HAS_COORDS', tostring(type(payload.coords) == 'table'))
emit('PAYLOAD_HAS_INDEX', tostring(tonumber(payload.index) == 1))

-- 2. 用载荷真跑一次校验器（玩家站在这一站的坐标上）
local validate = QuestValidators._validators['validate_route_stop']
if not validate then
    emit('REGISTERED', 'false')
    io.write(table.concat(OUT, '\n'), '\n')
    return
end
emit('REGISTERED', 'true')

local target = payload.coords or step.data.coords
state.coords = { x = target.x, y = target.y, z = target.z }
local ok, code = validate(1, payload, { questId = quest.id, citizenid = 'CID1' })
emit('INTEGRATION_FIRST_STOP', tostring(ok == true) .. '|' .. tostring(code))

io.write(table.concat(OUT, '\n'), '\n')
