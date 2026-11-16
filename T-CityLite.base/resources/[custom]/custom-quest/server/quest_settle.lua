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

-- 发单序号：issuedAt 只有秒级精度，同一秒内跨任务合并排序时用它定先后。
local IssuedSeq = 0

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

local function copyTable(source)
    local out = {}
    for key, value in pairs(source) do out[key] = value end
    return out
end

--- 回执副本：Recent / 导出的调用方改不坏内部账本。
--- 六行明细与 context 都复制一层（context.leftover 也复制），否则前端一改就改到账本上。
local function copyReceipt(receipt)
    local out = copyTable(receipt)
    if type(receipt.rows) == 'table' then
        out.rows = {}
        for index, row in ipairs(receipt.rows) do
            out.rows[index] = copyTable(row)
        end
    end
    if type(receipt.context) == 'table' then
        out.context = copyTable(receipt.context)
        if type(receipt.context.leftover) == 'table' then
            out.context.leftover = copyTable(receipt.context.leftover)
        end
    end
    out._seq = nil   -- 内部排序用，不进 DTO
    return out
end

--- 发一张回执。同一个 settleKey 重复调用返回同一张（replayed = true）。
---@param citizenid string
---@param questId string
---@param settleKey string|nil 幂等键；不传就用 questId（一条任务一张）
---@param receipt table|nil 已算好的账单（调用方先 Compute，再补 context）
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
            local replay = copyReceipt(existing)
            replay.replayed = true
            return replay
        end
    end

    local record = {}
    for k, v in pairs(receipt) do record[k] = v end
    if type(receipt.rows) == 'table' then
        record.rows = {}
        for index, row in ipairs(receipt.rows) do
            record.rows[index] = copyTable(row)
        end
    end
    if type(receipt.context) == 'table' then
        record.context = copyTable(receipt.context)
        if type(receipt.context.leftover) == 'table' then
            record.context.leftover = copyTable(receipt.context.leftover)
        end
    end
    record.key = key
    record.questId = questId
    record.issuedAt = os.time()
    IssuedSeq = IssuedSeq + 1
    record._seq = IssuedSeq
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

--- 历史账单：新的在前；只回 billable 的账；返回调用方改不坏的副本。
---@param citizenid string
---@param questId string|nil  nil / 空串 = 该角色全部任务
---@param limit number|nil    缺省 KEEP_PER_PLAYER；上限也是 KEEP_PER_PLAYER
---@return table[]
function QuestSettle.Recent(citizenid, questId, limit)
    if type(citizenid) ~= 'string' or citizenid == '' then return {} end
    local ledger = Ledgers[citizenid]
    if not ledger then return {} end

    local wanted = tonumber(limit) or KEEP_PER_PLAYER
    if wanted < 1 then wanted = KEEP_PER_PLAYER end
    if wanted > KEEP_PER_PLAYER then wanted = KEEP_PER_PLAYER end

    -- 只有「真的开了摊 / 真的结算了租借」的完成才有历史价值
    -- （纯剧情任务的 0 元回执仍进聊天框，但不占「已结算」列表）。
    local picked = {}
    local function collect(receipts)
        for _, receipt in ipairs(receipts or {}) do
            if type(receipt.context) == 'table' and receipt.context.billable == true then
                picked[#picked + 1] = receipt
            end
        end
    end

    if type(questId) == 'string' and questId ~= '' then
        local entry = ledger[questId]
        collect(entry and entry.receipts)
    else
        for _, entry in pairs(ledger) do collect(entry.receipts) end
    end

    -- issuedAt 只有秒级精度：同一秒内按发单顺序（_seq）排，新的在前。
    table.sort(picked, function(a, b)
        if a.issuedAt ~= b.issuedAt then return a.issuedAt > b.issuedAt end
        return (a._seq or 0) > (b._seq or 0)
    end)

    local rows = {}
    for index = 1, math.min(wanted, #picked) do
        rows[index] = copyReceipt(picked[index])
    end
    return rows
end

--- 测试/运维用：清内存态
function QuestSettle.Reset()
    Ledgers = {}
    IssuedSeq = 0
end

print('[quest-settle] ready')
