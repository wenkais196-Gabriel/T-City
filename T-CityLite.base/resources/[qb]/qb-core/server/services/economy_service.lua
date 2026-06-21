-- ============================================================================
-- EconomyService — 内存优先经济操作层
-- ============================================================================
-- 职责:
--   1. 所有金钱操作 100% 在内存中完成 (操作 QBCore.Players[src].PlayerData.money)
--   2. 绝不直接同步 SQL 写入 — 只标记 IsDirty=true 交由 PersistenceManager 异步刷盘
--   3. 触发原有事件链 (QBCore:Server:OnMoneyChange, QBCore:Client:OnMoneyChange 等)
--   4. 大额变动 (>100k) 触发 qb-log 审计日志
--
-- 调用方式:
--   外部: exports['qb-core']:GetCoreObject() ... 仍走 Player.Functions.AddMoney (桥接层)
--   内部: EconomyService.AddMoney(citizenid, moneytype, amount, reason)
-- ============================================================================

local EconomyService = {}

-- ── 内部辅助 ──────────────────────────────────────────────────────────

---通过 citizenid 查找在线玩家对象
---@param citizenid string
---@return table|nil Player 对象 (含 .Functions 和 .PlayerData)
local function getPlayerByCitizenId(citizenid)
    if not citizenid then return nil end
    for _, player in pairs(QBCore.Players) do
        if player.PlayerData and player.PlayerData.citizenid == citizenid then
            return player
        end
    end
    return nil
end

---触发经济变动事件链 (保持与原有 QBCore 完全一致的事件广播)
---@param player table Player 对象
---@param moneytype string
---@param amount number 变动金额
---@param operation string 'add' | 'remove' | 'set'
---@param reason string
local function fireMoneyEvents(player, moneytype, amount, operation, reason)
    local src = player.PlayerData.source
    if not src then return end

    -- 触发客户端 HUD 更新
    local isRemove = (operation == 'remove')
    TriggerClientEvent('hud:client:OnMoneyChange', src, moneytype, amount, isRemove)

    -- 触发客户端通用金钱变动
    TriggerClientEvent('QBCore:Client:OnMoneyChange', src, moneytype, amount, operation, reason)

    -- 触发服务端通用金钱变动
    TriggerEvent('QBCore:Server:OnMoneyChange', src, moneytype, amount, operation, reason)

    -- 银行扣款时额外通知手机
    if operation == 'remove' and moneytype == 'bank' then
        TriggerClientEvent('qb-phone:client:RemoveBankMoney', src, amount)
    end
end

---触发大额审计日志
---@param player table
---@param moneytype string
---@param amount number
---@param operation string
---@param newBalance number
---@param reason string
local function fireAuditLog(player, moneytype, amount, operation, newBalance, reason)
    local playerName = player.PlayerData.name or GetPlayerName(player.PlayerData.source)
    local citizenid = player.PlayerData.citizenid
    local src = player.PlayerData.source

    local color = (operation == 'add' or operation == 'set') and 'lightgreen' or 'red'
    local opLabel = operation == 'add' and 'AddMoney' or (operation == 'remove' and 'RemoveMoney' or 'SetMoney')

    local message = ('**%s** (citizenid: %s | id: %s)** $%d (%s) %s, new %s balance: %d reason: %s')
        :format(playerName, citizenid, src, amount, moneytype,
                operation == 'add' and 'added' or (operation == 'remove' and 'removed' or 'set'),
                moneytype, newBalance, reason)

    if amount > 100000 then
        TriggerEvent('qb-log:server:CreateLog', 'playermoney', opLabel, color, message, true)
    else
        TriggerEvent('qb-log:server:CreateLog', 'playermoney', opLabel, color, message)
    end
end

-- ── 公开 API ──────────────────────────────────────────────────────────

---增加金钱 (内存操作)
---@param citizenid string 玩家 citizenid
---@param moneytype string 货币类型 (cash/bank/crypto/...)
---@param amount number 金额 (必须为正数)
---@param reason string 变动原因
---@return boolean success
function EconomyService.AddMoney(citizenid, moneytype, amount, reason)
    reason = reason or 'unknown'
    moneytype = moneytype:lower()
    amount = tonumber(amount)

    -- 参数校验
    if amount == nil or amount <= 0 then return false end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local money = player.PlayerData.money
    if not money[moneytype] then return false end

    -- 内存操作
    money[moneytype] = money[moneytype] + amount
    player.IsDirty = true

    -- 更新客户端
    player.Functions.UpdatePlayerData()

    -- 事件链
    fireMoneyEvents(player, moneytype, amount, 'add', reason)
    fireAuditLog(player, moneytype, amount, 'add', money[moneytype], reason)

    return true
end

---扣除金钱 (内存操作)
---@param citizenid string 玩家 citizenid
---@param moneytype string 货币类型
---@param amount number 金额 (必须为正数)
---@param reason string 变动原因
---@return boolean success
function EconomyService.RemoveMoney(citizenid, moneytype, amount, reason)
    reason = reason or 'unknown'
    moneytype = moneytype:lower()
    amount = tonumber(amount)

    -- 参数校验
    if amount == nil or amount <= 0 then return false end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local money = player.PlayerData.money
    if not money[moneytype] then return false end

    -- Don'tAllowMinus 检查
    for _, mtype in pairs(QBCore.Config.Money.DontAllowMinus) do
        if mtype == moneytype then
            if (money[moneytype] - amount) < 0 then
                return false
            end
        end
    end

    -- MinusLimit 检查
    if money[moneytype] - amount < QBCore.Config.Money.MinusLimit then
        return false
    end

    -- 内存操作
    money[moneytype] = money[moneytype] - amount
    player.IsDirty = true

    -- 更新客户端
    player.Functions.UpdatePlayerData()

    -- 事件链
    fireMoneyEvents(player, moneytype, amount, 'remove', reason)
    fireAuditLog(player, moneytype, amount, 'remove', money[moneytype], reason)

    return true
end

---设置金钱 (内存操作) — 包含安全校验
---@param citizenid string 玩家 citizenid
---@param moneytype string 货币类型
---@param amount number 目标金额
---@param reason string 变动原因
---@return boolean success
function EconomyService.SetMoney(citizenid, moneytype, amount, reason)
    reason = reason or 'unknown'
    moneytype = moneytype:lower()
    amount = tonumber(amount)

    -- 参数校验
    if amount == nil or amount < 0 then return false end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local money = player.PlayerData.money
    if not money[moneytype] then return false end

    -- 安全校验 (SecurityService)
    if Bus and Bus.SecurityService then
        local ok, cleaned = Bus.SecurityService.ValidateMoneyEvent(
            player.PlayerData.source, amount, moneytype, reason
        )
        if not ok then return false end
        amount = cleaned
    end

    -- 内存操作
    local difference = amount - money[moneytype]
    money[moneytype] = amount
    player.IsDirty = true

    -- 更新客户端
    player.Functions.UpdatePlayerData()

    -- 事件链
    fireMoneyEvents(player, moneytype, amount, 'set', reason)
    fireAuditLog(player, moneytype, amount, 'set', money[moneytype], reason)

    return true
end

---获取金钱 (纯内存读取)
---@param citizenid string 玩家 citizenid
---@param moneytype string 货币类型
---@return number|nil
function EconomyService.GetMoney(citizenid, moneytype)
    if not citizenid or not moneytype then return nil end
    moneytype = moneytype:lower()

    local player = getPlayerByCitizenId(citizenid)
    if not player then return nil end

    return player.PlayerData.money[moneytype]
end

---转账: 从一个玩家扣款，给另一个玩家加款 (原子性尽力保证)
---@param fromCitizenId string 付款方 citizenid
---@param toCitizenId string 收款方 citizenid
---@param moneytype string 货币类型
---@param amount number 转账金额
---@param reason string 原因
---@return boolean success
function EconomyService.TransferMoney(fromCitizenId, toCitizenId, moneytype, amount, reason)
    reason = reason or 'transfer'
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false end

    -- 先扣款
    local removed = EconomyService.RemoveMoney(fromCitizenId, moneytype, amount, reason)
    if not removed then return false end

    -- 再加款
    local added = EconomyService.AddMoney(toCitizenId, moneytype, amount, reason)
    if not added then
        -- 回滚: 把扣掉的钱加回去
        EconomyService.AddMoney(fromCitizenId, moneytype, amount, 'rollback: ' .. reason)
        return false
    end

    return true
end

-- ── 自注册 ────────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if not _G.Bus then _G.Bus = {} end
        _G.Bus.EconomyService = EconomyService
        print('[EconomyService] Registered to _G.Bus.EconomyService')
    end
end)

-- 立即可用
if not _G.Bus then _G.Bus = {} end
_G.Bus.EconomyService = EconomyService
