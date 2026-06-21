-- quest_validators.lua — 自定义步骤校验器注册系统
--
-- 外部脚本可注册自定义校验器，用于 script_trigger / validator 类型步骤
-- 校验器接收 (source, stepData, questData) → 返回 (boolean, string)

QuestValidators = QuestValidators or {}

-- 已注册的校验器: validator_id → function
QuestValidators._validators = {}

--- 注册校验器
---@param validatorId string
---@param validatorFn function function(source, stepData, questData) → boolean, string
---@return boolean success
---@return string|nil error
function QuestValidators.Register(validatorId, validatorFn)
    if not validatorId or type(validatorId) ~= 'string' then
        return false, 'Invalid validator ID'
    end

    if type(validatorFn) ~= 'function' then
        return false, 'Validator must be a function'
    end

    if QuestValidators._validators[validatorId] then
        return false, ('Validator already registered: %s'):format(validatorId)
    end

    QuestValidators._validators[validatorId] = validatorFn
    print(('[quest-validators] 🔧 Validator registered: %s'):format(validatorId))
    return true, nil
end

--- 执行校验器
---@param validatorId string
---@param source number
---@param stepData table
---@param questData table
---@return boolean passed
---@return string message
function QuestValidators.Run(validatorId, source, stepData, questData)
    local fn = QuestValidators._validators[validatorId]
    if not fn then
        return false, ('Validator not found: %s'):format(validatorId)
    end

    local ok, result = pcall(fn, source, stepData, questData)
    if not ok then
        return false, ('Validator error: %s'):format(tostring(result))
    end

    -- 校验器应返回 (boolean, string)
    if type(result) == 'boolean' then
        return result, result and 'passed' or 'failed'
    end

    return false, 'Validator returned unexpected type'
end

print('[quest-validators] ✅ 校验器注册系统已加载')