-- ============================================================================
-- TransactionMonitor — 大额转账监控与自动扣税 (v1.0.0)
-- ============================================================================
-- 三类监控:
--   1. 大额交易税: 单笔 ≥ $100k 的 add 操作自动扣 5%
--   2. 跨组织转账税: 组织间转账 ≥ $50k 扣 3% (标记"不明资金")
--   3. 全服日交易统计: 供经济看板使用
--
-- 所有扣税走 SinkService.ApplyTransactionTax
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ── 配置 ──────────────────────────────────────────────────────────────

local LARGE_TRANSACTION_THRESHOLD = 100000   -- $100k
local LARGE_TRANSACTION_TAX_RATE = 0.05      -- 5%
local ORG_TRANSFER_THRESHOLD = 50000         -- $50k
local ORG_TRANSFER_TAX_RATE = 0.03           -- 3%

-- ── 统计 ──────────────────────────────────────────────────────────────

local dailyStats = {
    totalTaxCollected = 0,
    largeTransactionCount = 0,
    orgTransferCount = 0,
    lastReset = os.time(),
}

-- ── 公开 API ──────────────────────────────────────────────────────────

---获取每日统计
function GetDailyStats()
    -- 自动跨日重置
    if os.date('%Y%m%d', dailyStats.lastReset) ~= os.date('%Y%m%d') then
        dailyStats.totalTaxCollected = 0
        dailyStats.largeTransactionCount = 0
        dailyStats.orgTransferCount = 0
        dailyStats.lastReset = os.time()
    end
    return dailyStats
end

-- ── 监听: 全服金钱变动 ────────────────────────────────────────────────

AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    if action ~= 'add' then return end -- 只监控流入 (支出已在 SinkService 中处理)
    if moneytype ~= 'bank' then return end -- 只监控银行转账

    amount = tonumber(amount) or 0
    if amount < LARGE_TRANSACTION_THRESHOLD then return end

    -- 大额交易税
    local taxAmount = math.floor(amount * LARGE_TRANSACTION_TAX_RATE)
    if taxAmount <= 0 then return end

    -- 通过 SinkService 扣税
    if _G.Bus and _G.Bus.SinkService then
        _G.Bus.SinkService.Withdraw(src, taxAmount, 'transaction_tax',
            ('large_transfer: $%d → taxed $%d (%s)'):format(amount, taxAmount, reason or 'unknown'))
    else
        -- fallback: 直接从玩家账户扣
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            Player.Functions.RemoveMoney('bank', taxAmount,
                ('large_transfer_tax:%s'):format(reason or 'unknown'))
        end
    end

    dailyStats.totalTaxCollected = dailyStats.totalTaxCollected + taxAmount
    dailyStats.largeTransactionCount = dailyStats.largeTransactionCount + 1

    -- 通知玩家
    if src > 0 then
        TriggerClientEvent('QBCore:Notify', src,
            ('Large transfer tax: $%d (5%% of $%d)'):format(taxAmount, amount), 'primary')
    end

    -- 记录日志
    if exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('大额转账扣税',
            ('**Source**: %d | **金额**: $%d | **税收**: $%d | **原因**: %s'):format(
                src, amount, taxAmount, reason or 'unknown'), 16776960)
    end
end)

-- ── 监听: 组织间转账 (qb-banking externalTransfer) ────────────────────

-- qb-banking 的 externalTransfer 事件格式:
-- QBCore:Server:OnMoneyChange → reason 包含 'external-transfer' 时标记
-- 跨组织转账的 reason 通常是 "transfer-{name}-{fromAccount}-{toAccount}"
-- 我们通过 reason 模式匹配来识别
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    if action ~= 'add' then return end
    if moneytype ~= 'bank' then return end

    amount = tonumber(amount) or 0
    if amount < ORG_TRANSFER_THRESHOLD then return end

    -- 检测是否为跨组织转账
    -- 特征: reason 中包含 'transfer' 且 金额较大
    if reason and reason:lower():match('transfer') and not reason:lower():match('paycheck|salary|tax|sink') then
        -- 可能是组织间转账
        local taxAmount = math.floor(amount * ORG_TRANSFER_TAX_RATE)

        if _G.Bus and _G.Bus.SinkService then
            -- 收款方扣税 (src 是收款方)
            _G.Bus.SinkService.Withdraw(src, taxAmount, 'transaction_tax',
                ('org_transfer: $%d → taxed $%d'):format(amount, taxAmount))
        end

        dailyStats.totalTaxCollected = dailyStats.totalTaxCollected + taxAmount
        dailyStats.orgTransferCount = dailyStats.orgTransferCount + 1

        if exports['custom-logs'] then
            exports['custom-logs']:LogEconomy('跨组织转账扣税',
                ('**收款方**: %d | **金额**: $%d | **税款**: $%d (3%%)'):format(
                    src, amount, taxAmount), 16744448)
        end
    end
end)

-- ── 管理员命令: 查看统计 ────────────────────────────────────────────

RegisterCommand('taxstats', function(source)
    local stats = GetDailyStats()
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 200, 50 },
        multiline = true,
        args = { 'Tax', ('📊 今日税收统计\n大额交易: %d 笔\n跨组织转账: %d 笔\n总税收: $%d'):format(
            stats.largeTransactionCount, stats.orgTransferCount, stats.totalTaxCollected) }
    })
end, true)

print('[TransactionMonitor] ✅ 大额转账监控已启动')
print(('[TransactionMonitor]   大额阈值: $%dk (5%%) | 跨组织阈值: $%dk (3%%)'):format(
    LARGE_TRANSACTION_THRESHOLD / 1000, ORG_TRANSFER_THRESHOLD / 1000))
