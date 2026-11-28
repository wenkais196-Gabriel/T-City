-- server/commands.lua — S1 组织金库的四条命令（全部服务端）。
--
-- 授权模型：
--   /orgfund          该组织 Grade4 / 管理员 / 控制台
--   /orgfunddeposit   该组织 Grade4（必须在线）
--   /orgfundwithdraw  该组织 Grade4（必须在线）
--   /orgfundgrant     仅控制台（source == 0），系统注入
--
-- 玩家层金额只走 Player.Functions.RemoveMoney / AddMoney；组织层只走 Treasury.*。
-- 每一笔资金动作（包括被拒绝的）都写 industry_audit，payload 只有金额 / 结果码 / ref。

IndustryCommands = {}

-- 测试注入点：生产恒为 os.time()。周额度判断只通过这里取「现在」，
-- 用例可以把时钟拨到同一周/下一周，不需要真等 7 天。
IndustryCommands.Now = os.time

-- 本资源没有全局 QBCore：qb-core 是另一个资源，FiveM 不跨资源共享 Lua 全局；
-- main.lua 里就算写 local 也看不见。按 [custom]/AGENTS.md 的已知坑，惰性解析
-- 一次并缓存。Register() 开头把它取成局部变量，命令闭包会一起捕获。
local QBCore
local function core()
    if not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    return QBCore
end

local MAX_AMOUNT = 1000000000000000
local MAX_REASON_LEN = 64
local refSeq = 0

local function reply(src, message)
    if src and src > 0 then
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 200, 50 },
            args = { '产业', message },
        })
    else
        print('[custom-industry] ' .. message)
    end
end

local function validCommandAmount(amount)
    return type(amount) == 'number'
        and amount == amount -- NaN
        and amount > 0
        and amount <= MAX_AMOUNT
        and amount == math.floor(amount)
end

--- 金额只渲染成字符串再拼文案：`$` 与 `%d` 同串在金额为小数时会抛 format 错。
--- 实现只允许 core-framework 的 FormatMoney（Money 别名由 money_aliases.lua 集中定义）。
local function moneyText(value)
    return Money(value)
end

local function makeRef(kind, orgId, cid)
    refSeq = refSeq + 1
    return ('cmd:%s:%s:%s:%d:%d'):format(
        kind, orgId, tostring(cid or 'console'), os.time(), refSeq)
end

local function audit(orgId, actorCid, action, amount, result, ref)
    IndustryAudit.Write(orgId, actorCid, action, IndustryAudit.Payload(amount, result, ref))
end

-- ── 提现额度 / 税（P2 #410）────────────────────────────────────────
-- 额度与税率只从 Config.Industry 读；缺配置时 fail closed（不猜默认值，避免
-- 「配置漏加载 → 静默无税提现」）。
-- 税 = 销毁：Treasury.Withdraw 扣全额，Player.Functions.AddMoney 只进净值。
-- 同一组织的在途提现按 orgId 串行化：额度是从流水派生的，两个请求在 await
-- 之间交错会都读到旧额度（与 sale.lua 的 `busy` 同一理由）。
local withdrawBusy = {}

---@return number|nil quota, number|nil rate, string|nil errcode
local function withdrawalConfig()
    local quota = tonumber(Config.Industry.WeeklyWithdrawQuota)
    if not quota or quota ~= quota or quota < 0 then return nil, nil, 'config_error' end
    local rate = tonumber(Config.Industry.WithdrawTaxRate)
    if not rate or rate ~= rate or rate < 0 or rate > 1 then return nil, nil, 'config_error' end
    return quota, rate, nil
end

--- 税向下取整到整美元；净值 = 全额 - 税。
---@return number tax, number net
local function taxFor(amount, rate)
    local tax = math.floor(amount * rate + 1e-9)
    if tax < 0 then tax = 0 end
    if tax > amount then tax = amount end
    return tax, amount - tax
end

--- treasury.withdraw 的审计 payload：金额 / 净值 / 销毁税 / 结果 / ref。
--- 只有数字与白名单字符，不含 citizenid 以外的身份信息（actor_cid 单独成列）。
local function treasuryWithdrawPayload(amount, net, taxBurned, result, ref)
    local safeResult = tostring(result or 'unknown'):gsub('[^%w_%-%.]', '_')
    local safeRef = tostring(ref or ''):gsub('[^%w:_%-%.]', '_')
    return ('{"amount":%d,"net":%d,"tax_burned":%d,"result":"%s","ref":"%s"}'):format(
        math.floor(tonumber(amount) or 0),
        math.floor(tonumber(net) or 0),
        math.floor(tonumber(taxBurned) or 0),
        safeResult, safeRef)
end

local function auditTreasuryWithdraw(orgId, cid, amount, net, taxBurned, result, ref)
    IndustryAudit.Write(orgId, cid, 'treasury.withdraw',
        treasuryWithdrawPayload(amount, net, taxBurned, result, ref))
end

function IndustryCommands.Register()
    local QBCore = core()
    QBCore.Commands.Add('orgfund', '查看组织金库余额与最近流水', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
        { name = 'limit', help = '流水条数，默认 20' },
    }, false, function(source, args)
        local src = source
        local orgId = tostring(args[1] or '')
        if orgId == '' then
            reply(src, '用法: /orgfund <orgId> [limit]')
            return
        end

        local allowed = false
        if src > 0 then
            local Player = QBCore.Functions.GetPlayer(src)
            if not Player then
                reply(src, '玩家状态不可用，请稍后重试')
                return
            end
            local admin = QBCore.Functions.HasPermission(src, 'admin')
                or QBCore.Functions.HasPermission(src, 'god')
            allowed = admin or IndustryAccess.IsOrgBoss(Player, orgId)
        else
            allowed = true
        end

        if not allowed then
            reply(src, 'not_boss')
            return
        end

        local balance, err = Treasury.GetBalance(orgId)
        if balance == nil then
            reply(src, ('查询失败: %s'):format(tostring(err)))
            return
        end

        local limit = tonumber(args[2]) or Config.Industry.LedgerDefaultLimit
        local rows, ledgerErr = Treasury.GetLedger(orgId, limit)
        if rows == nil then
            reply(src, ('流水查询失败: %s'):format(tostring(ledgerErr)))
            return
        end

        reply(src, ('%s 余额 $%s，最近 %d 条流水'):format(orgId, moneyText(balance), #rows))
        for _, row in ipairs(rows) do
            local sign = row.delta >= 0 and '+' or ''
            reply(src, ('#%s %s%d → $%s %s ref=%s'):format(
                tostring(row.id), sign, row.delta, moneyText(row.balance_after),
                tostring(row.reason), tostring(row.ref)))
        end
    end, 'user')

    QBCore.Commands.Add('orgfunddeposit', '从个人银行存入组织金库', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
        { name = 'amount', help = '正整数美元' },
    }, false, function(source, args)
        local src = source
        if src < 1 then
            reply(src, '该命令只能由在线玩家执行')
            return
        end

        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then
            reply(src, '玩家状态不可用，请稍后重试')
            return
        end
        local cid = Player.PlayerData.citizenid

        local orgId = tostring(args[1] or '')
        local amount = tonumber(args[2])
        if not validCommandAmount(amount) then
            audit(orgId, cid, 'fund.deposit', amount or 0, 'bad_amount', nil)
            reply(src, '金额必须是正整数')
            return
        end
        if not IndustryAccess.IsOrgBoss(Player, orgId) then
            audit(orgId, cid, 'fund.deposit', amount, 'not_boss', nil)
            reply(src, 'not_boss')
            return
        end

        local ref = makeRef('dep', orgId, cid)
        if not Player.Functions.RemoveMoney('bank', amount, 'orgfunddeposit') then
            audit(orgId, cid, 'fund.deposit', amount, 'insufficient_funds', ref)
            reply(src, 'insufficient_funds')
            return
        end

        local ok, err = Treasury.Deposit(orgId, amount, 'deposit', { actor = cid, ref = ref })
        if not ok then
            Player.Functions.AddMoney('bank', amount, 'orgfunddeposit-refund')
            audit(orgId, cid, 'fund.deposit', amount, err or 'db_error', ref)
            reply(src, ('入账失败: %s，个人银行已退回'):format(tostring(err)))
            return
        end

        audit(orgId, cid, 'fund.deposit', amount, 'ok', ref)
        reply(src, ('已存入 $%s 到 %s'):format(moneyText(amount), orgId))
    end, 'user')

    -- 提现处理单独成函数：命令清单扫描器的 balanced_call 上限是 4000 字，
    -- 内联闭包会把末尾的权限参数 'user' 截掉，文档会被误写成「无判权」。
    local function withdrawHandler(source, args)
        local src = source
        if src < 1 then
            reply(src, '该命令只能由在线玩家执行')
            return
        end

        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then
            reply(src, '玩家状态不可用，请稍后重试')
            return
        end
        local cid = Player.PlayerData.citizenid

        local orgId = tostring(args[1] or '')
        local amount = tonumber(args[2])
        if not validCommandAmount(amount) then
            auditTreasuryWithdraw(orgId, cid, amount or 0, 0, 0, 'bad_amount', nil)
            reply(src, '金额必须是正整数')
            return
        end
        if not IndustryAccess.IsOrgBoss(Player, orgId) then
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0, 'not_boss', nil)
            reply(src, 'not_boss')
            return
        end

        local quota, taxRate, configErr = withdrawalConfig()
        if not quota then
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0, configErr or 'config_error', nil)
            reply(src, '提现配置不可用，请联系管理员')
            return
        end

        -- 同一组织的在途提现串行化：额度从流水派生，读与写之间不能有第二个请求。
        if withdrawBusy[orgId] then
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0, 'withdraw_busy', nil)
            reply(src, 'withdraw_busy：上一笔提现还在处理中')
            return
        end
        withdrawBusy[orgId] = true

        local clock = IndustryCommands.Now
        local now = type(clock) == 'function' and clock() or os.time()
        local already, quotaErr = Treasury.GetWithdrawnThisWeek(orgId, now)
        if not already then
            withdrawBusy[orgId] = nil
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0, quotaErr or 'db_error', nil)
            reply(src, ('取款失败: %s'):format(tostring(quotaErr or 'db_error')))
            return
        end

        -- 超额直接拒绝，不截断：静默截断会让玩家以为提了全额。
        if already + amount > quota then
            withdrawBusy[orgId] = nil
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0, 'weekly_quota_exceeded', nil)
            reply(src, ('weekly_quota_exceeded：本周已提 $%s / 周额度 $%s'):format(
                moneyText(already), moneyText(quota)))
            return
        end

        local tax, net = taxFor(amount, taxRate)
        local ref = makeRef('wd', orgId, cid)
        local ok, err = Treasury.Withdraw(orgId, amount, 'withdraw', { actor = cid, ref = ref })
        if not ok then
            withdrawBusy[orgId] = nil
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0, err or 'db_error', ref)
            reply(src, ('取款失败: %s'):format(tostring(err)))
            return
        end

        -- 税 = 销毁：只把净值记进个人银行；AddMoney 失败时退回**全额**（税不烧）。
        local paid = true
        if net > 0 then
            local called, credited = pcall(function()
                return Player.Functions.AddMoney('bank', net, 'orgfundwithdraw')
            end)
            paid = called and credited == true
        end
        if not paid then
            local refunded, refundErr = Treasury.Deposit(orgId, amount, 'withdraw-rollback', {
                actor = cid,
                ref = ref .. ':rb',
            })
            withdrawBusy[orgId] = nil
            auditTreasuryWithdraw(orgId, cid, amount, 0, 0,
                refunded and 'payout_failed_refunded' or 'payout_failed', ref)
            if not refunded then
                print(('[custom-industry] CRITICAL payout+rollback failed org=%s ref=%s err=%s'):format(
                    orgId, ref, tostring(refundErr)))
            end
            reply(src, '发放失败，组织金库已回滚')
            return
        end

        withdrawBusy[orgId] = nil
        auditTreasuryWithdraw(orgId, cid, amount, net, tax, 'ok', ref)
        reply(src, ('已从 %s 取出 $%s（税前 $%s，税 $%s 已销毁）'):format(
            orgId, moneyText(net), moneyText(amount), moneyText(tax)))
    end

    QBCore.Commands.Add('orgfundwithdraw', '从组织金库取款到个人银行（周额度 + 20% 税）', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
        { name = 'amount', help = '正整数美元' },
    }, false, withdrawHandler, 'user')

    QBCore.Commands.Add('orgfundgrant', '系统向组织金库注入资金（仅控制台）', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
        { name = 'amount', help = '正整数美元' },
        { name = 'reason', help = '必填，写入流水的可读原因' },
    }, false, function(source, args)
        local src = source
        local orgId = tostring(args[1] or '')
        local amount = tonumber(args[2])
        local reason = tostring(args[3] or '')

        if src > 0 then
            -- 玩家调用控制台命令：不索引 PlayerData，统一返回 not_boss。
            audit(orgId, nil, 'fund.grant', amount or 0, 'not_console', nil)
            reply(src, 'not_boss')
            return
        end

        if not validCommandAmount(amount) then
            audit(orgId, nil, 'fund.grant', amount or 0, 'bad_amount', nil)
            print('[custom-industry] 用法: orgfundgrant <orgId> <amount> <reason>')
            return
        end
        if reason == '' or #reason > MAX_REASON_LEN then
            audit(orgId, nil, 'fund.grant', amount, 'bad_reason', nil)
            print('[custom-industry] reason 必填且不超过 64 字节')
            return
        end

        -- 只有控制台注入会开户：玩家侧存/取保持 no_account，避免打错 orgId 凭空建账户。
        local opened, openErr, created = Treasury.EnsureAccount(orgId)
        if not opened then
            audit(orgId, nil, 'fund.grant', amount, openErr or 'db_error', nil)
            print(('[custom-industry] grant open failed org=%s err=%s'):format(
                orgId, tostring(openErr or 'db_error')))
            return
        end
        if created then
            audit(orgId, nil, 'fund.open', 0, 'ok', nil)
        end

        local ref = makeRef('grant', orgId, 'console')
        local ok, err = Treasury.Deposit(orgId, amount, reason, { ref = ref })
        audit(orgId, nil, 'fund.grant', amount, ok and 'ok' or (err or 'db_error'), ref)
        print(('[custom-industry] grant org=%s amount=%d ok=%s err=%s ref=%s'):format(
            orgId, amount, tostring(ok), tostring(err or 'nil'), ref))
    end, 'user')
end
