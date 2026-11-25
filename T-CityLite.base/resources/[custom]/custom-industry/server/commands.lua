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

--- 玩家是否属于 orgId 且达到 Grade4。org 的 job/gang 映射来自 Config.Industry.OrgWhitelist。
local function isOrgBoss(Player, orgId)
    local def = Config.Industry.OrgWhitelist[orgId]
    if not def then return false end

    local data = Player.PlayerData
    local level = 0
    if def.kind == 'job' then
        local job = data.job
        if not job or job.name ~= def.name then return false end
        level = tonumber(job.grade and job.grade.level) or 0
    elseif def.kind == 'gang' then
        local gang = data.gang
        if not gang or gang.name ~= def.name then return false end
        level = tonumber(gang.grade and gang.grade.level) or 0
    else
        return false
    end

    return level >= (Config.Industry.BossGrade or 4)
end

local function audit(orgId, actorCid, action, amount, result, ref)
    IndustryAudit.Write(orgId, actorCid, action, IndustryAudit.Payload(amount, result, ref))
end

function IndustryCommands.Register()
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
            allowed = admin or isOrgBoss(Player, orgId)
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
        if not isOrgBoss(Player, orgId) then
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

    QBCore.Commands.Add('orgfundwithdraw', '从组织金库取款到个人银行', {
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
            audit(orgId, cid, 'fund.withdraw', amount or 0, 'bad_amount', nil)
            reply(src, '金额必须是正整数')
            return
        end
        if not isOrgBoss(Player, orgId) then
            audit(orgId, cid, 'fund.withdraw', amount, 'not_boss', nil)
            reply(src, 'not_boss')
            return
        end

        local ref = makeRef('wd', orgId, cid)
        local ok, err = Treasury.Withdraw(orgId, amount, 'withdraw', { actor = cid, ref = ref })
        if not ok then
            audit(orgId, cid, 'fund.withdraw', amount, err or 'db_error', ref)
            reply(src, ('取款失败: %s'):format(tostring(err)))
            return
        end

        if not Player.Functions.AddMoney('bank', amount, 'orgfundwithdraw') then
            local refunded, refundErr = Treasury.Deposit(orgId, amount, 'withdraw-rollback', {
                actor = cid,
                ref = ref .. ':rb',
            })
            audit(orgId, cid, 'fund.withdraw', amount,
                refunded and 'payout_failed_refunded' or 'payout_failed', ref)
            if not refunded then
                print(('[custom-industry] CRITICAL payout+rollback failed org=%s ref=%s err=%s'):format(
                    orgId, ref, tostring(refundErr)))
            end
            reply(src, '发放失败，组织金库已回滚')
            return
        end

        audit(orgId, cid, 'fund.withdraw', amount, 'ok', ref)
        reply(src, ('已从 %s 取出 $%s'):format(orgId, moneyText(amount)))
    end, 'user')

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

        local ref = makeRef('grant', orgId, 'console')
        local ok, err = Treasury.Deposit(orgId, amount, reason, { ref = ref })
        audit(orgId, nil, 'fund.grant', amount, ok and 'ok' or (err or 'db_error'), ref)
        print(('[custom-industry] grant org=%s amount=%d ok=%s err=%s ref=%s'):format(
            orgId, amount, tostring(ok), tostring(err or 'nil'), ref))
    end, 'user')
end
