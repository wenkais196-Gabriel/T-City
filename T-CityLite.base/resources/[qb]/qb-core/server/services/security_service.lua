-- ============================================================================
-- SecurityService — 核心安全防火墙
-- ============================================================================
-- 职责:
--   1. 所有涉及金钱/职业/帮派/资质的 Server 端网络事件入口校验
--   2. source 权威校验 — 确保请求来自真实玩家而非客户端注入
--   3. 输入清洗 (Sanitizer) — 职业名/帮派名/资质名白名单过滤
--   4. 单笔阈值熔断 — 异常大额金钱变动直接拒绝
--
-- 注册路径: _G.Bus.SecurityService (在 onResourceStart 时自动挂载)
-- 使用者:   player.lua 中的 SetJob/SetGang/SetMoney 等核心方法
-- ============================================================================

local SecurityService = {}

-- ── 配置 ──────────────────────────────────────────────────────────────

-- 单笔交易阈值 (超过此值直接熔断，需管理员手动操作)
SecurityService.MONEY_MAX_SINGLE_TRANSACTION = 5000000 -- 500万

-- 被禁止的职业名 / 帮派名 (黑名单，防止注入伪造的职业)
SecurityService.BLOCKED_JOB_NAMES = {
    ['admin'] = true,
    ['root'] = true,
    ['owner'] = true,
    ['dev'] = true,
    ['developer'] = true,
}

SecurityService.BLOCKED_GANG_NAMES = {
    ['admin'] = true,
    ['root'] = true,
}

-- ── 工具函数 ──────────────────────────────────────────────────────────

---检查 source 是否对应一个在线的合法玩家
---@param source number
---@return boolean, table|nil
local function validateSource(source)
    if not source or tonumber(source) == nil then
        return false, nil
    end
    source = tonumber(source)
    if source <= 0 then
        return false, nil
    end
    -- 必须在 QBCore.Players 中存在
    local Player = QBCore.Players[source]
    if not Player or not Player.PlayerData then
        return false, nil
    end
    return true, Player
end

---清洗字符串：去空白、转小写、截断超长输入
---@param str string
---@param maxLen number
---@return string
local function sanitizeString(str, maxLen)
    maxLen = maxLen or 64
    if type(str) ~= 'string' then return '' end
    str = str:gsub('%s+', ''):lower()
    if #str > maxLen then
        str = str:sub(1, maxLen)
    end
    return str
end

---校验数值是否合理
---@param value any
---@return boolean, number|nil
local function sanitizeNumber(value)
    local num = tonumber(value)
    if not num then return false, nil end
    if num ~= num then return false, nil end -- NaN check
    if num == math.huge or num == -math.huge then return false, nil end
    return true, num
end

-- ── 公开 API ──────────────────────────────────────────────────────────

---校验职业变更事件
---@param source number 玩家服务器ID
---@param job string 目标职业名
---@param grade string|number 目标等级
---@return boolean ok, string cleanedJob, string cleanedGrade
function SecurityService.ValidateJobEvent(source, job, grade)
    -- 1. Source 权威校验
    local ok, Player = validateSource(source)
    if not ok then
        return false, nil, nil
    end

    -- 2. 输入清洗
    local cleanedJob = sanitizeString(job, 32)
    if cleanedJob == '' then
        return false, nil, nil
    end

    -- 3. 黑名单过滤
    if SecurityService.BLOCKED_JOB_NAMES[cleanedJob] then
        print(('[SECURITY] Player %d attempted to set blocked job: %s'):format(source, cleanedJob))
        return false, nil, nil
    end

    -- 4. 白名单校验 (职业必须在 QBShared.Jobs 中存在)
    if not QBCore.Shared.Jobs[cleanedJob] then
        return false, nil, nil
    end

    -- 5. 等级清洗
    local cleanedGrade = tostring(grade or '0')
    -- 等级必须在当前职业的 grades 中存在
    if not QBCore.Shared.Jobs[cleanedJob].grades[cleanedGrade] then
        return false, nil, nil
    end

    return true, cleanedJob, cleanedGrade
end

---校验帮派变更事件
---@param source number 玩家服务器ID
---@param gang string 目标帮派名
---@param grade string|number 目标等级
---@return boolean ok, string cleanedGang, string cleanedGrade
function SecurityService.ValidateGangEvent(source, gang, grade)
    -- 1. Source 权威校验
    local ok = validateSource(source)
    if not ok then
        return false, nil, nil
    end

    -- 2. 输入清洗
    local cleanedGang = sanitizeString(gang, 32)
    if cleanedGang == '' then
        return false, nil, nil
    end

    -- 3. 黑名单过滤
    if SecurityService.BLOCKED_GANG_NAMES[cleanedGang] then
        print(('[SECURITY] Player %d attempted to set blocked gang: %s'):format(source, cleanedGang))
        return false, nil, nil
    end

    -- 4. 白名单校验
    if not QBCore.Shared.Gangs[cleanedGang] then
        return false, nil, nil
    end

    -- 5. 等级清洗
    local cleanedGrade = tostring(grade or '0')
    if not QBCore.Shared.Gangs[cleanedGang].grades[cleanedGrade] then
        return false, nil, nil
    end

    return true, cleanedGang, cleanedGrade
end

---校验金钱变动事件
---@param source number 玩家服务器ID
---@param amount number 金额
---@param moneytype string 货币类型
---@param reason string 变动原因
---@return boolean ok, number cleanedAmount
function SecurityService.ValidateMoneyEvent(source, amount, moneytype, reason)
    -- 1. Source 权威校验
    local ok = validateSource(source)
    if not ok then
        return false, nil
    end

    -- 2. 数值清洗
    local numOk, cleanedAmount = sanitizeNumber(amount)
    if not numOk then
        return false, nil
    end

    -- 3. 负数拒绝 (SetMoney 不接受负数)
    if cleanedAmount < 0 then
        return false, nil
    end

    -- 4. 货币类型白名单
    if not moneytype or not QBCore.Config.Money.MoneyTypes[moneytype:lower()] then
        -- moneytype 存在但不在配置中 — 可能是新货币类型，允许通过但记录日志
        -- 如果 moneytype 根本不存在则拒绝
        if type(moneytype) ~= 'string' then
            return false, nil
        end
    end

    -- 5. 单笔阈值熔断
    if cleanedAmount > SecurityService.MONEY_MAX_SINGLE_TRANSACTION then
        print(('[SECURITY] Player %d attempted SetMoney of $%d (%s) — EXCEEDS THRESHOLD, BLOCKED'):format(source, cleanedAmount, moneytype or 'unknown'))
        return false, nil
    end

    return true, cleanedAmount
end

---校验资质变更事件
---@param source number 玩家服务器ID
---@param qualification string 资质标识
---@param action string 'grant' | 'revoke'
---@return boolean ok, string cleanedQual
function SecurityService.ValidateQualificationEvent(source, qualification, action)
    -- 1. Source 权威校验
    local ok = validateSource(source)
    if not ok then
        return false, nil
    end

    -- 2. 输入清洗
    local cleanedQual = sanitizeString(qualification, 48)
    if cleanedQual == '' then
        return false, nil
    end

    -- 3. Action 校验
    if action ~= 'grant' and action ~= 'revoke' then
        return false, nil
    end

    -- 4. 白名单校验 (资质必须在配置表中定义)
    if QBCore.Config.Qualifications and not QBCore.Config.Qualifications[cleanedQual] then
        return false, nil
    end

    return true, cleanedQual
end

-- ── 自注册到全局 Bus (双命名: PascalCase + lowercase) ──────────────

-- 立即可用: 同时注册到两个 Bus 路径，确保 player.lua 和 core-framework 都能找到
if not _G.Bus then
    _G.Bus = {}
end
_G.Bus.SecurityService = SecurityService  -- PascalCase (player.lua references)
_G.Bus.security = SecurityService          -- lowercase (core-framework Bus pattern)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if not _G.Bus then _G.Bus = {} end
        _G.Bus.SecurityService = SecurityService
        _G.Bus.security = SecurityService

        -- 如果 core-framework 已加载，委托到其更完整的 SecurityService
        -- (core-framework 的版本有 SanitizeNumber/SanitizeString 等额外能力)
        if _G.Bus.security and _G.Bus.security.SanitizeNumber then
            -- core-framework 的 SecurityService 已注册到 Bus.security
            -- 保留 qb-core 版本作为 backward-compat 别名
            print('[SecurityService] ✅ Registered (dual-namespace: Bus.SecurityService + Bus.security)')
        else
            print('[SecurityService] ✅ Registered to _G.Bus.SecurityService')
        end
    end
end)
