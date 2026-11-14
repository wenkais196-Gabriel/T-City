-- rental_probe.lua — 真跑 quest_rental.lua（不复制实现），只桩外部符号
--
-- 覆盖 S1 计划的 8 条不变量：
--   1 押金不足 → 不建会话、不扣钱
--   2 重复 open → already_open
--   3 正常 close → 退款 = 押金 − 租金
--   4 重复 close → 幂等，不重复退钱
--   5 超时 close → 分钟数封顶 max_minutes
--   6 断线 close → 不转账，进待退队列
--   7 启动扫描 → 只排队，不转账
--   8 登录补退 → 只发生一次

local SOURCE = arg[1]
if not SOURCE then error('用法: lua5.4 rental_probe.lua <quest_rental.lua>') end

QuestDB = { events = {}, LogEvent = function(cid, qid, ev, node, meta)
    table.insert(QuestDB.events, { cid = cid, qid = qid, ev = ev, node = node, meta = meta or {} })
end, FindUnclosedRentals = function(cb) cb({}) end }
AddEventHandler = function() end
CreateThread = function() end     -- 启动扫描在探针里不跑
Wait = function() end
exports = setmetatable({}, { __index = function() return setmetatable({}, {
    __index = function() return function() return nil end end }) end })

local chunk = assert(loadfile(SOURCE))
chunk()

local results = {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok, detail = detail or '' }
end

-- 假玩家：记录钱的进出
local function makePlayer(cid, bank)
    local p = { PlayerData = { citizenid = cid }, money = { bank = bank }, ledger = {} }
    p.Functions = {
        -- 与 qb-core 一致：点调用，没有 self（参数是 account, amount, reason）
        RemoveMoney = function(account, amount)
            if p.money[account] < amount then return false, 'not enough' end
            p.money[account] = p.money[account] - amount
            table.insert(p.ledger, { op = 'remove', amount = amount })
            return true
        end,
        AddMoney = function(account, amount)
            p.money[account] = p.money[account] + amount
            table.insert(p.ledger, { op = 'add', amount = amount })
            return true
        end,
    }
    return p
end

local T0 = 1700000000
QuestRental.Reset()

-- 1. 押金不足：不建会话、不扣钱
local poor = makePlayer('cid-poor', 100)
local ok1, err1 = QuestRental.Open(poor, 'q', 'node', { deposit = 250, now = T0 })
check('insufficient_funds_rejected', ok1 == false and not QuestRental.IsOpen('cid-poor') and #poor.ledger == 0,
    tostring(err1))

-- 2. 重复 open 被拒
local rich = makePlayer('cid-rich', 10000)
QuestRental.Open(rich, 'q', 'node', { deposit = 250, rate_per_min = 6, grace_sec = 60, max_minutes = 60, now = T0 })
local ok2, err2 = QuestRental.Open(rich, 'q', 'node', { deposit = 250, now = T0 })
check('duplicate_open_rejected', ok2 == false and err2 == 'already_open', tostring(err2))

-- 3. 正常 close：已用 10 分钟（600s），免租 60s → 计费 9 分钟 × $6 = $54，退 $196
local ok3, res3 = QuestRental.Close(rich, 'returned', T0 + 600)
check('close_refunds_deposit_minus_rent',
    ok3 and res3.minutes == 9 and res3.rent == 54 and res3.refund == 196 and rich.money.bank == 10000 - 250 + 196,
    ('min=%s rent=%s refund=%s bank=%s'):format(res3.minutes, res3.rent, res3.refund, rich.money.bank))

-- 4. 重复 close：幂等，不再退钱
local bankAfter = rich.money.bank
local ok4, res4 = QuestRental.Close(rich, 'failed', T0 + 700)
check('double_close_is_idempotent', ok4 and res4.idempotent and rich.money.bank == bankAfter,
    ('idempotent=%s bank=%s'):format(tostring(res4.idempotent), rich.money.bank))

-- 5. 超时：用 5 小时也按 max_minutes=60 封顶 → 租金 360，退款 0（押金 250 < 360）
local slow = makePlayer('cid-slow', 10000)
QuestRental.Open(slow, 'q', 'node', { deposit = 250, rate_per_min = 6, grace_sec = 0, max_minutes = 60, now = T0 })
local ok5, res5 = QuestRental.Close(slow, 'timeout', T0 + 5 * 3600)
check('timeout_is_capped_at_max_minutes',
    ok5 and res5.minutes == 60 and res5.rent == 360 and res5.refund == 0,
    ('min=%s rent=%s refund=%s'):format(res5.minutes, res5.rent, res5.refund))

-- 6. 断线：不转账，进待退队列
local dropper = makePlayer('cid-drop', 10000)
QuestRental.Open(dropper, 'q', 'node', { deposit = 300, rate_per_min = 5, grace_sec = 0, max_minutes = 60, now = T0 })
local bankBeforeDrop = dropper.money.bank
local ok6, res6 = QuestRental.CloseOnDrop('cid-drop', T0 + 120)
local pending = QuestRental.GetPendingRefund('cid-drop')
check('drop_defers_refund_without_moving_money',
    ok6 and res6.deferred and dropper.money.bank == bankBeforeDrop and pending ~= nil and pending.amount == 290,
    ('refund=%s bank=%s pending=%s'):format(res6.refund, dropper.money.bank, pending and pending.amount or 'nil'))

-- 7. 启动扫描：只排队，不转账
QuestRental.Reset()
local queued = QuestRental.QueueUnclosedSessions({
    { citizenid = 'cid-boot', quest_id = 'q', step_id = 'node',
      metadata = { deposit = 500, rate_per_min = 10, grace_sec = 0, max_minutes = 60, started_at = T0 },
      created_at = T0 },
}, T0 + 600)
local bootPending = QuestRental.GetPendingRefund('cid-boot')
check('boot_scan_queues_without_paying',
    queued == 1 and bootPending ~= nil and bootPending.amount == 400 and #QuestDB.events >= 0,
    ('queued=%s pending=%s'):format(queued, bootPending and bootPending.amount or 'nil'))

-- 8. 登录补退：只发生一次
local claimant = makePlayer('cid-boot', 0)
local paid1 = QuestRental.ClaimPendingRefund(claimant)
local paid2 = QuestRental.ClaimPendingRefund(claimant)
check('claim_pays_exactly_once',
    paid1 == 400 and paid2 == 0 and claimant.money.bank == 400,
    ('first=%s second=%s bank=%s'):format(paid1, paid2, claimant.money.bank))

-- 9. 免租期内关闭：租金 0，押金全退
QuestRental.Reset()
local quick = makePlayer('cid-quick', 1000)
QuestRental.Open(quick, 'q', 'node', { deposit = 250, rate_per_min = 6, grace_sec = 120, max_minutes = 60, now = T0 })
local ok9, res9 = QuestRental.Close(quick, 'returned', T0 + 30)
check('grace_period_means_no_rent',
    ok9 and res9.minutes == 0 and res9.rent == 0 and res9.refund == 250,
    ('min=%s rent=%s refund=%s'):format(res9.minutes, res9.rent, res9.refund))

local failures = 0
for _, r in ipairs(results) do
    if not r.ok then failures = failures + 1 end
    print(('%-38s %s  %s'):format(r.name, r.ok and 'OK' or 'FAIL', r.detail))
end
print(('SUMMARY %d/%d'):format(#results - failures, #results))
os.exit(failures == 0 and 0 or 1)
