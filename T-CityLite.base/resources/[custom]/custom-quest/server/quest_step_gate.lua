-- server/quest_step_gate.lua — validator 步骤的服务端闸（阶段 D · C1）
--
-- 背景（2026-11-13 调研 §2.1-5）：
--   `validator` 类型步骤只在 `quest:server:dashboardStampDelivery` 这条路径上执行过
--   `validator_id`；客户端 `nodeComplete` 路径（client/main.lua 对带 coords 的 validator 步骤
--   也画了交互点）直接 `ValidateNode` → `AdvanceStep`，**validator 从来没跑过**。
--   也就是说「到达判定」「绑定载具」这类校验，走客户端那条腿时可以整段跳过。
--
-- 本文件只做两件事，保持纯函数：
--   1. RequiredValidator(step)      → 这个步骤必须过哪个 validator（不需要返回 nil）
--   2. ValidatorPayload(step)       → 把校验器关心的字段合并成它要的入参
-- 是否真的拦截由调用方决定（convar `quest_step_validator_enforce`，默认开，可一键回滚）。
--
-- 为什么不把 `QuestValidators.Run` 也搬进来：它依赖 source/pcall，搬进来就没法离线测。
-- 本文件零依赖、零原生调用，测试见 tests/unit/layer3_business/test_quest_step_gate.py。

QuestStepGate = QuestStepGate or {}

--- 校验器关心的 meta 字段（与 dashboardStampDelivery 的同名白名单保持一份）
QuestStepGate.META_KEYS = {
    destCoords = true, radius = true, use_bound_vehicle = true,
    require_trailer = true, returnCoords = true,
    allowed_classes = true, fallback_model = true,
    rental_fee_percent = true, rental_deposit = true,
}

--- 该步骤是否必须通过 validator；不需要时返回 nil
---@param step table|nil
---@return string|nil validatorId
--: 哪些步骤类型必须过校验器。**新类型一定要加进来**：
--: `rental` 初版只加到客户端表现里，忘了加这张表，结果押金那一步的校验器根本没跑 ——
--: 真机表现是「任务能推进，但一分钱押金没扣、日志里连 rental_open 都没有」。
QuestStepGate.VALIDATED_TYPES = {
    validator = true,
    rental    = true,   -- 租借点：validate_rental_open 负责扣押金与建会话
}

function QuestStepGate.RequiredValidator(step)
    if type(step) ~= 'table' then return nil end
    if not QuestStepGate.VALIDATED_TYPES[step.type] then return nil end
    local data = step.data
    if type(data) ~= 'table' then return nil end
    local validatorId = data.validator_id
    if type(validatorId) ~= 'string' or validatorId == '' then return nil end
    return validatorId
end

--- 校验器入参：step.data.validator_data 打底，再合并白名单里的 meta 字段
---@param step table|nil
---@return table payload
function QuestStepGate.ValidatorPayload(step)
    local payload = {}
    if type(step) ~= 'table' or type(step.data) ~= 'table' then return payload end
    local base = step.data.validator_data
    if type(base) == 'table' then
        for key, value in pairs(base) do
            if type(key) == 'string' then payload[key] = value end
        end
    end
    for key in pairs(QuestStepGate.META_KEYS) do
        local value = step.data[key]
        if value ~= nil then payload[key] = value end
    end
    return payload
end

--- 是否启用拦截。默认开；`setr quest_step_validator_enforce 0` 一键退回旧行为（只记日志不拦）
---@return boolean
function QuestStepGate.Enforced()
    local raw = '1'
    if type(GetConvar) == 'function' then
        raw = GetConvar('quest_step_validator_enforce', '1')
    end
    if raw == nil then return true end
    raw = tostring(raw)
    return not (raw == '0' or raw == 'false' or raw == 'off')
end
