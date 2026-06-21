local QBCore = exports['qb-core']:GetCoreObject()
local Accounts = {}
local Statements = {}

-- 🛡️ Rate Limiter: 防止金融操作被恶意高频调用
local RateLimiter = {}
local RATE_LIMIT_MS = 2000 -- 同类型操作最小间隔 2 秒

local function CheckBankRateLimit(source, action)
    local now = os.time() * 1000 + math.floor((os.clock() % 1) * 1000)
    if not RateLimiter[source] then RateLimiter[source] = {} end
    local last = RateLimiter[source][action] or 0
    if now - last < RATE_LIMIT_MS then
        return false
    end
    RateLimiter[source][action] = now
    return true
end

-- Functions

local function getPlayerAndCitizenId(playerId)
    local Player = QBCore.Functions.GetPlayer(playerId)
    if not Player then return nil, nil end
    return Player, Player.PlayerData.citizenid
end

local function GetNumberOfAccounts(citizenid)
    local numberOfAccounts = 0
    for _, account in pairs(Accounts) do
        if account.citizenid == citizenid then
            numberOfAccounts = numberOfAccounts + 1
        end
    end
    return numberOfAccounts
end

-- Exported Functions

local function CreatePlayerAccount(playerId, accountName, accountBalance, accountUsers)
    local Player, citizenid = getPlayerAndCitizenId(playerId)
    if not Player or not citizenid then return false end

    if Accounts[accountName] then
        return false
    end

    Accounts[accountName] = {
        citizenid = citizenid,
        account_name = accountName,
        account_balance = accountBalance,
        account_type = 'shared',
        users = accountUsers
    }

    local insertSuccess = MySQL.insert.await('INSERT INTO bank_accounts (citizenid, account_name, account_balance, account_type, users) VALUES (?, ?, ?, ?, ?)', { citizenid, accountName, accountBalance, 'shared', accountUsers })
    return insertSuccess
end
exports('CreatePlayerAccount', CreatePlayerAccount)

local function CreateJobAccount(accountName, accountBalance)
    Accounts[accountName] = {
        account_name = accountName,
        account_balance = accountBalance,
        account_type = 'job'
    }
    local insertSuccess = MySQL.insert.await('INSERT INTO bank_accounts (account_name, account_balance, account_type) VALUES (?, ?, ?)', { accountName, accountBalance, 'job' })
    return insertSuccess
end
exports('CreateJobAccount', CreateJobAccount)

local function CreateGangAccount(accountName, accountBalance)
    Accounts[accountName] = {
        account_name = accountName,
        account_balance = accountBalance,
        account_type = 'gang'
    }
    local insertSuccess = MySQL.insert.await('INSERT INTO bank_accounts (account_name, account_balance, account_type) VALUES (?, ?, ?)', { accountName, accountBalance, 'gang' })
    return insertSuccess
end
exports('CreateGangAccount', CreateGangAccount)

local function CreateBankStatement(playerId, account, amount, reason, statementType, accountType)
    local Player, citizenid = getPlayerAndCitizenId(playerId)
    if not Player or not citizenid then return false end

    local newStatement = {
        citizenid = citizenid,
        account_name = (accountType == 'player') and 'checking' or account,
        amount = amount,
        reason = reason,
        date = os.time() * 1000,
        statement_type = statementType
    }
    if accountType == 'player' or accountType == 'shared' then
        if accountType == 'player' then account = 'checking' end
        if not Statements[citizenid] then Statements[citizenid] = {} end
        if not Statements[citizenid][account] then Statements[citizenid][account] = {} end
        Statements[citizenid][account][#Statements[citizenid][account] + 1] = newStatement
    else
        if not Statements[account] then Statements[account] = {} end
        Statements[account][#Statements[account] + 1] = newStatement
    end

    local insertSuccess = MySQL.insert.await('INSERT INTO bank_statements (citizenid, account_name, amount, reason, statement_type) VALUES (?, ?, ?, ?, ?)', { citizenid, account, amount, reason, statementType })
    if not insertSuccess then return false end
    return true
end
exports('CreateBankStatement', CreateBankStatement)

local function AddMoney(accountName, amount, reason)
    if not reason then reason = 'External Deposit' end
    local newStatement = {
        amount = amount,
        reason = reason,
        date = os.time() * 1000,
        statement_type = 'deposit'
    }
    if Accounts[accountName] then
        local accountToUpdate = Accounts[accountName]
        accountToUpdate.account_balance = accountToUpdate.account_balance + amount
        if not Statements[accountName] then Statements[accountName] = {} end
        Statements[accountName][#Statements[accountName] + 1] = newStatement
        MySQL.insert.await('INSERT INTO bank_statements (account_name, amount, reason, statement_type) VALUES (?, ?, ?, ?)', { accountName, amount, reason, 'deposit' })
        local updateSuccess = MySQL.update.await('UPDATE bank_accounts SET account_balance = account_balance + ? WHERE account_name = ?', { amount, accountName })
        return updateSuccess
    end
    return false
end
exports('AddMoney', AddMoney)
exports('AddGangMoney', AddMoney)

local function RemoveMoney(accountName, amount, reason)
    if not reason then reason = 'External Withdrawal' end
    local newStatement = {
        amount = amount,
        reason = reason,
        date = os.time() * 1000,
        statement_type = 'withdraw'
    }
    if Accounts[accountName] then
        local accountToUpdate = Accounts[accountName]
        accountToUpdate.account_balance = accountToUpdate.account_balance - amount
        if not Statements[accountName] then Statements[accountName] = {} end
        Statements[accountName][#Statements[accountName] + 1] = newStatement
        MySQL.insert.await('INSERT INTO bank_statements (account_name, amount, reason, statement_type) VALUES (?, ?, ?, ?)', { accountName, amount, reason, 'withdraw' })
        local updateSuccess = MySQL.update.await('UPDATE bank_accounts SET account_balance = account_balance - ? WHERE account_name = ?', { amount, accountName })
        return updateSuccess
    end
    return false
end
exports('RemoveMoney', RemoveMoney)
exports('RemoveGangMoney', RemoveMoney)

local function GetAccount(accountName)
    if Accounts[accountName] then
        return Accounts[accountName]
    end
    return nil
end
exports('GetAccount', GetAccount)
exports('GetGangAccount', GetAccount)

local function GetAccountBalance(accountName)
    local account = GetAccount(accountName)
    return account and account.account_balance or 0
end
exports('GetAccountBalance', GetAccountBalance)

-- Callbacks

QBCore.Functions.CreateCallback('qb-banking:server:openBank', function(source, cb)
    local src = source
    print(("[qb-banking] Server callback 'openBank' triggered for player ID: %s"):format(src))
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then 
        print("[qb-banking] Error: Player or citizenid is nil inside openBank callback!")
        return 
    end
    -- 🔒 Security: citizenid 脱敏 — 仅输出前4后4
    local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
    print(("[qb-banking] Player Name: %s %s | CID: %s"):format(Player.PlayerData.charinfo.firstname, Player.PlayerData.charinfo.lastname, maskedCid))
    
    local job = Player.PlayerData.job
    local gang = Player.PlayerData.gang
    print(("[qb-banking] Debug OpenBank: Job Info -> Name=%s, Grade=%s, IsBoss=%s"):format(job.name, job.grade and job.grade.level or "nil", tostring(job.isboss)))
    print(("[qb-banking] Debug OpenBank: Gang Info -> Name=%s, Grade=%s, IsBoss=%s"):format(gang.name, gang.grade and gang.grade.level or "nil", tostring(gang.isboss)))
    local accounts = {}
    local statements = {}
    
    if job.name ~= 'unemployed' and not Accounts[job.name] then 
        print(("[qb-banking] Dynamically creating Job Account for: %s"):format(job.name))
        CreateJobAccount(job.name, 0) 
    end
    if gang.name ~= 'none' and not Accounts[gang.name] then 
        print(("[qb-banking] Dynamically creating Gang Account for: %s"):format(gang.name))
        CreateGangAccount(gang.name, 0) 
    end
    
    accounts[#accounts + 1] = { account_name = 'checking', account_type = 'checking', account_balance = Player.PlayerData.money.bank, users = {} }
    
    local flatStatements = {}
    local checkingStatements = Statements[citizenid] and Statements[citizenid]['checking'] or {}
    for _, stmt in ipairs(checkingStatements) do
        flatStatements[#flatStatements + 1] = {
            id = stmt.id,
            citizenid = stmt.citizenid,
            account_name = 'checking',
            amount = stmt.amount,
            reason = stmt.reason,
            statement_type = stmt.statement_type,
            date = stmt.date
        }
    end
    
    for accountName, accountInfo in pairs(Accounts) do
        local hasAccess = false
        if accountInfo.citizenid == citizenid then
            hasAccess = true
        elseif accountInfo.users and string.find(accountInfo.users, citizenid, 1, true) then
            hasAccess = true
        elseif (accountName == job.name and job.isboss) or (accountName == gang.name and gang.isboss) then
            hasAccess = true
        end
        
        if hasAccess then
            -- Append the accessible account to the accounts array returned to the NUI with decoded users array to avoid JS string-looping bug
            local accountCopy = {
                id = accountInfo.id,
                citizenid = accountInfo.citizenid,
                account_name = accountInfo.account_name,
                account_balance = accountInfo.account_balance,
                account_type = accountInfo.account_type,
                users = {}
            }
            if accountInfo.users then
                if type(accountInfo.users) == 'string' then
                    accountCopy.users = json.decode(accountInfo.users)
                else
                    accountCopy.users = accountInfo.users
                end
            end
            accounts[#accounts + 1] = accountCopy
            
            if Statements[accountName] then
                for _, stmt in ipairs(Statements[accountName]) do
                    flatStatements[#flatStatements + 1] = {
                        id = stmt.id,
                        citizenid = stmt.citizenid,
                        account_name = stmt.account_name or accountName,
                        amount = stmt.amount,
                        reason = stmt.reason,
                        statement_type = stmt.statement_type,
                        date = stmt.date
                    }
                end
            end
        end
    end
    
    print(("[qb-banking] Successfully fetched %s accounts and %s statements, sending to client."):format(#accounts, #flatStatements))
    cb(accounts, flatStatements, Player.PlayerData)
end)

QBCore.Functions.CreateCallback('qb-banking:server:openATM', function(source, cb)
    local src = source
    print(("[qb-banking] Server callback 'openATM' triggered for player ID: %s"):format(src))
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then 
        print("[qb-banking] Error: Player or citizenid is nil inside openATM callback!")
        return 
    end
    
    local bankCards = Player.Functions.GetItemsByName('bank_card')
    if not bankCards or #bankCards == 0 then 
        print("[qb-banking] ATM Access Denied: No 'bank_card' found in inventory.")
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.card'), 'error') 
        return
    end
    
    local acceptablePins = {}
    for _, bankCard in ipairs(bankCards) do 
        if bankCard.info and bankCard.info.cardPin then
            -- Cast the PIN to string to prevent Javascript strict-equality (===) type-mismatch rejection
            acceptablePins[#acceptablePins + 1] = tostring(bankCard.info.cardPin) 
        end
    end
    
    local job = Player.PlayerData.job
    local gang = Player.PlayerData.gang
    print(("[qb-banking] Debug OpenATM: Job Info -> Name=%s, Grade=%s, IsBoss=%s"):format(job.name, job.grade and job.grade.level or "nil", tostring(job.isboss)))
    print(("[qb-banking] Debug OpenATM: Gang Info -> Name=%s, Grade=%s, IsBoss=%s"):format(gang.name, gang.grade and gang.grade.level or "nil", tostring(gang.isboss)))
    local accounts = {}
    accounts[#accounts + 1] = { account_name = 'checking', account_type = 'checking', account_balance = Player.PlayerData.money.bank, users = {} }
    
    for accountName, accountInfo in pairs(Accounts) do
        local hasAccess = false
        if accountInfo.citizenid == citizenid then
            hasAccess = true
        elseif accountInfo.users and string.find(accountInfo.users, citizenid, 1, true) then
            hasAccess = true
        elseif (accountName == job.name and job.isboss) or (accountName == gang.name and gang.isboss) then
            hasAccess = true
        end
        
        if hasAccess then
            local accountCopy = {
                id = accountInfo.id,
                citizenid = accountInfo.citizenid,
                account_name = accountInfo.account_name,
                account_balance = accountInfo.account_balance,
                account_type = accountInfo.account_type,
                users = {}
            }
            if accountInfo.users then
                if type(accountInfo.users) == 'string' then
                    accountCopy.users = json.decode(accountInfo.users)
                else
                    accountCopy.users = accountInfo.users
                end
            end
            accounts[#accounts + 1] = accountCopy
        end
    end
    
    print(("[qb-banking] Successfully authorized ATM access. Found %s acceptable PINs. Fetched %s accounts."):format(#acceptablePins, #accounts))
    cb(accounts, Player.PlayerData, acceptablePins)
end)

QBCore.Functions.CreateCallback('qb-banking:server:withdraw', function(source, cb, data)
    local src = source
    -- 🛡️ Rate Limit: 防止高频提现
    if not CheckBankRateLimit(src, 'withdraw') then return cb({ success = false, message = '操作过于频繁，请稍后再试' }) end
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    local withdrawAmount = tonumber(data.amount)
    if not withdrawAmount or withdrawAmount <= 0 then return cb({ success = false, message = "请输入有效的提现正数金额！" }) end
    local reason = (data.reason ~= '' and data.reason) or 'Bank Withdrawal'
    if accountName == 'checking' then
        local accountBalance = Player.PlayerData.money.bank
        if accountBalance < withdrawAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        Player.Functions.RemoveMoney('bank', withdrawAmount, 'bank withdrawal')
        Player.Functions.AddMoney('cash', withdrawAmount, 'bank withdrawal')
        if not CreateBankStatement(src, 'checking', withdrawAmount, reason, 'withdraw', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.withdraw') })
    end
    if Accounts[accountName] then
        local job = Player.PlayerData.job
        local gang = Player.PlayerData.gang
        if Accounts[accountName].account_type == 'job' and job.name ~= accountName and not job.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        if Accounts[accountName].account_type == 'gang' and gang.name ~= accountName and not gang.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        local accountBalance = GetAccountBalance(accountName)
        if accountBalance < withdrawAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        
        -- Enrich Ledger Reason for public/shared account audit tracking
        local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
        local enrichedReason = string.format("[取款] %s (%s): %s", charName, citizenid, reason)
        
        if not RemoveMoney(accountName, withdrawAmount, enrichedReason) then return cb({ success = false, message = Lang:t('error.error') }) end
        Player.Functions.AddMoney('cash', withdrawAmount, 'bank account: ' .. accountName .. ' withdrawal')
        if not CreateBankStatement(src, accountName, withdrawAmount, enrichedReason, 'withdraw', Accounts[accountName].account_type) then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.withdraw') })
    end
end)

QBCore.Functions.CreateCallback('qb-banking:server:deposit', function(source, cb, data)
    local src = source
    -- 🛡️ Rate Limit: 防止高频存款
    if not CheckBankRateLimit(src, 'deposit') then return cb({ success = false, message = '操作过于频繁，请稍后再试' }) end
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    local depositAmount = tonumber(data.amount)
    if not depositAmount or depositAmount <= 0 then return cb({ success = false, message = "请输入有效的存款正数金额！" }) end
    local reason = (data.reason ~= '' and data.reason) or 'Bank Deposit'
    if accountName == 'checking' then
        local accountBalance = Player.PlayerData.money.cash
        if accountBalance < depositAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        Player.Functions.RemoveMoney('cash', depositAmount, 'bank deposit')
        Player.Functions.AddMoney('bank', depositAmount, 'bank deposit')
        if not CreateBankStatement(src, 'checking', depositAmount, reason, 'deposit', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.deposit') })
    end
    if Accounts[accountName] then
        local job = Player.PlayerData.job
        local gang = Player.PlayerData.gang
        if Accounts[accountName].account_type == 'job' and job.name ~= accountName and not job.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        if Accounts[accountName].account_type == 'gang' and gang.name ~= accountName and not gang.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        if Player.PlayerData.money.cash < depositAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        
        -- Enrich Ledger Reason for public/shared account audit tracking
        local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
        local enrichedReason = string.format("[存款] %s (%s): %s", charName, citizenid, reason)
        
        Player.Functions.RemoveMoney('cash', depositAmount, 'bank account: ' .. accountName .. ' deposit')
        if not AddMoney(accountName, depositAmount, enrichedReason) then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.deposit') })
    end
end)

QBCore.Functions.CreateCallback('qb-banking:server:internalTransfer', function(source, cb, data)
    local src = source
    -- 🛡️ Rate Limit: 防止高频内部转账
    if not CheckBankRateLimit(src, 'transfer') then return cb({ success = false, message = '操作过于频繁，请稍后再试' }) end
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local job = Player.PlayerData.job
    local gang = Player.PlayerData.gang
    local fromAccountName = data.fromAccountName
    local toAccountName = data.toAccountName
    local transferAmount = tonumber(data.amount)
    if not transferAmount or transferAmount <= 0 then return cb({ success = false, message = "请输入有效的转账正数金额！" }) end
    local reason = (data.reason ~= '' and data.reason) or 'Internal transfer'
    -- Enrich Ledger Reason for internal transfer tracking
    local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    local enrichedReasonFrom = string.format("[内部转出] %s (%s) 至 Checking: %s", charName, citizenid, reason)
    local enrichedReasonTo = string.format("[内部划入] 从 %s 账户划拨: %s", fromAccountName, reason)

    if fromAccountName == 'checking' then
        if Player.PlayerData.money.bank < transferAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        Player.Functions.RemoveMoney('bank', transferAmount, reason)
        if toAccountName == 'checking' then
            Player.Functions.AddMoney('bank', transferAmount, reason)
        else
            local enrichedReasonDeposit = string.format("[存入] %s (%s) 自 Checking: %s", charName, citizenid, reason)
            if not AddMoney(toAccountName, transferAmount, enrichedReasonDeposit) then return cb({ success = false, message = Lang:t('error.error') }) end
        end
        if not CreateBankStatement(src, 'checking', transferAmount, reason, 'withdraw', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.transfer') })
    elseif toAccountName == 'checking' then
        if Accounts[fromAccountName].account_type == 'job' and job.name ~= fromAccountName and not job.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        if Accounts[fromAccountName].account_type == 'gang' and gang.name ~= fromAccountName and not gang.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        local fromAccountBalance = GetAccountBalance(fromAccountName)
        if fromAccountBalance < transferAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        if not RemoveMoney(fromAccountName, transferAmount, enrichedReasonFrom) then return cb({ success = false, message = Lang:t('error.error') }) end
        Player.Functions.AddMoney('bank', transferAmount, enrichedReasonTo)
        if not CreateBankStatement(src, 'checking', transferAmount, enrichedReasonTo, 'deposit', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.transfer') })
    else
        if Accounts[fromAccountName].account_type == 'job' and job.name ~= fromAccountName and not job.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        if Accounts[fromAccountName].account_type == 'gang' and gang.name ~= fromAccountName and not gang.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        local fromAccountBalance = GetAccountBalance(fromAccountName)
        if fromAccountBalance < transferAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        
        local enrichedReasonCross = string.format("[对公划拨] %s (%s) -> %s: %s", charName, citizenid, toAccountName, reason)
        if not RemoveMoney(fromAccountName, transferAmount, enrichedReasonCross) then return cb({ success = false, message = Lang:t('error.error') }) end
        if not AddMoney(toAccountName, transferAmount, enrichedReasonCross) then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.transfer') })
    end
end)

QBCore.Functions.CreateCallback('qb-banking:server:externalTransfer', function(source, cb, data)
    local src = source
    -- 🛡️ Rate Limit: 防止高频外部汇款
    if not CheckBankRateLimit(src, 'transfer') then return cb({ success = false, message = '操作过于频繁，请稍后再试' }) end
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local job = Player.PlayerData.job
    local gang = Player.PlayerData.gang
    local toAccountName = data.toAccountNumber
    local transferAmount = tonumber(data.amount)
    if not transferAmount or transferAmount <= 0 then return cb({ success = false, message = "请输入有效的汇款正数金额！" }) end
    local toPlayer = QBCore.Functions.GetPlayerByCitizenId(toAccountName)
    if not toPlayer then return cb({ success = false, message = "汇款失败：无法找到目标公民，或该公民当前已离线！" }) end
    if toPlayer.PlayerData.citizenid == citizenid then return cb({ success = false, message = "汇款失败：您不能向自己的账户进行外部汇款！" }) end
    local fromAccountName = data.fromAccountName
    local reason = (data.reason ~= '' and data.reason) or 'External transfer'
    if fromAccountName == 'checking' then
        if Player.PlayerData.money.bank < transferAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        Player.Functions.RemoveMoney('bank', transferAmount, reason)
        toPlayer.Functions.AddMoney('bank', transferAmount, reason)
        if not CreateBankStatement(src, 'checking', transferAmount, reason, 'withdraw', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        if not CreateBankStatement(toPlayer.PlayerData.source, 'checking', transferAmount, reason, 'deposit', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.transfer') })
    else
        if Accounts[fromAccountName].account_type == 'job' and job.name ~= fromAccountName and not job.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        if Accounts[fromAccountName].account_type == 'gang' and gang.name ~= fromAccountName and not gang.isboss then return cb({ success = false, message = Lang:t('error.access') }) end
        local fromAccountBalance = GetAccountBalance(fromAccountName)
        if fromAccountBalance < transferAmount then return cb({ success = false, message = Lang:t('error.money') }) end
        
        -- Enrich Ledger Reason for public/shared account wire transfer
        local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
        local targetName = toPlayer.PlayerData.charinfo.firstname .. " " .. toPlayer.PlayerData.charinfo.lastname
        local enrichedReasonFrom = string.format("[对公汇出] %s (%s) 汇至 %s (%s): %s", charName, citizenid, targetName, toPlayer.PlayerData.citizenid, reason)
        local enrichedReasonTo = string.format("[汇入] 从 %s 账户 (%s 经办): %s", fromAccountName, charName, reason)
        
        if not RemoveMoney(fromAccountName, transferAmount, enrichedReasonFrom) then return cb({ success = false, message = Lang:t('error.error') }) end
        toPlayer.Functions.AddMoney('bank', transferAmount, enrichedReasonTo)
        if not CreateBankStatement(toPlayer.PlayerData.source, 'checking', transferAmount, enrichedReasonTo, 'deposit', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
        cb({ success = true, message = Lang:t('success.transfer') })
    end
end)

QBCore.Functions.CreateCallback('qb-banking:server:orderCard', function(source, cb, data)
    cb({ success = false, message = "本服已取消实体银行卡，请直接在柜台办理业务！" })
end)

QBCore.Functions.CreateCallback('qb-banking:server:openAccount', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    local initialAmount = tonumber(data.amount)
    if not initialAmount or initialAmount < 0 then return cb({ success = false, message = "请输入有效的开户初始存款金额！" }) end
    if Accounts[accountName] then return cb({ success = false, message = "开户失败：该账户名称已被占用！" }) end
    if GetNumberOfAccounts(citizenid) >= Config.maxAccounts then return cb({ success = false, message = Lang:t('error.accounts') }) end
    if Player.PlayerData.money.bank < initialAmount then return cb({ success = false, message = Lang:t('error.money') }) end
    Player.Functions.RemoveMoney('bank', initialAmount, 'Opened account ' .. accountName)
    if not CreatePlayerAccount(src, accountName, initialAmount, json.encode({})) then return cb({ success = false, message = Lang:t('error.error') }) end
    if not CreateBankStatement(src, accountName, initialAmount, 'Initial deposit', 'deposit', 'shared') then return cb({ success = false, message = Lang:t('error.error') }) end
    if not CreateBankStatement(src, 'checking', initialAmount, 'Initial deposit for ' .. accountName, 'withdraw', 'player') then return cb({ success = false, message = Lang:t('error.error') }) end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Opened', 'green', string.format('**%s** opened account **%s** with an initial deposit of **$%s**', GetPlayerName(src), accountName, initialAmount))
    cb({ success = true, message = Lang:t('success.account') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:renameAccount', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local oldName = data.accountName
    local newName = data.newName
    if not oldName or not newName or oldName == '' or newName == '' then return cb({ success = false, message = "账户重命名失败：参数无效！" }) end
    if oldName == newName then return cb({ success = false, message = "新账户名不能与旧账户名相同！" }) end
    if Accounts[newName] then return cb({ success = false, message = "重命名失败：该账户名称已被占用！" }) end
    if not Accounts[oldName] then return cb({ success = false, message = Lang:t('error.error') }) end
    if Accounts[oldName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    
    -- Rename memory mapping
    Accounts[newName] = Accounts[oldName]
    Accounts[newName].account_name = newName
    Accounts[oldName] = nil
    
    if Statements[oldName] then
        Statements[newName] = Statements[oldName]
        Statements[oldName] = nil
        MySQL.update.await('UPDATE bank_statements SET account_name = ? WHERE account_name = ?', { newName, oldName })
    end
    
    local result = MySQL.update.await('UPDATE bank_accounts SET account_name = ? WHERE account_name = ? AND citizenid = ?', { newName, oldName, citizenid })
    if not result then return cb({ success = false, message = Lang:t('error.error') }) end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Renamed', 'red', string.format('**%s** renamed **%s** to **%s**', GetPlayerName(src), oldName, newName))
    cb({ success = true, message = Lang:t('success.rename') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:deleteAccount', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    if not Accounts[accountName] then return cb({ success = false, message = Lang:t('error.error') }) end
    if Accounts[accountName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    
    local refundAmount = Accounts[accountName].account_balance or 0
    -- 🔒 Security: citizenid 脱敏
    local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
    print(("[qb-banking] Deleting account '%s' for citizen '%s'. Refunding $%s to checking."):format(accountName, maskedCid, refundAmount))
    
    -- Refund the money to the player's primary bank account in QBCore
    Player.Functions.AddMoney('bank', refundAmount, 'Account closure refund: ' .. accountName)
    
    -- Create ledger statement for the refund
    CreateBankStatement(src, 'checking', refundAmount, 'Refund from closure of ' .. accountName, 'deposit', 'player')
    
    -- Clean up statements in server memory and database to prevent ghost records on same-named accounts
    Statements[accountName] = nil
    MySQL.rawExecute.await('DELETE FROM bank_statements WHERE account_name = ?', { accountName })
    
    Accounts[accountName] = nil
    local result = MySQL.rawExecute.await('DELETE FROM bank_accounts WHERE account_name = ? AND citizenid = ?', { accountName, citizenid })
    if not result then return cb({ success = false, message = Lang:t('error.error') }) end
    
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Deleted', 'red', string.format('**%s** deleted account **%s** and was refunded **$%s**', GetPlayerName(src), accountName, refundAmount))
    cb({ success = true, message = Lang:t('success.delete') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:addUser', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local userToAdd = data.citizenid
    if not userToAdd or userToAdd == '' then return cb({ success = false, message = "请输入有效的 Citizen ID！" }) end
    if userToAdd == citizenid then return cb({ success = false, message = "您是该账户的所有者，无需重复添加！" }) end
    
    local accountName = data.accountName
    if not Accounts[accountName] then return cb({ success = false, message = Lang:t('error.account') }) end
    if Accounts[accountName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    
    local account = Accounts[accountName]
    local users = {}
    if account.users then
        if type(account.users) == 'string' then
            users = json.decode(account.users) or {}
        else
            users = account.users
        end
    end
    
    for _, cid in ipairs(users) do
        if cid == userToAdd then return cb({ success = false, message = "该公民已在此共享账户的授权名单中！" }) end
    end
    
    users[#users + 1] = userToAdd
    local usersData = json.encode(users)
    Accounts[accountName].users = usersData
    local result = MySQL.update.await('UPDATE bank_accounts SET users = ? WHERE account_name = ? AND citizenid = ?', { usersData, accountName, citizenid })
    if not result then return cb({ success = false, message = Lang:t('error.error') }) end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'User Added', 'green', string.format('**%s** added **%s** to **%s**', GetPlayerName(src), userToAdd, accountName))
    cb({ success = true, message = Lang:t('success.userAdd') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:removeUser', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local userToRemove = data.citizenid
    if not userToRemove or userToRemove == '' then return cb({ success = false, message = "无效的 Citizen ID！" }) end
    
    local accountName = data.accountName
    if not Accounts[accountName] then return cb({ success = false, message = Lang:t('error.account') }) end
    if Accounts[accountName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    
    local account = Accounts[accountName]
    local users = {}
    if account.users then
        if type(account.users) == 'string' then
            users = json.decode(account.users) or {}
        else
            users = account.users
        end
    end
    
    local userFound = false
    for i = #users, 1, -1 do
        if users[i] == userToRemove then
            table.remove(users, i)
            userFound = true
            break
        end
    end
    if not userFound then return cb({ success = false, message = Lang:t('error.noUser') }) end
    
    local usersData = json.encode(users)
    Accounts[accountName].users = usersData
    local result = MySQL.update.await('UPDATE bank_accounts SET users = ? WHERE account_name = ? AND citizenid = ?', { usersData, accountName, citizenid })
    if not result then return cb({ success = false, message = Lang:t('error.error') }) end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'User Removed', 'red', string.format('**%s** removed **%s** from **%s**', GetPlayerName(src), userToRemove, accountName))
    cb({ success = true, message = Lang:t('success.userRemove') })
end)

-- Items

QBCore.Functions.CreateUseableItem('bank_card', function(source, item)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    if Player.Functions.GetItemByName(item.name) then
        TriggerClientEvent('qb-banking:client:useCard', source)
    end
end)

-- Threads

CreateThread(function()
    local accounts = MySQL.query.await('SELECT * FROM bank_accounts')

    for _, account in ipairs(accounts) do
        Accounts[account.account_name] = account
    end

    for job in pairs(QBCore.Shared.Jobs) do
        if Accounts[job] == nil then
            CreateJobAccount(job, 0)
        end
    end
end)

CreateThread(function()
    local statements = MySQL.query.await('SELECT * FROM bank_statements')
    for _, statement in ipairs(statements) do
        if statement.account_name == 'checking' then
            if not Statements[statement.citizenid] then Statements[statement.citizenid] = {} end
            if not Statements[statement.citizenid][statement.account_name] then Statements[statement.citizenid][statement.account_name] = {} end
            Statements[statement.citizenid][statement.account_name][#Statements[statement.citizenid][statement.account_name] + 1] = statement
        else
            if not Statements[statement.account_name] then Statements[statement.account_name] = {} end
            Statements[statement.account_name][#Statements[statement.account_name] + 1] = statement
        end
    end
end)

-- Commands

QBCore.Commands.Add('givecash', 'Give Cash', { { name = 'id', help = 'Player ID' }, { name = 'amount', help = 'Amount' } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local target = QBCore.Functions.GetPlayer(tonumber(args[1]))
    if not target then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.noUser'), 'error') end
    local targetPed = GetPlayerPed(tonumber(args[1]))
    local targetCoords = GetEntityCoords(targetPed)
    local amount = tonumber(args[2])
    if not amount then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.amount'), 'error') end
    if amount <= 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.amount'), 'error') end
    if #(playerCoords - targetCoords) > 5 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.toofar'), 'error') end
    if Player.PlayerData.money.cash < amount then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.money'), 'error') end
    Player.Functions.RemoveMoney('cash', amount, 'cash transfer')
    target.Functions.AddMoney('cash', amount, 'cash transfer')
    TriggerClientEvent('QBCore:Notify', src, string.format(Lang:t('success.give'), amount), 'success')
    TriggerClientEvent('QBCore:Notify', target.PlayerData.source, string.format(Lang:t('success.receive'), amount), 'success')
end)
