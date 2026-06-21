-- ============================================================================
-- SinkService — 资金碎纸机 (Economic Sink System)
-- ============================================================================
-- 设计原则:
--   健康的经济生态必须保证流入系统的钱有地方被高效回收。
--   SinkService 提供统一的资金回收入口，所有系统扣款都应走这里。
--
-- Sink 类型:
--   transaction_tax     — 玩家间大额交易印花税
--   atm_fee             — ATM 存取款手续费
--   vehicle_maintenance — 车辆定期维护费
--   housing_tax         — 房产物业税
--   prison_bail         — 保释金
--   impound_fee         — 车辆扣押取回费
--   weapon_repair       — 武器维修费 (桥接)
--
-- 统计数据:
--   SinkService 维护全局 sinkStats，供自适应调节 Loop 读取
--   用于计算全服 netFlow = totalEarned - totalSunk
-- ============================================================================

local SinkService = {}

-- ── 配置 (从 QBConfig.Economy.Sinks 读取) ────────────────────────────

---获取某个 Sink 类型的配置
---@param sinkType string
---@return table|nil
local function getSinkConfig(sinkType)
    local econConfig = QBCore.Config.Economy
    if not econConfig or not econConfig.Sinks then return nil end
    return econConfig.Sinks[sinkType]
end

-- ── 统计数据结构 ─────────────────────────────────────────────────────

-- 全局回收统计: { [sinkType] = { total = N, count = M, lastReset = timestamp } }
local sinkStats = {}

---确保统计条目存在
---@param sinkType string
local function ensureStats(sinkType)
    if not sinkStats[sinkType] then
        sinkStats[sinkType] = {
            total = 0,
            count = 0,
            lastReset = os.time(),
        }
    end
end

---记录一次回收
---@param sinkType string
---@param amount number
local function recordSink(sinkType, amount)
    ensureStats(sinkType)
    sinkStats[sinkType].total = sinkStats[sinkType].total + amount
    sinkStats[sinkType].count = sinkStats[sinkType].count + 1
end

-- ── 公开 API ──────────────────────────────────────────────────────────

---统一资金回收入口
---@param source number 玩家服务器 ID (nil = 系统扣款，不触发客户端事件)
---@param amount number 回收金额
---@param sinkType string 回收类型 (transaction_tax / atm_fee / ...)
---@param reason string 原因描述
---@return boolean success
---@return number|nil actualAmount 实际扣除金额
function SinkService.Withdraw(source, amount, sinkType, reason)
    sinkType = sinkType or 'unknown'
    reason = reason or sinkType
    amount = tonumber(amount)

    -- 参数校验
    if not amount or amount <= 0 then return false end

    -- 检查配置是否启用
    local config = getSinkConfig(sinkType)
    if config and config.enabled == false then
        return true, 0 -- 关闭的 sink 静默通过
    end

    -- 如果提供了 source，从玩家账户扣款
    if source then
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then return false end

        local success = _G.Bus.EconomyService.RemoveMoney(
            Player.PlayerData.citizenid,
            'bank',
            amount,
            ('sink:%s:%s'):format(sinkType, reason)
        )

        if success then
            recordSink(sinkType, amount)

            -- 触发 sink 事件 (供日志/UI 使用)
            TriggerEvent('QBCore:Server:OnMoneySink', source, sinkType, amount, reason)

            return true, amount
        else
            return false
        end
    else
        -- 系统直接回收 (不涉及玩家账户，仅统计)
        recordSink(sinkType, amount)
        TriggerEvent('QBCore:Server:OnMoneySink', -1, sinkType, amount, reason)
        return true, amount
    end
end

---计算基于配置的回收金额 (不实际扣款，仅计算)
---@param sinkType string
---@param params table 参数 (不同 sink 类型需要不同参数)
---   transaction_tax: { amount = 交易金额 }
---   atm_fee:         { amount = 存取金额 }
---   vehicle_maintenance: { vehicleValue = 车辆价值 }
---   housing_tax:     { propertyValue = 房产价值 }
---   prison_bail:     { baseAmount = 基础保释金 }
---   impound_fee:     {}  (使用配置的 baseFee)
---@return number fee 计算出的费用
function SinkService.CalculateFee(sinkType, params)
    params = params or {}
    local config = getSinkConfig(sinkType)
    if not config then return 0 end
    if config.enabled == false then return 0 end

    if sinkType == 'transaction_tax' then
        local amount = tonumber(params.amount) or 0
        local minAmount = config.minAmount or 10000
        if amount < minAmount then return 0 end
        return math.floor(amount * (config.rate or 0.05))

    elseif sinkType == 'atm_fee' then
        local amount = tonumber(params.amount) or 0
        return math.floor(amount * (config.rate or 0.02))

    elseif sinkType == 'vehicle_maintenance' then
        local vehicleValue = tonumber(params.vehicleValue) or 0
        local baseFee = config.baseFee or 500
        local valueFee = math.floor(vehicleValue * (config.ratePerValue or 0.001))
        return baseFee + valueFee

    elseif sinkType == 'housing_tax' then
        local propertyValue = tonumber(params.propertyValue) or 0
        return math.floor(propertyValue * (config.rate or 0.005))

    elseif sinkType == 'prison_bail' then
        local baseAmount = tonumber(params.baseAmount) or 0
        return math.floor(baseAmount * (config.baseMultiplier or 1.0))

    elseif sinkType == 'impound_fee' then
        return config.baseFee or 2500

    elseif sinkType == 'weapon_repair' then
        return tonumber(params.cost) or 0 -- 桥接现有系统

    else
        return 0
    end
end

---执行交易印花税 (一步: 计算 + 扣除)
---@param source number 付款方 source
---@param transactionAmount number 交易金额
---@param reason string 交易描述
---@return boolean success
---@return number|nil taxAmount 实际税额
function SinkService.ApplyTransactionTax(source, transactionAmount, reason)
    local fee = SinkService.CalculateFee('transaction_tax', { amount = transactionAmount })
    if fee <= 0 then return true, 0 end

    return SinkService.Withdraw(source, fee, 'transaction_tax', reason or 'transaction')
end

---获取全服回收统计
---@return table { [sinkType] = { total, count }, totalSunk = N }
function SinkService.GetSinkStats()
    local result = {}
    local totalSunk = 0
    for sinkType, stats in pairs(sinkStats) do
        result[sinkType] = {
            total = stats.total,
            count = stats.count,
        }
        totalSunk = totalSunk + stats.total
    end
    result.totalSunk = totalSunk
    return result
end

---获取自上次重置以来的总回收金额 (供自适应调节 Loop 使用)
---@return number totalSunk
function SinkService.GetTotalSunk()
    local total = 0
    for _, stats in pairs(sinkStats) do
        total = total + stats.total
    end
    return total
end

---重置统计 (自适应调节 Loop 每周期调用)
function SinkService.ResetStats()
    sinkStats = {}
end

---获取统计快照并重置 (原子操作，供自适应调节 Loop 使用)
---@return number totalSunk
function SinkService.TakeSnapshot()
    local total = SinkService.GetTotalSunk()
    SinkService.ResetStats()
    return total
end

-- ── 自注册 ────────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if not _G.Bus then _G.Bus = {} end
        _G.Bus.SinkService = SinkService
        print('[SinkService] Registered to _G.Bus.SinkService')
    end
end)

if not _G.Bus then _G.Bus = {} end
_G.Bus.SinkService = SinkService
