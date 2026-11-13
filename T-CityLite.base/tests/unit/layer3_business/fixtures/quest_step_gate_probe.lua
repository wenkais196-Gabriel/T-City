-- tests/unit/layer3_business/fixtures/quest_step_gate_probe.lua
-- 真加载 custom-quest 的 server/quest_step_gate.lua（纯函数，零原生依赖），
-- 覆盖「哪些步骤必须过 validator」「校验器入参合成」「拦截开关默认值」。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

-- convar 桩：默认走 default，测试里可改
local convar = {}
GetConvar = function(name, default)
    if convar[name] ~= nil then return convar[name] end
    return default
end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/server/quest_step_gate.lua', 'quest_step_gate.lua')

-- ── 1. RequiredValidator ──
emit('RV_VALIDATOR_OK', tostring(QuestStepGate.RequiredValidator(
    { id = 's1', type = 'validator', data = { validator_id = 'validate_delivery_arrival' } })))
emit('RV_NO_ID', tostring(QuestStepGate.RequiredValidator(
    { id = 's1', type = 'validator', data = {} }) == nil))
emit('RV_EMPTY_ID', tostring(QuestStepGate.RequiredValidator(
    { id = 's1', type = 'validator', data = { validator_id = '' } }) == nil))
emit('RV_WRONG_TYPE', tostring(QuestStepGate.RequiredValidator(
    { id = 's1', type = 'reach', data = { validator_id = 'x' } }) == nil))
emit('RV_NIL_STEP', tostring(QuestStepGate.RequiredValidator(nil) == nil))
emit('RV_NO_DATA', tostring(QuestStepGate.RequiredValidator(
    { id = 's1', type = 'validator' }) == nil))

-- ── 2. ValidatorPayload：validator_data 打底 + 只合并白名单 meta ──
local step = {
    id = 's1', type = 'validator',
    data = {
        validator_id = 'validate_route_stop',
        -- UI 字段，不该进校验器入参
        coords = { x = 1, y = 2, z = 3 },
        label = '装载',
        duration = 3000,
        -- meta 字段，应该进
        radius = 10.0,
        destCoords = { x = 9, y = 9, z = 9 },
        validator_data = { index = 3, job = 'trucker' },
    },
}
local payload = QuestStepGate.ValidatorPayload(step)
emit('PAYLOAD_FROM_VALIDATOR_DATA', tostring(payload.index == 3 and payload.job == 'trucker'))
emit('PAYLOAD_META_RADIUS', tostring(payload.radius == 10.0))
emit('PAYLOAD_META_DEST', tostring(type(payload.destCoords) == 'table'))
emit('PAYLOAD_SKIPS_UI', tostring(payload.coords == nil and payload.label == nil and payload.duration == nil))

local empty = QuestStepGate.ValidatorPayload(nil)
emit('PAYLOAD_NIL_SAFE', tostring(type(empty) == 'table' and next(empty) == nil))

-- ── 3. Enforced：默认开，能一键关 ──
emit('ENFORCE_DEFAULT', tostring(QuestStepGate.Enforced() == true))
convar['quest_step_validator_enforce'] = '0'
emit('ENFORCE_OFF_ZERO', tostring(QuestStepGate.Enforced() == false))
convar['quest_step_validator_enforce'] = 'false'
emit('ENFORCE_OFF_FALSE', tostring(QuestStepGate.Enforced() == false))
convar['quest_step_validator_enforce'] = '1'
emit('ENFORCE_ON_ONE', tostring(QuestStepGate.Enforced() == true))
convar['quest_step_validator_enforce'] = nil

io.write(table.concat(OUT, '\n'), '\n')
