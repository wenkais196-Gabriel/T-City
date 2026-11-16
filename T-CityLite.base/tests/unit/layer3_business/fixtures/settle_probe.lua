-- settle_probe.lua — 真跑 quest_settle.lua（不复制实现）
--
-- 覆盖 S5 计划里的账单算式与幂等：
--   1 六行齐全、金额正确
--   2 **售出不进净额**（A19）：只改 soldTotal，净额必须不变
--   3 成品回收 = 单价 × 折价 × 剩余
--   4 原料回收 = 剩料 × 单价 × 0.5
--   5 税：无税率时整行为 0 且标 muted；有税率时按「售出+回收」计税
--   6 净额 = 押金 − 租金 + 回收 − 税（用一组手算数字复核）
--   7 幂等：同 key 第二次返回同一张，replayed=true
--   8 回看：Last 返回最近一张；最多留 5 张
--   9 负数净额（租金 > 押金）不炸
--  10 空输入不炸
--  11 按班次(per-run)的幂等键：同班重复 → 同一张；跨班 → 两张不同 key
--  12 context 随回执保存，且是副本（调用方改不到账本）
--  13 Recent：新的在前、questId 过滤、limit 缺省/上限、只回 billable、副本安全

local SOURCE = arg[1]
if not SOURCE then error('用法: lua5.4 settle_probe.lua <quest_settle.lua>') end

local chunk = assert(loadfile(SOURCE))
chunk()

local results = {}
local function check(name, condition, detail)
    results[#results + 1] = { name = name, ok = condition and true or false, detail = detail }
    print(('%s %s%s'):format(condition and 'OK  ' or 'FAIL', name,
        detail and (' — ' .. tostring(detail)) or ''))
end

local function rowOf(receipt, id)
    for _, row in ipairs(receipt.rows) do
        if row.id == id then return row end
    end
    return nil
end

-- 1) 六行齐全 + UX 规格里那组示例数字：押金 250、租金 36、售出 174 → 净额 214、到手 388
local base = QuestSettle.Compute({
    depositRefund = 250, rent = 36, soldTotal = 174,
    leftover = nil, raw = 0, taxRate = 0,
})
check('SIX_ROWS', #base.rows == 6, #base.rows)
check('NET_IS_214', base.net == 214, base.net)
check('CASH_IN_HAND_IS_388', base.cashInHand == 388, base.cashInHand)
check('DEPOSIT_ROW', rowOf(base, 'deposit').amount == 250)
check('RENT_ROW_NEGATIVE', rowOf(base, 'rent').amount == -36, rowOf(base, 'rent').amount)

-- 2) 售出不进净额：把售出从 174 改成 999，净额必须一模一样
local louder = QuestSettle.Compute({ depositRefund = 250, rent = 36, soldTotal = 999, raw = 0, taxRate = 0 })
check('SOLD_NOT_IN_NET', louder.net == base.net, ('%s vs %s'):format(louder.net, base.net))
check('SOLD_ROW_MARKED_PAID', rowOf(louder, 'sold').counted == false)
check('CASH_IN_HAND_FOLLOWS_SOLD', louder.cashInHand == 214 + 999, louder.cashInHand)

-- 3) 成品回收：普通 3 份 × $6 × 0.5 = 9（稀有 1 份 × $9 × 0.5 = 4.5）
local recycled = QuestSettle.Compute({
    depositRefund = 250, rent = 36, soldTotal = 0,
    leftover = { common = 3, rare = 1, exotic = 0 },
    prices = { common = 6, rare = 9, exotic = 14 },
    recycleRatio = 0.5, raw = 0, taxRate = 0,
})
check('LEFTOVER_VALUE', rowOf(recycled, 'leftover').amount == 13.5, rowOf(recycled, 'leftover').amount)
check('NET_WITH_LEFTOVER', recycled.net == 227.5, recycled.net)

-- 4) 原料回收：10 份 × $2 × 0.5 = 10
local raw = QuestSettle.Compute({
    depositRefund = 250, rent = 36, soldTotal = 0, raw = 10, rawUnit = 2, taxRate = 0,
})
check('RAW_VALUE', rowOf(raw, 'raw').amount == 10, rowOf(raw, 'raw').amount)

-- 5) 税：无税率 → 0 且 muted；10% → 按「售出 + 回收」计税（押金不上税）
check('TAX_DISABLED_ROW', rowOf(base, 'tax').amount == 0 and rowOf(base, 'tax').muted == true)
local taxed = QuestSettle.Compute({
    depositRefund = 250, rent = 36, soldTotal = 100,
    leftover = { common = 0 }, prices = { common = 6 }, raw = 0, taxRate = 0.1,
})
-- 计税基数 = 售出 100（回收 0）→ 税 10 → 净额 250 − 36 − 10 = 204
check('TAX_AMOUNT', rowOf(taxed, 'tax').amount == -10, rowOf(taxed, 'tax').amount)
check('TAX_NOT_ON_DEPOSIT', taxed.net == 204, taxed.net)

-- 6) 手算复核：250 − 60 + 9 + 10 − 0 = 209
local manual = QuestSettle.Compute({
    depositRefund = 250, rent = 60, soldTotal = 500,
    leftover = { common = 3 }, prices = { common = 6 }, recycleRatio = 0.5,
    raw = 10, rawUnit = 2, taxRate = 0,
})
check('MANUAL_NET', manual.net == 209, manual.net)

-- 7) 幂等：同 key 第二次返回同一张，replayed = true，且总额不变
QuestSettle.Reset()
local first = QuestSettle.Issue('cid-1', 'hotdog', 'settle-1', manual)
local second = QuestSettle.Issue('cid-1', 'hotdog', 'settle-1', manual)
check('ISSUE_FIRST', first ~= nil and first.replayed == false)
check('ISSUE_REPLAY', second ~= nil and second.replayed == true)
check('ISSUE_REPLAY_SAME_NET', second.net == first.net, second.net)

-- 8) 回看 + 只留 5 张
for i = 2, 7 do
    QuestSettle.Issue('cid-1', 'hotdog', 'settle-' .. i, manual)
end
local last = QuestSettle.Last('cid-1', 'hotdog')
check('LAST_IS_NEWEST', last ~= nil and last.key == 'settle-7', last and last.key or 'nil')
local count = 0
for i = 1, 10 do
    if QuestSettle.Issue('cid-1', 'hotdog', 'settle-7', manual).replayed == true then count = count + 1 end
end
check('REPLAY_IS_STABLE', count == 10, count)

-- 9) 负数净额不炸：押金 100、租金 250（租太久了）
local negative = QuestSettle.Compute({ depositRefund = 100, rent = 250, soldTotal = 0, raw = 0, taxRate = 0 })
check('NEGATIVE_NET', negative.net == -150, negative.net)

-- 10) 空输入不炸
local empty = QuestSettle.Compute(nil)
check('EMPTY_INPUT_SAFE', empty.net == 0 and #empty.rows == 6, empty.net)

--- 造一张带 context 的「可计费」账单：Recent 只收 billable 的账。
local function billableReceipt(net, leftover)
    local receipt = QuestSettle.Compute({
        depositRefund = net, rent = 0, soldTotal = 0, raw = 0, taxRate = 0,
    })
    receipt.context = {
        quest_title = '热狗摊',
        minutes = 14,
        sold_count = 9,
        leftover = leftover or { common = 1, rare = 0, exotic = 0 },
        raw_count = 3,
        billable = true,
    }
    return receipt
end

-- 11) 幂等键按「班次」：同班重复 → 同一张；跨班 → 两张不同 key
QuestSettle.Reset()
local runKeyA = 'hotdog:complete:1700000000'
local runKeyB = 'hotdog:complete:1700003600'
local receiptA = billableReceipt(10)
local firstA = QuestSettle.Issue('cid-run', 'hotdog', runKeyA, receiptA)
local replayA = QuestSettle.Issue('cid-run', 'hotdog', runKeyA, receiptA)
check('PER_RUN_REPLAYS_SAME_RECEIPT', replayA.replayed == true and replayA.key == firstA.key)
check('PER_RUN_REPLAY_SAME_ISSUED_AT', replayA.issuedAt == firstA.issuedAt)
local firstB = QuestSettle.Issue('cid-run', 'hotdog', runKeyB, billableReceipt(20))
check('PER_RUN_DISTINCT_KEY', firstB.key ~= firstA.key and firstB.replayed == false)
check('PER_RUN_TWO_RECEIPTS', #QuestSettle.Recent('cid-run', 'hotdog', 5) == 2,
    #QuestSettle.Recent('cid-run', 'hotdog', 5))
local newestRun = QuestSettle.Last('cid-run', 'hotdog')
check('PER_RUN_LAST_IS_NEWEST', newestRun ~= nil and newestRun.key == runKeyB,
    newestRun and newestRun.key or 'nil')

-- 12) context 随回执保存，并且是副本（调用方改不到账本）
local ctxReceipt = billableReceipt(30)
local issuedCtx = QuestSettle.Issue('cid-run', 'hotdog', 'hotdog:complete:ctx', ctxReceipt)
check('CONTEXT_PASSTHROUGH',
    issuedCtx.context.quest_title == '热狗摊'
        and issuedCtx.context.minutes == 14
        and issuedCtx.context.sold_count == 9
        and issuedCtx.context.raw_count == 3
        and issuedCtx.context.leftover.common == 1,
    issuedCtx.context and issuedCtx.context.quest_title or 'nil')
ctxReceipt.context.quest_title = '被改掉'
ctxReceipt.context.leftover.common = 99
check('CONTEXT_IS_COPIED',
    issuedCtx.context.quest_title == '热狗摊' and issuedCtx.context.leftover.common == 1,
    issuedCtx.context.quest_title .. '/' .. tostring(issuedCtx.context.leftover.common))

-- 13) Recent：新的在前、questId 过滤、limit 缺省/上限、只回 billable、副本安全
QuestSettle.Reset()
QuestSettle.Issue('cid-recent', 'hotdog', 'hotdog:complete:1', billableReceipt(10))
QuestSettle.Issue('cid-recent', 'hotdog', 'hotdog:complete:2', billableReceipt(20))
QuestSettle.Issue('cid-recent', 'taxi', 'taxi:complete:1', billableReceipt(30))
QuestSettle.Issue('cid-recent', 'civic', 'civic:complete:1', QuestSettle.Compute({}))

local allRecent = QuestSettle.Recent('cid-recent', nil, nil)
check('RECENT_ALL_QUESTS', #allRecent == 3, #allRecent)     -- civic 的 0 元账不计
check('RECENT_NEWEST_FIRST',
    allRecent[1].questId == 'taxi' and allRecent[2].net == 20 and allRecent[3].net == 10,
    ('%s/%s/%s'):format(tostring(allRecent[1] and allRecent[1].questId),
        tostring(allRecent[2] and allRecent[2].net), tostring(allRecent[3] and allRecent[3].net)))

local hotdogRecent = QuestSettle.Recent('cid-recent', 'hotdog', 5)
check('RECENT_QUEST_FILTER', #hotdogRecent == 2 and hotdogRecent[1].net == 20, #hotdogRecent)
local limited = QuestSettle.Recent('cid-recent', nil, 1)
check('RECENT_LIMIT', #limited == 1 and limited[1].questId == 'taxi', #limited)
check('RECENT_ONLY_BILLABLE', #QuestSettle.Recent('cid-recent', 'civic', 5) == 0)
check('RECENT_EMPTY_QUEST_ID_IS_ALL', #QuestSettle.Recent('cid-recent', '', nil) == 3)

-- 副本安全：改返回值不能改到内部账本（含六行明细与 context）
allRecent[1].net = 9999
allRecent[1].rows[1].amount = 9999
allRecent[1].context.quest_title = '被改掉'
local taxiInternal = QuestSettle.Last('cid-recent', 'taxi')
check('RECENT_COPY_SAFE',
    taxiInternal.net == 30 and taxiInternal.rows[1].amount == 30
        and taxiInternal.context.quest_title == '热狗摊',
    ('%s/%s/%s'):format(tostring(taxiInternal.net), tostring(taxiInternal.rows[1].amount),
        tostring(taxiInternal.context.quest_title)))

-- limit 上限：8 张 billable，limit=99 也只能回 KEEP_PER_PLAYER(5) 张
for i = 1, 5 do
    QuestSettle.Issue('cid-recent', 'extra_' .. i, 'extra_' .. i .. ':complete:1',
        billableReceipt(40 + i))
end
check('RECENT_LIMIT_CAP', #QuestSettle.Recent('cid-recent', nil, 99) == 5,
    #QuestSettle.Recent('cid-recent', nil, 99))

local passed = 0
for _, r in ipairs(results) do if r.ok then passed = passed + 1 end end
print(('SUMMARY %d/%d'):format(passed, #results))
os.exit(passed == #results and 0 or 1)
