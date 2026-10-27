local QBCore = exports['qb-core']:GetCoreObject()

-- Phone banking only allows Wire Transfer (转账). Deposit and withdrawal must be done physically.

-- 3. Wire Transfer from my checking account to another player's phone number (Online & Offline Capable)
QBCore.Functions.CreateCallback('phone:server:bankTransfer', function(source, cb, toPhoneNumber, amount, reason)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    amount = tonumber(amount) or 0
    if amount <= 0 then return cb({ success = false, message = 'Invalid transfer amount' }) end
    if amount > 100000 then return cb({ success = false, message = 'Single transfer exceeds bank limit of $100,000' }) end

    local currentBank = Player.PlayerData.money.bank
    if currentBank < amount then
        return cb({ success = false, message = 'Insufficient checking balance' })
    end

    if toPhoneNumber == Player.PlayerData.charinfo.phone then
        return cb({ success = false, message = 'Cannot transfer money to yourself' })
    end

    -- 1. Try to find the target player online first
    local targetPlayer = nil
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local Target = QBCore.Functions.GetPlayer(playerId)
        if Target and Target.PlayerData.charinfo.phone == toPhoneNumber then
            targetPlayer = Target
            break
        end
    end

    if targetPlayer then
        -- Recipient is ONLINE: atomic transfer via EconomyService (deduct+credit+rollback)
        local es = _G.Bus and _G.Bus.EconomyService
        if es and es.TransferMoney then
            local ok = es.TransferMoney(
                Player.PlayerData.citizenid, targetPlayer.PlayerData.citizenid,
                'bank', amount, "Transfer to " .. toPhoneNumber
            )
            if not ok then
                return cb({ success = false, message = 'Transfer failed' })
            end
        else
            -- Fallback: manual deduct+add
            if not Player.Functions.RemoveMoney('bank', amount, "Transfer to " .. toPhoneNumber) then
                return cb({ success = false, message = 'Deduction failed' })
            end
            targetPlayer.Functions.AddMoney('bank', amount, "Transfer from " .. Player.PlayerData.charinfo.phone)
        end

        -- Persisted server-originated notification (pushed once to recipient).
        PhoneNotify(targetPlayer.PlayerData.source, {
            title = "🏦 Wire Inbound",
            content = ("Received $%d from %s %s. Memo: %s"):format(
                amount, Player.PlayerData.charinfo.firstname, Player.PlayerData.charinfo.lastname, reason or "None"
            ),
        })

        -- Audit Logs
        local auditText = ("**[在线] 汇款人**: %s (%s)\n**收款人**: %s (%s)\n**金额**: $%d\n**说明**: %s"):format(
            GetPlayerName(source), Player.PlayerData.citizenid,
            GetPlayerName(targetPlayer.PlayerData.source), targetPlayer.PlayerData.citizenid,
            amount, reason or "None"
        )
        exports['custom-main']:LogEconomy("手机银行转账", auditText, 65535)

        cb({ success = true, newBalances = Player.PlayerData.money, message = ('Successfully transferred $%d to %s!'):format(amount, targetPlayer.PlayerData.charinfo.firstname) })
    else
        -- Recipient is OFFLINE: Query database to find citizen and credit their account directly
        -- [PERF] Use JSON_EXTRACT for indexed query instead of full-text LIKE
        -- TODO: Step 3 will replace this with phone_number virtual column + exact match
        MySQL.Async.fetchAll([[
            SELECT citizenid, money, charinfo FROM players 
            WHERE JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.phone')) = ?
            LIMIT 1
        ]], { toPhoneNumber }, function(results)
            local foundCitizen = nil
            local dbMoney = nil
            local dbChar = nil

            if results then
                for i = 1, #results do
                    local char = json.decode(results[i].charinfo)
                    if char and char.phone == toPhoneNumber then
                        foundCitizen = results[i].citizenid
                        dbMoney = json.decode(results[i].money)
                        dbChar = char
                        break
                    end
                end
            end

            if not foundCitizen or not dbMoney or not dbChar then
                return cb({ success = false, message = 'Active citizen with this number not found' })
            end

            -- Debit the online sender via EconomyService bridge (ensures audit trail + events)
            if Player.Functions.RemoveMoney('bank', amount, "Transfer to " .. toPhoneNumber) then
                -- 离线收款人不在内存里，只能改 DB —— 但这条 SQL 只允许 owner 写。
                exports['qb-core']:EconomyAddMoneyOffline(foundCitizen, 'bank', amount,
                    'phone-transfer-offline-to-' .. foundCitizen, function(ok)
                    if ok then
                        local auditText = ("**[离线] 汇款人**: %s (%s)\n**离线收款人**: %s %s (%s)\n**金额**: $%d\n**说明**: %s"):format(
                            GetPlayerName(source), Player.PlayerData.citizenid,
                            dbChar.firstname, dbChar.lastname, foundCitizen,
                            amount, reason or "None"
                        )
                        exports['custom-main']:LogEconomy("手机银行转账", auditText, 65535)
                        cb({ success = true, newBalances = Player.PlayerData.money,
                            message = ('Successfully wired $%d to %s (Offline)!'):format(amount, dbChar.firstname) })
                    else
                        -- 没入账 → 把发送方刚扣掉的钱退回去，绝不能吞掉
                        Player.Functions.AddMoney('bank', amount, "Transfer Rollback (offline credit failed)")
                        cb({ success = false, message = 'Offline credit failed. Rollback triggered.' })
                    end
                end)
            else
                cb({ success = false, message = 'Deduction failed' })
            end
        end)
    end
end)
