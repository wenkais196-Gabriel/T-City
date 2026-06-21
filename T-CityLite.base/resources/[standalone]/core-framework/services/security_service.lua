-- security_service.lua — 核心事件防火墙 (Event Firewall)
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 提供三大核心能力:
--   1. 输入清理器 (Sanitizer)       — 类型安全 + 边界钳制 + 模式校验
--   2. 变动阈值熔断 (ThresholdBreaker) — 单次上限 + 累计窗口 + 滑动熔断
--   3. source 权威校验 (SourceValidator) — 玩家有效性 + 在线状态 + 职业白名单
--
-- 使用示例:
--   local ok, cleaned, err = SecurityService.ValidateMoneyEvent(source, amount, 'bank', '工资')
--   local ok, err = SecurityService.ValidateJobEvent(source, 'police', 3)
--   local num = SecurityService.SanitizeNumber(rawInput, {min=1, max=100000, integer=true})

local QBCore = exports['qb-core']:GetCoreObject()
local SecurityService = {}

-- ==============================================================
-- 内部状态表
-- ==============================================================

-- 输入清洗类型定义
local SanitizerTypes = {
    number  = 'number',
    string  = 'string',
    boolean = 'boolean',
}

-- 累计熔断追踪: source → { action → { count, window_start, total_amount } }
local thresholdTracker = {}

-- ==============================================================
-- Convar 读取辅助
-- ==============================================================

local function GetIntConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return math.floor(tonumber(val) or default) end
    return default
end

local function GetNumConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return tonumber(val) or default end
    return default
end

-- ==============================================================
-- 1. 输入清理器 (Sanitizer)
-- ==============================================================

--- 安全清洗数值输入
---@param value any 原始输入
---@param bounds table { min, max, integer, defaultValue }
---@return number|nil cleaned 清洗后的值
---@return string|nil error 错误信息
function SecurityService.SanitizeNumber(value, bounds)
    bounds = bounds or {}
    local num = tonumber(value)

    -- 非数字 → 使用默认值或拒绝
    if num == nil then
        if bounds.defaultValue ~= nil then
            return bounds.defaultValue
        end
        return nil, 'Value is not a valid number'
    end

    -- NaN / Inf 检查
    if num ~= num or num == math.huge or num == -math.huge then
        if bounds.defaultValue ~= nil then
            return bounds.defaultValue
        end
        return nil, 'Value is NaN or infinite'
    end

    -- 整数强制
    if bounds.integer then
        num = math.floor(num + 0.5)
    end

    -- 最小值钳制
    if bounds.min ~= nil and num < bounds.min then
        return bounds.min, ('Value clamped to minimum (%.2f)'):format(bounds.min)
    end

    -- 最大值钳制（安全熔断核心）
    if bounds.max ~= nil and num > bounds.max then
        return bounds.max, ('Value clamped to maximum (%.2f)'):format(bounds.max)
    end

    return num
end

--- 安全清洗字符串输入
---@param value any 原始输入
---@param bounds table { maxLength, pattern, trim, defaultValue }
---@return string|nil cleaned
---@return string|nil error
function SecurityService.SanitizeString(value, bounds)
    bounds = bounds or {}

    -- 非字符串 → 转为字符串或使用默认值
    if type(value) ~= 'string' then
        if bounds.defaultValue ~= nil then
            return tostring(bounds.defaultValue)
        end
        -- 对 nil 特别处理
        if value == nil then
            return nil, 'Value is nil'
        end
        value = tostring(value)
    end

    -- Trim 首尾空白
    if bounds.trim ~= false then
        value = value:match('^%s*(.-)%s*$') or value
    end

    -- 最大长度截断
    if bounds.maxLength and #value > bounds.maxLength then
        value = value:sub(1, bounds.maxLength)
    end

    -- 正则模式校验（不匹配则拒绝）
    if bounds.pattern then
        if not value:match(bounds.pattern) then
            if bounds.defaultValue ~= nil then
                return bounds.defaultValue, 'Value did not match pattern, using default'
            end
            return nil, ('Value does not match required pattern: %s'):format(tostring(bounds.pattern))
        end
    end

    -- 空字符串检查
    if bounds.allowEmpty ~= true and #value == 0 then
        if bounds.defaultValue ~= nil then
            return bounds.defaultValue, 'Empty string, using default'
        end
        return nil, 'Value is empty'
    end

    return value
end

--- 通用输入清洗（自动根据 type 选择清洗器）
---@param value any
---@param options table { type, min, max, maxLength, pattern, integer, defaultValue }
function SecurityService.SanitizeInput(value, options)
    options = options or {}

    if options.type == 'number' then
        return SecurityService.SanitizeNumber(value, options)
    elseif options.type == 'string' then
        return SecurityService.SanitizeString(value, options)
    elseif options.type == 'boolean' then
        if type(value) == 'boolean' then return value end
        return not not value  -- truthy → boolean
    end

    return value  -- 未知类型，原样返回
end

-- ==============================================================
-- 2. Source 权威校验 (SourceValidator)
-- ==============================================================

--- 校验 source 是否为有效在线玩家
---@param source number
---@return boolean valid
---@return table|nil Player
---@return string|nil error
function SecurityService.ValidateSource(source)
    -- source 必须为正整数
    local src = tonumber(source)
    if not src or src <= 0 then
        return false, nil, 'Invalid source: ' .. tostring(source)
    end

    -- 必须能通过 GetPlayer 找到
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        return false, nil, 'Player not found for source: ' .. tostring(src)
    end

    -- PlayerData 完整性检查
    if not Player.PlayerData or not Player.PlayerData.citizenid then
        return false, nil, 'PlayerData incomplete for source: ' .. tostring(src)
    end

    return true, Player, nil
end

--- 校验 source + 职业白名单
---@param source number
---@param allowedJobs table|nil { police = true, ambulance = true } or nil for any
---@param requireOnDuty boolean|nil
function SecurityService.ValidateSourceWithJob(source, allowedJobs, requireOnDuty)
    local valid, Player, err = SecurityService.ValidateSource(source)
    if not valid then
        return false, nil, err
    end

    if allowedJobs then
        local jobName = Player.PlayerData.job and Player.PlayerData.job.name
        if not jobName or not allowedJobs[jobName] then
            return false, Player, ('Job not authorized: %s'):format(tostring(jobName))
        end
    end

    if requireOnDuty then
        local onDuty = Player.PlayerData.job and Player.PlayerData.job.onduty
        if not onDuty then
            return false, Player, 'Player is not on duty'
        end
    end

    return true, Player, nil
end

-- ==============================================================
-- 3. 变动阈值熔断 (ThresholdBreaker)
-- ==============================================================

--- 检测单次变动是否超过阈值（单笔熔断）
---@param source number
---@param amount number
---@param eventType string 'money' | 'item' | 'job' | 'gang'
---@return boolean allowed
---@return string|nil reason
function SecurityService.CheckSingleThreshold(source, amount, eventType)
    amount = tonumber(amount) or 0

    local maxSingle = GetIntConvar(
        ('security_max_single_%s'):format(eventType),
        -- 默认值按类型区分
        eventType == 'money' and 500000 or  -- 金钱: 50万
        eventType == 'item'  and 100 or     -- 物品: 100个
        1                                   -- job/gang: 1次
    )

    if amount > maxSingle then
        local Player = QBCore.Functions.GetPlayer(source)
        local isAdmin = Player and (QBCore.Functions.HasPermission(source, 'admin') or QBCore.Functions.HasPermission(source, 'god'))

        -- 管理员豁免
        if isAdmin then
            return true
        end

        return false, ('Single %s change ($%d) exceeds max ($%d)'):format(eventType, amount, maxSingle)
    end

    return true
end

--- 累计窗口熔断（时间窗口内累计变动）
---@param source number
---@param action string 操作标识
---@param amount number 本次变动量
---@param windowSec number 时间窗口（秒）
---@param maxCumulative number 窗口内最大累计量
---@return boolean allowed
---@return string|nil reason
function SecurityService.CheckCumulativeThreshold(source, action, amount, windowSec, maxCumulative)
    local now = os.time()
    amount = tonumber(amount) or 0

    if not thresholdTracker[source] then
        thresholdTracker[source] = {}
    end

    local tracker = thresholdTracker[source][action]
    if not tracker then
        tracker = { count = 0, window_start = now, total_amount = 0 }
        thresholdTracker[source][action] = tracker
    end

    -- 窗口过期 → 重置
    if now - tracker.window_start > windowSec then
        tracker.window_start = now
        tracker.count = 0
        tracker.total_amount = 0
    end

    -- 累计检查
    local newTotal = tracker.total_amount + amount
    if newTotal > maxCumulative then
        return false, ('Cumulative threshold exceeded: %d + %d = %d > %d in %ds'):format(
            tracker.total_amount, amount, newTotal, maxCumulative, windowSec
        )
    end

    -- 通过 → 更新追踪
    tracker.count = tracker.count + 1
    tracker.total_amount = newTotal

    return true
end

-- ==============================================================
-- 4. 事件级联合校验（组合校验器）
-- ==============================================================

--- 金钱事件全量校验（source + 金额清洗 + 单笔阈值 + 类型校验）
---@param source number
---@param amount any
---@param accountType string 'cash' | 'bank'
---@param reason string|nil
---@return boolean ok
---@return number cleanedAmount
---@return string|nil error
function SecurityService.ValidateMoneyEvent(source, amount, accountType, reason)
    -- 1. Source 校验
    local valid, Player, err = SecurityService.ValidateSource(source)
    if not valid then
        return false, 0, err
    end

    -- 2. 账户类型校验
    local validTypes = { cash = true, bank = true }
    if not validTypes[accountType] then
        return false, 0, 'Invalid account type: ' .. tostring(accountType)
    end

    -- 3. 金额清洗
    local cleanedAmount, cleanErr = SecurityService.SanitizeNumber(amount, {
        min = 0,
        max = GetIntConvar('security_max_single_money', 500000),
        integer = false,
    })
    if not cleanedAmount or cleanedAmount <= 0 then
        return false, 0, cleanErr or 'Invalid amount'
    end

    -- 4. 原因清洗（防注入）
    local cleanReason = reason
    if reason and type(reason) == 'string' then
        local cleaned, reasonErr = SecurityService.SanitizeString(reason, {
            maxLength = 128,
            pattern = '^[%w%p%s]+$',  -- 仅允许字母数字标点空格
        })
        if cleaned then
            cleanReason = cleaned
        else
            cleanReason = 'sanitized'
        end
    else
        cleanReason = 'unknown'
    end

    -- 5. 单笔阈值
    local thresholdOk, thresholdReason = SecurityService.CheckSingleThreshold(source, cleanedAmount, 'money')
    if not thresholdOk then
        return false, cleanedAmount, thresholdReason
    end

    -- 6. 10 分钟窗口累计熔断（可选，通过 Convar 开关）
    local enableCumulative = GetIntConvar('security_enable_cumulative_threshold', 1)
    if enableCumulative == 1 then
        local maxCumulative = GetIntConvar('security_max_cumulative_money', 2000000) -- 200万/10分钟
        local cumulativeOk, cumReason = SecurityService.CheckCumulativeThreshold(
            source, 'money_add', cleanedAmount, 600, maxCumulative
        )
        if not cumulativeOk then
            return false, cleanedAmount, cumReason
        end
    end

    return true, cleanedAmount, nil
end

--- 职业变更事件全量校验
---@param source number
---@param jobName string
---@param grade number|nil
---@return boolean ok
---@return string cleanedJobName
---@return number cleanedGrade
---@return string|nil error
function SecurityService.ValidateJobEvent(source, jobName, grade)
    -- 1. Source 校验
    local valid, _, err = SecurityService.ValidateSource(source)
    if not valid then
        return false, '', 0, err
    end

    -- 2. 职业名称清洗
    local cleanedJob, jobErr = SecurityService.SanitizeString(jobName, {
        maxLength = 32,
        pattern = '^[a-z0-9_]+$',
        defaultValue = 'unemployed',
    })
    if not cleanedJob then
        return false, '', 0, jobErr
    end

    -- 3. 等级清洗
    local cleanedGrade, gradeErr = SecurityService.SanitizeNumber(grade, {
        min = 0,
        max = 20,
        integer = true,
        defaultValue = 0,
    })
    if not cleanedGrade and gradeErr then
        return false, cleanedJob, 0, gradeErr
    end

    -- 4. 单次变动阈值（职业变更频率）
    local thresholdOk, thresholdReason = SecurityService.CheckSingleThreshold(source, 1, 'job')
    if not thresholdOk then
        return false, cleanedJob, cleanedGrade, thresholdReason
    end

    return true, cleanedJob, cleanedGrade or 0, nil
end

--- 帮派变更事件全量校验
---@param source number
---@param gangName string
---@param grade number|nil
function SecurityService.ValidateGangEvent(source, gangName, grade)
    -- 复用与 Job 相同的清洗逻辑
    local valid, cleanedGang, cleanedGrade, err = SecurityService.ValidateJobEvent(source, gangName, grade)
    if not valid then
        return false, '', 0, err
    end
    return true, cleanedGang, cleanedGrade, nil
end

--- 物品变动事件全量校验
---@param source number
---@param itemName string
---@param count any
function SecurityService.ValidateItemEvent(source, itemName, count)
    -- 1. Source 校验
    local valid, _, err = SecurityService.ValidateSource(source)
    if not valid then
        return false, '', 0, err
    end

    -- 2. 物品名清洗
    local cleanedItem, itemErr = SecurityService.SanitizeString(itemName, {
        maxLength = 64,
        pattern = '^[a-zA-Z0-9_]+$',
    })
    if not cleanedItem then
        return false, '', 0, itemErr
    end

    -- 3. 数量清洗
    local cleanedCount, countErr = SecurityService.SanitizeNumber(count, {
        min = 1,
        max = GetIntConvar('security_max_single_item', 100),
        integer = true,
    })
    if not cleanedCount then
        return false, cleanedItem, 0, countErr
    end

    return true, cleanedItem, cleanedCount, nil
end

-- ==============================================================
-- 5. 资质事件校验 (QualificationEventValidator)
-- ==============================================================

--- 校验资质变更事件
---@param source number 玩家服务器ID
---@param qualification string 资质标识
---@param action string 'grant' | 'revoke'
---@return boolean ok, string cleanedQual
function SecurityService.ValidateQualificationEvent(source, qualification, action)
    -- 1. Source 权威校验
    local valid, _, err = SecurityService.ValidateSource(source)
    if not valid then
        return false, nil
    end

    -- 2. 输入清洗
    local cleanedQual, qualErr = SecurityService.SanitizeString(qualification, {
        maxLength = 48,
        pattern = '^[a-z0-9_]+$',
    })
    if not cleanedQual then
        return false, nil
    end

    -- 3. Action 校验
    if action ~= 'grant' and action ~= 'revoke' then
        return false, nil
    end

    -- 4. 白名单校验 (资质必须在 QBConfig 中定义)
    if QBCore.Config.Qualifications and not QBCore.Config.Qualifications[cleanedQual] then
        return false, nil
    end

    return true, cleanedQual
end

-- ==============================================================
-- 6. 全局熔断开关（紧急关停所有敏感操作）
-- ==============================================================

--- 检查全局安全开关
---@param category string 'money' | 'item' | 'job' | 'gang' | 'all'
---@return boolean enabled
function SecurityService.IsSecurityEnabled(category)
    local globalSwitch = GetConvar('security_enable', 'true')
    if globalSwitch ~= 'true' then
        return false
    end
    if category == 'all' then
        return true
    end
    return GetConvar(('security_enable_%s'):format(category), 'true') == 'true'
end

-- ==============================================================
-- 6. 离线清理（防止内存泄露）
-- ==============================================================

AddEventHandler('playerDropped', function()
    local src = source
    if thresholdTracker[src] then
        thresholdTracker[src] = nil
    end
end)

-- ==============================================================
-- 7. 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('security', {
        -- 清洗器
        SanitizeNumber          = SecurityService.SanitizeNumber,
        SanitizeString          = SecurityService.SanitizeString,
        SanitizeInput           = SecurityService.SanitizeInput,

        -- 校验器
        ValidateSource          = SecurityService.ValidateSource,
        ValidateSourceWithJob   = SecurityService.ValidateSourceWithJob,
        ValidateMoneyEvent      = SecurityService.ValidateMoneyEvent,
        ValidateJobEvent        = SecurityService.ValidateJobEvent,
        ValidateGangEvent       = SecurityService.ValidateGangEvent,
        ValidateItemEvent       = SecurityService.ValidateItemEvent,
        ValidateQualificationEvent = SecurityService.ValidateQualificationEvent,

        -- 熔断器
        CheckSingleThreshold    = SecurityService.CheckSingleThreshold,
        CheckCumulativeThreshold = SecurityService.CheckCumulativeThreshold,

        -- 开关
        IsSecurityEnabled       = SecurityService.IsSecurityEnabled,
    })
end

-- 同时注册 PascalCase 别名，供 player.lua 的 Bus.SecurityService 使用
_G.Bus.SecurityService = SecurityService

print('[security-service] 🛡️  核心事件防火墙已注册到 Bus (Bus.security + Bus.SecurityService)')
print('[security-service]   Exports: ValidateMoneyEvent, ValidateJobEvent, ValidateGangEvent, ValidateItemEvent')
print('[security-service]   Sanitizer: SanitizeNumber, SanitizeString, SanitizeInput')
print('[security-service]   Threshold: single + cumulative (10min window)')
print('[security-service]   全局开关: security_enable / security_enable_money / security_enable_item')
print('[security-service]   单笔上限: security_max_single_money (default 500k)')