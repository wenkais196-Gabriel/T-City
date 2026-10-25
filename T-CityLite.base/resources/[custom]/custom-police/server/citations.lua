-- server/citations.lua — police_citations 的唯一写者
--
-- 收口前的两处毛病：
--  1. p1（玩家开单）的 INSERT 用 `plate ~= '' and plate or nil` 和 `tonumber(incident_id)`
--     直接塞进参数数组 —— plate 为空（很常见）或 incident_id 缺失时数组在中间出现空洞，
--     oxmysql 截断 → 少于占位符 → MariaDB 语法错 → InsertId() 拿到错误字符串 → 'db_error'。
--     也就是"不带车牌开罚单"这条路一直是坏的。
--  2. 金额规则分两处：p1 只校验 1..50000，p2 有 0.8~1.2 倍基准价的钳制（deriveCitationAmount）。
--     同一张表两个价格政策，谁写进去的取决于调用方。
--
-- 现在：列集合按需拼接（NULL 进 SQL，参数数组永不留洞），金额政策只有一份：
--   * 带 `base_amount`（按罪名开单）→ 钳制到 [0.8×base, 1.2×base]；
--   * 不带 → 自由金额 1..50000（玩家手写罚单）。
--
-- 审计（citation.issue）在写者里统一记，调用方不要再记第二条。

PoliceCitations = PoliceCitations or {}

--: 按罪名开单时的浮动区间（与旧 p2 的 deriveCitationAmount 一致），用**整数百分比**做边界：
--  双精度的 0.8/1.2 会把 500 的边界算成 401/599（0.8×500 = 400.00000000000006 → ceil 401，
--  1.2×500 = 599.9999999999999 → floor 599）。改成 base×8/10、base×12/10 没有这个问题。
local CITATION_LOW_PERCENT = 80
local CITATION_HIGH_PERCENT = 120
local MAX_AMOUNT = 50000
local MAX_REASON = 240
local MAX_CHARGE_ID = 32
local MAX_PLATE = 12

local function clean(value, maxLen)
    if type(value) ~= 'string' then return '' end
    return value:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, maxLen)
end

--- 按罪名基准价推导罚金。`requested` 为空时取基准价本身。
---@param base number 罪名基准价
---@param requested number|nil 执法者指定的金额
---@return number|nil amount, string|nil reason
function PoliceCitations.PolicyAmount(base, requested)
    local value = tonumber(base)
    if not value or value <= 0 then return nil, 'invalid_base' end
    local low = math.ceil(value * CITATION_LOW_PERCENT / 100)
    local high = math.floor(value * CITATION_HIGH_PERCENT / 100)
    if high < low then high = low end

    local amount
    if requested == nil then
        amount = value
    else
        amount = tonumber(requested)
        if not amount then return nil, 'invalid_amount' end
        amount = math.floor(amount)
    end

    if amount < low then amount = low end
    if amount > high then amount = high end
    return math.floor(amount)
end

--- 写一张罚单。
---@param actorCid string 开单警官的 citizenid
---@param params table { citizenid, amount, base_amount?, reason, plate?, incident_id?, charge_id?, report_id? }
---@return number|nil id, number|string|nil 成功时是结算金额，失败时是原因字符串
function PoliceCitations.Insert(actorCid, params)
    if type(params) ~= 'table' then return nil, 'invalid_params' end

    local target = tostring(params.citizenid or ''):sub(1, 50)
    if target == '' then return nil, 'invalid_citizen' end

    local reason = clean(params.reason, MAX_REASON)
    if #reason < 3 then return nil, 'invalid_reason' end

    local amount
    if params.base_amount ~= nil then
        local derived, deriveReason = PoliceCitations.PolicyAmount(params.base_amount, params.amount)
        if not derived then return nil, deriveReason end
        amount = derived
    else
        local requested = tonumber(params.amount)
        if not requested or requested < 1 or requested > MAX_AMOUNT then return nil, 'invalid_amount' end
        amount = math.floor(requested)
    end

    -- 列集合按需拼接：不存在的字段写成 SQL 里的 NULL，绝不留参数洞
    local columns = { 'citizenid', 'officer_citizenid', 'amount', 'reason' }
    local placeholders = { '?', '?', '?', '?' }
    local values = { target, actorCid, amount, reason }
    local function add(column, value)
        if value == nil then return end
        columns[#columns + 1] = column
        placeholders[#placeholders + 1] = '?'
        values[#values + 1] = value
    end

    local plate = clean(params.plate, MAX_PLATE):upper()
    add('plate', plate ~= '' and plate or nil)
    add('incident_id', tonumber(params.incident_id))
    local chargeId = tostring(params.charge_id or ''):sub(1, MAX_CHARGE_ID)
    add('charge_id', chargeId ~= '' and chargeId or nil)
    add('base_amount', tonumber(params.base_amount))
    add('report_id', tonumber(params.report_id))

    local inserted = MySQL.insert.await(
        ('INSERT INTO police_citations (%s) VALUES (%s)'):format(
            table.concat(columns, ', '), table.concat(placeholders, ', ')),
        values)
    local id = InsertId(inserted)
    if not id or id == 0 then return nil, 'db_error' end

    local audited = PoliceAudit.Write(actorCid, 'citation.issue', target,
        ('$%d %s'):format(amount, reason))
    if not audited then
        print(('[custom-police] citation.issue audit failed for #%s'):format(tostring(id)))
    end

    -- 第二/第三个返回值：**结算后**的金额（调用方拿它写通知，别再自己算）与审计是否写成功
    -- （agent 路径要据此上报 audit_unavailable，玩家路径只记日志）。
    return tonumber(id), amount, audited
end

--- 抢占一张未付罚单（付款第一步）。并发下只有一个调用者能抢到：
--- 条件 UPDATE 匹配 `status = 'unpaid'` 的行，affectedRows 告诉调用方有没有抢到。
---@param id number
---@param citizenid string
---@return boolean claimed, boolean ok
function PoliceCitations.ClaimPaid(id, citizenid)
    local ok, result = pcall(function()
        return MySQL.update.await(
            "UPDATE police_citations SET status = 'paid', paid_at = NOW()"
            .. " WHERE id = ? AND citizenid = ? AND status = 'unpaid'",
            { tonumber(id), tostring(citizenid) })
    end)
    if not ok then return false, false end
    local affected = 0
    if type(result) == 'table' then
        affected = tonumber(result.affectedRows) or tonumber(result.affected_rows) or 0
    elseif type(result) == 'number' then
        affected = result
    end
    return affected > 0, true
end

--- 把刚抢占的罚单放回去（扣款失败时）。
---@param id number
---@return boolean ok
function PoliceCitations.RevertPaid(id)
    local ok, result = pcall(function()
        return MySQL.update.await(
            "UPDATE police_citations SET status = 'unpaid', paid_at = NULL"
            .. " WHERE id = ? AND status = 'paid'",
            { tonumber(id) })
    end)
    return ok and type(result) ~= 'string'
end
