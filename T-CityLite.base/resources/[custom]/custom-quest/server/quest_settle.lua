-- server/quest_settle.lua — 结算账单（热狗线 S5）
--
-- 一句话：把「这一班到底赚了多少」算清楚，并且**只算一次**。
--
-- 账单六类（A6 / A19）：
--   押金      + 退回
--   租金      − 按时长
--   售出      + 已付现（**不进净额**：每笔成交当时就把现金给了玩家）
--   成品回收  + 打烊时剩下的成品折价
--   原料回收  + 剩下的原料折价
--   税        − 无税率时显示 0%（未启用）
--
-- 净额 = 押金 + 租金(负) + 成品回收 + 原料回收 − 税
--       （售出那一行**不参与**：否则玩家会以为「净额」里又赚了一次卖热狗的钱）
--
-- 幂等：同一 (citizenid, questId, settleKey) 只发一张回执；重复调用返回同一张，
-- 但 `replayed = true`（玩家看得到，但不会被算成「又赚了一次」）。
--
-- 为什么不落库：账单是**展示**，钱已经在各处结清了（押金在 rental、售出在 vendor）。
-- 落库会引入第二处真相，两边对不上时没人知道以谁为准。内存保留最近 5 张，
-- 供「关闭后回看」（A6）；重启后回看不到 —— 这比「回看一张算错的账单」要好。

QuestSettle = QuestSettle or {}

local KEEP_PER_PLAYER = 5

--- citizenid → { [questId] = { receipts = { ... } } }
local Ledgers = {}

local function money(value)
    local num = tonumber(value)
    if not num then return 0 end
    return math.floor(num * 100 + 0.5) / 100
end

--- 取配置里的百分比折价（0.x），缺省 0
local function ratio(value)
    local num = tonumber(value)
    if not num or num < 0 then return 0 end
    if num > 1 then return 1 end
    return num
end

--- 纯计算：喂数字，出账单。不碰钱、不碰玩家、不碰时间。
---@param parts table {
---   depositRefund = number|nil,   -- 押金退回（正数）
---   rent          = number|nil,   -- 租金（正数，账单里显示为负）
---   soldTotal     = number|nil,   -- 售出总额（已付现，不进净额）
---   leftover      = table|nil,    -- { common=, rare=, exotic= } 剩余成品
---   prices        = table|nil,    -- { common=, rare=, exotic= } 单价
---   recycleRatio  = number|nil,   -- 成品回收折价比例（默认 0.5）
---   raw           = number|nil,   -- 剩余原料份数
---   rawUnit       = number|nil,   -- 每份原料成本（默认 2）
---   taxRate       = number|nil,   -- 税率（0.x）；0 或 nil → 显示未启用
--- }
---@return table receipt
function QuestSettle.Compute(parts)
    parts = type(parts) == 'table' and parts or {}

    local deposit = money(parts.depositRefund)
    local rent = money(parts.rent)
    local soldTotal = money(parts.soldTotal)

    -- 成品回收：按单价 × 折价比例 × 剩余份数
    local recycleRatio = parts.recycleRatio
    if recycleRatio == nil then recycleRatio = 0.5 end
    recycleRatio = ratio(recycleRatio)
    local leftoverValue = 0
    local leftover = type(parts.leftover) == 'table' and parts.leftover or {}
    local prices = type(parts.prices) == 'table' and parts.prices or {}
    for _, quality in ipairs({ 'common', 'rare', 'exotic' }) do
        local count = tonumber(leftover[quality]) or 0
        local unit = tonumber(prices[quality]) or 0
        if count > 0 and unit > 0 then
            leftoverValue = leftoverValue + count * unit * recycleRatio
        end
    end
    leftoverValue = money(leftoverValue)

    -- 原料回收：按每份成本折半（v1 抽象库存没有真实采购价，用固定单价说明白）
    local rawUnit = tonumber(parts.rawUnit)
    if rawUnit == nil then rawUnit = 2 end
    local rawCount = tonumber(parts.raw) or 0
    local rawValue = money(rawCount > 0 and rawCount * rawUnit * 0.5 or 0)

    -- 税：基数是「售出 + 回收」（押金是玩家自己的钱，不能上税）
    local taxRate = ratio(parts.taxRate or 0)
    local taxable = soldTotal + leftoverValue + rawValue
    local tax = money(taxable * taxRate)

    -- 净额：售出**不参与**（已付现）。押金退回是「钱回到手里」，租金是「这一班的成本」，
    -- 回收是「没卖掉的货折成钱」。
    local net = money(deposit - rent + leftoverValue + rawValue - tax)

    return {
        rows = {
            { id = 'deposit', label = '押金退回', amount = deposit, kind = 'in' },
            { id = 'rent', label = '租金（按时长）', amount = -rent, kind = 'out' },
            { id = 'sold', label = '售出（已付现）', amount = soldTotal, kind = 'cash', counted = false },
            { id = 'leftover', label = '成品回收', amount = leftoverValue, kind = 'in' },
            { id = 'raw', label = '原料回收', amount = rawValue, kind = 'in' },
            {
                id = 'tax',
                label = taxRate > 0 and ('税（%s%%）'):format(tostring(math.floor(taxRate * 100 + 0.5)))
                    or '税（0% · 未启用）',
                amount = -tax,
                kind = 'out',
                muted = taxRate <= 0,
            },
        },
        net = net,
        soldTotal = soldTotal,
        taxRate = taxRate,
        -- 「钱回到手里」＝净额 + 售出（因为售出当时已经给过现金）
        cashInHand = money(net + soldTotal),
    }
end

--- 发一张回执。同一个 settleKey 重复调用返回同一张（replayed = true）。
---@param citizenid string
---@param questId string
---@param settleKey string|nil 幂等键；不传就用 questId（一条任务一张）
---@param receipts table[]|nil 已算好的账单（不传就调用方自己算好再传）
---@return table|nil receipt
function QuestSettle.Issue(citizenid, questId, settleKey, receipt)
    if type(citizenid) ~= 'string' or type(questId) ~= 'string' then return nil end
    if type(receipt) ~= 'table' then return nil end

    local key = settleKey or questId
    Ledgers[citizenid] = Ledgers[citizenid] or {}
    local ledger = Ledgers[citizenid]
    ledger[questId] = ledger[questId] or { receipts = {} }

    -- 幂等：同一个 key 只发一次。重复的那次把上一张原样返回，并标 replayed。
    for _, existing in ipairs(ledger[questId].receipts) do
        if existing.key == key then
            local replay = {}
            for k, v in pairs(existing) do replay[k] = v end
            replay.replayed = true
            return replay
        end
    end

    local record = {}
    for k, v in pairs(receipt) do record[k] = v end
    record.key = key
    record.questId = questId
    record.issuedAt = os.time()
    record.replayed = false

    table.insert(ledger[questId].receipts, 1, record)   -- 新的在前
    while #ledger[questId].receipts > KEEP_PER_PLAYER do
        table.remove(ledger[questId].receipts)
    end

    return record
end

--- 最近一张回执（关闭后回看，A6）
function QuestSettle.Last(citizenid, questId)
    local ledger = Ledgers[citizenid]
    if not ledger or not ledger[questId] then return nil end
    return ledger[questId].receipts[1]
end

--- 测试/运维用：清内存态
function QuestSettle.Reset()
    Ledgers = {}
end

print('[quest-settle] ready')
