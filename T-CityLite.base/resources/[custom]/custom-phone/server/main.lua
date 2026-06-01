local QBCore = exports['qb-core']:GetCoreObject()

-- Create phone_numbers table if it does not exist
MySQL.ready(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_numbers (
            id INT AUTO_INCREMENT PRIMARY KEY,
            citizenid VARCHAR(50) NOT NULL,
            number VARCHAR(20) NOT NULL UNIQUE,
            is_primary INT DEFAULT 0,
            INDEX (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end)

-- Helper to find online player by phone number
local function GetPlayerByPhone(phoneNum)
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(playerId)
        if Player and Player.PlayerData.charinfo.phone == phoneNum then
            return Player
        end
    end
    return nil
end

-- 1. Main callback to load all phone data
QBCore.Functions.CreateCallback('phone:server:getPhoneData', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(nil) end

    local citizenid = Player.PlayerData.citizenid
    local phoneNum = Player.PlayerData.charinfo.phone
    local name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname

    local identity = exports['custom-career']:GetPlayerIdentity(source) or {
        primary_role = 'civilian',
        rank_tier = 'entry',
        department = '',
        certs = {}
    }

    local data = {
        success = true,
        playerData = {
            citizenid = citizenid,
            name = name,
            phone = phoneNum,
            money = Player.PlayerData.money,
            career = identity
        },
        contacts = {},
        messages = {},
        notifications = {}, -- Memory transient notifications
        jobBoard = {},
        factionMessages = {}
    }

    -- Fetch Contacts
    MySQL.Async.fetchAll('SELECT * FROM phone_contacts WHERE citizenid = ?', { citizenid }, function(contacts)
        data.contacts = contacts or {}

        -- Add phone numbers list to playerData
        MySQL.Async.fetchAll('SELECT number, is_primary FROM phone_numbers WHERE citizenid = ?', { citizenid }, function(numbersList)
            local finalNumbers = {}
            local hasPrimary = false
            for _, val in ipairs(numbersList) do
                table.insert(finalNumbers, val.number)
                if val.is_primary == 1 then
                    hasPrimary = true
                    data.playerData.phone = val.number
                end
            end
            
            -- Fallback if no phone numbers in db yet
            if #finalNumbers == 0 or not hasPrimary then
                table.insert(finalNumbers, phoneNum)
                data.playerData.phone = phoneNum
                MySQL.Async.execute('INSERT IGNORE INTO phone_numbers (citizenid, number, is_primary) VALUES (?, ?, 1)', {
                    citizenid, phoneNum
                })
            end
            data.playerData.phoneNumbers = finalNumbers

            -- Fetch Messages (Optimized to latest 100 entries to prevent memory overload)
            MySQL.Async.fetchAll('SELECT * FROM phone_messages WHERE sender_number = ? OR receiver_number = ? ORDER BY timestamp DESC LIMIT 100', { phoneNum, phoneNum }, function(messages)
                data.messages = messages or {}

                -- Fetch active Job Board tasks
                MySQL.Async.fetchAll('SELECT * FROM phone_jobboard ORDER BY posted_at DESC LIMIT 20', {}, function(jobs)
                    -- Parse target_tags JSON
                    for i = 1, #jobs do
                        if type(jobs[i].target_tags) == 'string' then
                            jobs[i].target_tags = json.decode(jobs[i].target_tags)
                        end
                    end
                    data.jobBoard = jobs or {}

                    -- Fetch Faction/Group message queue (transient from global state)
                    local faction = identity.primary_role
                    if GlobalState.FactionMessages and GlobalState.FactionMessages[faction] then
                        data.factionMessages = GlobalState.FactionMessages[faction]
                    else
                        data.factionMessages = {}
                    end

                    cb(data)
                end)
            end)
        end)
    end)
end)

-- ----------------------------------------------------
-- Contact CRUD Callbacks
-- ----------------------------------------------------
QBCore.Functions.CreateCallback('phone:server:addContact', function(source, cb, name, number)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not name or #name == 0 or #name > 30 then
        return cb({ success = false, message = 'Name must be between 1 and 30 characters' })
    end
    if not number or #number == 0 or #number > 15 then
        return cb({ success = false, message = 'Number must be between 1 and 15 digits' })
    end

    local citizenid = Player.PlayerData.citizenid

    MySQL.Async.insert('INSERT INTO phone_contacts (citizenid, name, number) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name)', {
        citizenid, name, number
    }, function(insertId)
        if insertId then
            cb({ success = true, contact = { id = insertId, citizenid = citizenid, name = name, number = number } })
        else
            cb({ success = false, message = 'Database error' })
        end
    end)
end)

QBCore.Functions.CreateCallback('phone:server:deleteContact', function(source, cb, id)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false }) end

    MySQL.Async.execute('DELETE FROM phone_contacts WHERE id = ? AND citizenid = ?', { id, Player.PlayerData.citizenid }, function(affected)
        cb({ success = affected > 0 })
    end)
end)

-- ----------------------------------------------------
-- SMS Callbacks
-- ----------------------------------------------------
QBCore.Functions.CreateCallback('phone:server:sendMessage', function(source, cb, receiver_number, message)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not receiver_number or #receiver_number == 0 or #receiver_number > 15 then
        return cb({ success = false, message = 'Invalid recipient number' })
    end
    if not message or #message == 0 or #message > 500 then
        return cb({ success = false, message = 'Message must be between 1 and 500 characters' })
    end

    local sender_number = Player.PlayerData.charinfo.phone

    MySQL.Async.insert('INSERT INTO phone_messages (sender_number, receiver_number, message) VALUES (?, ?, ?)', {
        sender_number, receiver_number, message
    }, function(insertId)
        if insertId then
            local msgData = {
                id = insertId,
                sender_number = sender_number,
                receiver_number = receiver_number,
                message = message,
                timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                is_read = false
            }

            -- Route real-time event to recipient if online
            local targetPlayer = GetPlayerByPhone(receiver_number)
            if targetPlayer then
                TriggerClientEvent('phone:client:newMessage', targetPlayer.PlayerData.source, msgData)
                -- Push notification popup too!
                TriggerClientEvent('phone:client:newNotification', targetPlayer.PlayerData.source, {
                    id = math.random(1000, 9999),
                    title = "💬 New Message",
                    content = "From " .. (Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname) .. ": " .. message,
                    timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                    is_read = false
                })
            end

            cb({ success = true, message = msgData })
        else
            cb({ success = false, message = 'Database error' })
        end
    end)
end)

RegisterNetEvent('phone:server:markMessagesRead', function(sender_number)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    
    local my_number = Player.PlayerData.charinfo.phone
    MySQL.Async.execute('UPDATE phone_messages SET is_read = 1 WHERE sender_number = ? AND receiver_number = ?', {
        sender_number, my_number
    })
end)

-- ----------------------------------------------------
-- CityFeed Callbacks & SQL
-- ----------------------------------------------------
QBCore.Functions.CreateCallback('phone:server:getCityFeed', function(source, cb)
    MySQL.Async.fetchAll('SELECT f.*, p.charinfo FROM phone_cityfeed f LEFT JOIN players p ON f.citizenid = p.citizenid ORDER BY f.timestamp DESC LIMIT 30', {}, function(posts)
        local formatted = {}
        for i = 1, #posts do
            local name = "Anonymous"
            if posts[i].charinfo then
                local char = json.decode(posts[i].charinfo)
                name = char.firstname .. " " .. char.lastname
            end
            table.insert(formatted, {
                id = posts[i].id,
                name = name,
                citizenid = posts[i].citizenid,
                content = posts[i].content,
                likes = posts[i].likes,
                timestamp = posts[i].timestamp
            })
        end
        cb({ success = true, feed = formatted })
    end)
end)

QBCore.Functions.CreateCallback('phone:server:postCityFeed', function(source, cb, content)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not content or #content == 0 or #content > 200 then
        return cb({ success = false, message = 'Content must be between 1 and 200 characters' })
    end

    local citizenid = Player.PlayerData.citizenid
    local name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname

    MySQL.Async.insert('INSERT INTO phone_cityfeed (citizenid, content) VALUES (?, ?)', {
        citizenid, content
    }, function(insertId)
        if insertId then
            cb({
                success = true,
                post = {
                    id = insertId,
                    name = name,
                    citizenid = citizenid,
                    content = content,
                    likes = 0,
                    timestamp = os.date('%Y-%m-%d %H:%M:%S')
                }
            })
        else
            cb({ success = false })
        end
    end)
end)

QBCore.Functions.CreateCallback('phone:server:likeCityFeed', function(source, cb, id)
    MySQL.Async.execute('UPDATE phone_cityfeed SET likes = likes + 1 WHERE id = ?', { id }, function(affected)
        if affected > 0 then
            MySQL.Async.fetchScalar('SELECT likes FROM phone_cityfeed WHERE id = ?', { id }, function(likes)
                cb({ success = true, likes = likes or 0 })
            end)
        else
            cb({ success = false })
        end
    end)
end)

-- ----------------------------------------------------
-- v0.4.2 Advanced Premium NUI Callback Registrations
-- ----------------------------------------------------

-- 1. Mobile Nearby Citizens Scanner (Pay / Share card scanner)
QBCore.Functions.CreateCallback('phone:server:getNearbyPlayers', function(source, cb)
    local src = source
    local ped = GetPlayerPed(src)
    if not ped or ped <= 0 then return cb({}) end

    local playerCoords = GetEntityCoords(ped)
    local nearbyList = {}

    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        if playerId ~= src then
            local targetPed = GetPlayerPed(playerId)
            if targetPed and targetPed > 0 then
                local targetCoords = GetEntityCoords(targetPed)
                local dist = #(playerCoords - targetCoords)
                if dist <= 8.0 then
                    local Target = QBCore.Functions.GetPlayer(playerId)
                    if Target then
                        table.insert(nearbyList, {
                            id = playerId,
                            name = Target.PlayerData.charinfo.firstname .. " " .. Target.PlayerData.charinfo.lastname,
                            phone = Target.PlayerData.charinfo.phone
                        })
                    end
                end
            end
        end
    end
    cb(nearbyList)
end)

-- 2. AirDrop Contact sharing to nearby player
QBCore.Functions.CreateCallback('phone:server:shareContactNearby', function(source, cb, targetPlayerId, contactName, contactNumber)
    local Player = QBCore.Functions.GetPlayer(source)
    local Target = QBCore.Functions.GetPlayer(targetPlayerId)
    if not Player or not Target then return cb({ success = false, message = 'Citizen not found' }) end

    -- Verify distance is still < 8m (Security boundary validation)
    local pPed = GetPlayerPed(source)
    local tPed = GetPlayerPed(targetPlayerId)
    if pPed and tPed then
        local dist = #(GetEntityCoords(pPed) - GetEntityCoords(tPed))
        if dist > 8.0 then
            return cb({ success = false, message = 'Target citizen has walked too far away' })
        end
    end

    local targetCid = Target.PlayerData.citizenid

    -- Insert contact directly into target player database
    MySQL.Async.insert('INSERT INTO phone_contacts (citizenid, name, number) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name)', {
        targetCid, contactName, contactNumber
    }, function(insertId)
        if insertId then
            -- Trigger UI push reload and visual notification for recipient
            TriggerClientEvent('phone:client:newNotification', targetPlayerId, {
                id = math.random(1000, 9999),
                title = "📥 Contact Received",
                content = ("%s shared their card: %s. Added to contacts!"):format(contactName, contactNumber),
                timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                is_read = false
            })
            cb({ success = true, message = 'Contact shared successfully!' })
        else
            cb({ success = false, message = 'Database error' })
        end
    end)
end)

-- 3. Fetch owned vehicles for Garage App
QBCore.Functions.CreateCallback('phone:server:getOwnedVehicles', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({}) end

    MySQL.Async.fetchAll('SELECT vehicle, plate, garage, state, fuel, engine, body FROM player_vehicles WHERE citizenid = ?', {
        Player.PlayerData.citizenid
    }, function(vehicles)
        local list = {}
        for i = 1, #vehicles do
            local status = "Stored"
            if vehicles[i].state == 0 then
                status = "Out of Garage"
            elseif vehicles[i].state == 2 then
                status = "Impounded"
            end

            -- Match friendly model name
            local model = vehicles[i].vehicle:upper()
            table.insert(list, {
                model = model,
                plate = vehicles[i].plate,
                garage = vehicles[i].garage or "Main Impound",
                status = status,
                fuel = tonumber(vehicles[i].fuel) or 100,
                engine = math.floor((tonumber(vehicles[i].engine) or 1000) / 10),
                body = math.floor((tonumber(vehicles[i].body) or 1000) / 10)
            })
        end
        cb(list)
    end)
end)

-- 4. Yellow Pages & Service Hotline callbacks
QBCore.Functions.CreateCallback('phone:server:getHotlineStatus', function(source, cb, jobType)
    local count = 0
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(playerId)
        if Player and Player.PlayerData.job.name == jobType and Player.PlayerData.job.onduty then
            count = count + 1
        end
    end
    cb(count)
end)

-- 5. Trigger active transfer ringing on relevant on-duty workers
QBCore.Functions.CreateCallback('phone:server:triggerHotlineCall', function(source, cb, jobType)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false }) end

    local callerName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    local callerPhone = Player.PlayerData.charinfo.phone

    local activeWorkers = {}
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local Target = QBCore.Functions.GetPlayer(playerId)
        if Target and Target.PlayerData.job.name == jobType and Target.PlayerData.job.onduty then
            table.insert(activeWorkers, playerId)
            
            -- Push call alerting notification
            TriggerClientEvent('phone:client:newNotification', playerId, {
                id = math.random(1000, 9999),
                title = "📞 Inbound Hot Call",
                content = ("Emergency call from %s (%s)"):format(callerName, callerPhone),
                timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                is_read = false
            })
        end
    end

    if #activeWorkers > 0 then
        cb({ success = true, active = true, message = 'Connecting to available agents...' })
    else
        cb({ success = true, active = false, message = 'All lines busy. Re-routing to automated system.' })
    end
end)

-- 6. Automated IVR dynamic query
QBCore.Functions.CreateCallback('phone:server:queryAutomatedIvr', function(source, cb, actionType)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(nil) end

    if actionType == 'economy' then
        local wage = GetConvar and GetConvar('economy_wage_multiplier', '1.0') or '1.0'
        cb({
            title = "📊 Market Index",
            info = ("Economy Wage Multiplier: %s | Maze Bank Savings Rate: 1.25%% APR"):format(wage)
        })
    elseif actionType == 'licenses' then
        local licenses = Player.PlayerData.metadata['licences'] or {}
        local list = {}
        for k, v in pairs(licenses) do
            if v then table.insert(list, k:upper()) end
        end
        cb({
            title = "🪪 Gov Certificates",
            info = #list > 0 and ("Active Licenses: " .. table.concat(list, ", ")) or "No certified licenses found."
        })
    else
        cb(nil)
    end
end)
