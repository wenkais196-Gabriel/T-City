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

    -- phone_messages: SMS between players
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_messages (
            id INT AUTO_INCREMENT PRIMARY KEY,
            sender_number VARCHAR(20) NOT NULL,
            receiver_number VARCHAR(20) NOT NULL,
            message TEXT NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            is_read BOOLEAN DEFAULT FALSE,
            gps TEXT DEFAULT NULL,
            msg_status VARCHAR(20) DEFAULT NULL,
            INDEX idx_receiver (receiver_number),
            INDEX idx_sender (sender_number),
            INDEX idx_time (timestamp)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- v0.6 migration: add GPS columns to existing phone_messages table
    MySQL.query([[ALTER TABLE phone_messages ADD COLUMN IF NOT EXISTS gps TEXT DEFAULT NULL]])
    MySQL.query([[ALTER TABLE phone_messages ADD COLUMN IF NOT EXISTS msg_status VARCHAR(20) DEFAULT NULL]])

    -- phone_contacts: player address book
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_contacts (
            id INT AUTO_INCREMENT PRIMARY KEY,
            citizenid VARCHAR(50) NOT NULL,
            name VARCHAR(100) NOT NULL,
            number VARCHAR(20) NOT NULL,
            UNIQUE KEY uq_contact (citizenid, number),
            INDEX idx_citizenid (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- phone_cityfeed: global bulletin board
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_cityfeed (
            id INT AUTO_INCREMENT PRIMARY KEY,
            citizenid VARCHAR(50) NOT NULL,
            content TEXT NOT NULL,
            likes INT DEFAULT 0,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_time (timestamp)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- phone_jobboard: city job posting board
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_jobboard (
            id INT AUTO_INCREMENT PRIMARY KEY,
            task_id INT DEFAULT NULL,
            title VARCHAR(100) DEFAULT NULL,
            description TEXT DEFAULT NULL,
            target_tags JSON DEFAULT NULL,
            reward INT DEFAULT 0,
            status VARCHAR(20) DEFAULT 'open',
            taken_by VARCHAR(50) DEFAULT NULL,
            posted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            deadline DATETIME DEFAULT NULL,
            INDEX idx_status (status),
            INDEX idx_posted (posted_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- v0.4.2: phone_calls call log table
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_calls (
            id INT AUTO_INCREMENT PRIMARY KEY,
            caller VARCHAR(20) NOT NULL,
            receiver VARCHAR(20) NOT NULL,
            duration INT DEFAULT 0,
            status VARCHAR(20) DEFAULT 'missed',
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_caller (caller),
            INDEX idx_receiver (receiver),
            INDEX idx_time (timestamp)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- phone_notifications: persistent user notification tray
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS phone_notifications (
            id INT AUTO_INCREMENT PRIMARY KEY,
            citizenid VARCHAR(50) NOT NULL,
            title VARCHAR(200) NOT NULL,
            content TEXT NOT NULL,
            is_read BOOLEAN DEFAULT FALSE,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_citizenid (citizenid),
            INDEX idx_time (timestamp)
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

-- ⚡ TTL Cache: avoid re-querying phone data on rapid open/close (30s TTL)
local phoneDataCache = {} -- { [citizenid] = { data, expires } }

-- 1. Main callback to load all phone data
QBCore.Functions.CreateCallback('phone:server:getPhoneData', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(nil) end

    local citizenid = Player.PlayerData.citizenid

    -- ⚡ Cache hit: return cached data if still valid (30s TTL)
    local cached = phoneDataCache[citizenid]
    if cached and cached.expires > os.time() then
        -- Update volatile fields (money, career, faction messages) from live state
        cached.data.playerData.money = Player.PlayerData.money
        cached.data.factionMessages = (GlobalState.FactionMessages and GlobalState.FactionMessages[cached.data.playerData.career.primary_role]) or {}
        return cb(cached.data)
    end

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
        notifications = {},
        jobBoard = {},
        factionMessages = {}
    }

    -- ⚡ Parallel: fire 5 independent queries simultaneously (async counter pattern)
    local pending = 0
    local contacts, numberRows, messages, jobs, notifs

    local function tryAssemble()
        if pending > 0 then return end

        -- Process phone numbers
        local finalNumbers = {}
        local hasPrimary = false
        for _, val in ipairs(numberRows) do
            table.insert(finalNumbers, val.number)
            if val.is_primary == 1 then hasPrimary = true; data.playerData.phone = val.number end
        end
        if #finalNumbers == 0 or not hasPrimary then
            table.insert(finalNumbers, phoneNum)
            data.playerData.phone = phoneNum
            pcall(MySQL.prepare, 'INSERT IGNORE INTO phone_numbers (citizenid, number, is_primary) VALUES (?, ?, 1)', { citizenid, phoneNum })
        end
        data.playerData.phoneNumbers = finalNumbers

        data.contacts = contacts
        data.messages = messages
        data.jobBoard = jobs
        data.notifications = notifs

        local faction = identity.primary_role
        data.factionMessages = (GlobalState.FactionMessages and GlobalState.FactionMessages[faction]) or {}

        -- ⚡ Store in cache (30s TTL for personal data)
        phoneDataCache[citizenid] = { data = data, expires = os.time() + 30 }
        cb(data)
    end

    -- 1. Contacts
    pending = pending + 1
    MySQL.Async.fetchAll('SELECT * FROM phone_contacts WHERE citizenid = ?', { citizenid }, function(result)
        contacts = result or {}
        pending = pending - 1
        tryAssemble()
    end)

    -- 2. Phone numbers
    pending = pending + 1
    MySQL.Async.fetchAll('SELECT number, is_primary FROM phone_numbers WHERE citizenid = ?', { citizenid }, function(result)
        numberRows = result or {}
        pending = pending - 1
        tryAssemble()
    end)

    -- 3. Messages (with GPS decode post-processing)
    pending = pending + 1
    MySQL.Async.fetchAll(
        'SELECT * FROM phone_messages WHERE sender_number = ? OR receiver_number = ? ORDER BY timestamp DESC LIMIT 100',
        { phoneNum, phoneNum },
        function(result)
            messages = result or {}
            for _, msg in ipairs(messages) do
                if msg.gps and msg.gps ~= '' and msg.gps ~= 'null' then
                    local ok, decoded = pcall(json.decode, msg.gps)
                    if ok and decoded then msg.gps = decoded end
                else msg.gps = nil end
                if msg.msg_status then msg.status = msg.msg_status; msg.msg_status = nil end
            end
            pending = pending - 1
            tryAssemble()
        end
    )

    -- 4. Job board (cache-aware: skip query if cache warm)
    if phoneJobBoardCache and #phoneJobBoardCache > 0 then
        jobs = phoneJobBoardCache
    else
        pending = pending + 1
        MySQL.Async.fetchAll('SELECT * FROM phone_jobboard ORDER BY posted_at DESC LIMIT 20', {}, function(result)
            jobs = result or {}
            for i = 1, #jobs do
                if jobs[i] and type(jobs[i].target_tags) == 'string' then jobs[i].target_tags = json.decode(jobs[i].target_tags) end
            end
            phoneJobBoardCache = jobs
            pending = pending - 1
            tryAssemble()
        end)
    end

    -- 5. Notifications (persistent, newest first, limit 50)
    pending = pending + 1
    MySQL.Async.fetchAll('SELECT * FROM phone_notifications WHERE citizenid = ? ORDER BY timestamp DESC LIMIT 50', { citizenid }, function(result)
        notifs = result or {}
        pending = pending - 1
        tryAssemble()
    end)
end)

-- ⚡ Job board background refresh (every 2 minutes)
local phoneJobBoardCache = nil
CreateThread(function()
    while true do
        Wait(2 * 60 * 1000)
        local jobs = MySQL.query.await('SELECT * FROM phone_jobboard ORDER BY posted_at DESC LIMIT 20', {}) or {}
        for i = 1, #jobs do
            if jobs[i] and type(jobs[i].target_tags) == 'string' then jobs[i].target_tags = json.decode(jobs[i].target_tags) end
        end
        phoneJobBoardCache = jobs
    end
end)

-- ----------------------------------------------------
-- Contact CRUD Callbacks
-- ----------------------------------------------------
QBCore.Functions.CreateCallback('phone:server:addContact', function(source, cb, name, number)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

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
        phoneDataCache[citizenid] = nil -- ⚡ Invalidate cache
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
        phoneDataCache[Player.PlayerData.citizenid] = nil -- ⚡ Invalidate cache
        cb({ success = affected.affectedRows > 0 })
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
-- Server-side system messages (trusted resources only)
-- ----------------------------------------------------
-- custom-director calls this after a human approval. No net event or callback
-- is registered for this path, so a client can never inject a system sender.
-- sender_number stores the sender label, not a number: phone_messages has no
-- foreign key, so a label such as 'City Services' is allowed and is rendered
-- as-is by the client. Labels beyond 20 chars do not fit the VARCHAR(20)
-- sender_number column; the default label does.
-- Validation and label handling live in server/sms.lua (loaded before this
-- file) so the rules can be unit tested without a FiveM runtime.
--- Server-side system message. Not exposed to clients.
---@param receiverNumber string
---@param message string
---@param senderLabel string|nil  默认 'City Services'
---@return boolean ok, string|nil errCode
exports('SendSystemMessage', function(receiverNumber, message, senderLabel)
    local valid, validationError = Sms.Validate(receiverNumber, message)
    if not valid then return false, validationError end

    local sender = Sms.SenderLabel(senderLabel)

    local insertOk, insertId = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO phone_messages (sender_number, receiver_number, message) VALUES (?, ?, ?)',
            { sender, receiverNumber, message })
    end)
    -- oxmysql returns the insert id; some wrappers return { insertId = ... }.
    if insertOk and type(insertId) == 'table' then insertId = insertId.insertId or 0 end
    if not insertOk or not tonumber(insertId) or tonumber(insertId) == 0 then
        return false, 'db_error'
    end
    insertId = tonumber(insertId)

    -- Online receiver: push the same two client events the player-to-player
    -- callback sends. Offline receivers still get the persisted row.
    local targetPlayer = GetPlayerByPhone(receiverNumber)
    if targetPlayer then
        local timestamp = os.date('%Y-%m-%d %H:%M:%S')
        TriggerClientEvent('phone:client:newMessage', targetPlayer.PlayerData.source, {
            id = insertId,
            sender_number = sender,
            receiver_number = receiverNumber,
            message = message,
            timestamp = timestamp,
            is_read = false,
        })
        TriggerClientEvent('phone:client:newNotification', targetPlayer.PlayerData.source, {
            id = math.random(1000, 9999),
            title = sender,
            content = Sms.TruncateChars(message, 200),
            timestamp = timestamp,
            is_read = false,
        })
    end

    return true, nil
end)

-- ----------------------------------------------------
-- Notification Persistence (DB-backed)
-- ----------------------------------------------------

-- Helper: store notification in DB + push to client
local function StoreAndPushNotification(targetSrc, notification)
    local Player = QBCore.Functions.GetPlayer(targetSrc)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    MySQL.Async.insert('INSERT INTO phone_notifications (citizenid, title, content) VALUES (?, ?, ?)', {
        citizenid, notification.title, notification.content
    }, function(insertId)
        if insertId then
            notification.id = insertId
            notification.is_read = false
            notification.timestamp = os.date('%Y-%m-%d %H:%M:%S')
            TriggerClientEvent('phone:client:newNotification', targetSrc, notification)
        end
    end)
end

RegisterNetEvent('phone:server:storeNotification', function(notification)
    StoreAndPushNotification(source, notification)
end)

QBCore.Functions.CreateCallback('phone:server:markNotificationsRead', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false }) end
    MySQL.Async.execute('UPDATE phone_notifications SET is_read = 1 WHERE citizenid = ?', {
        Player.PlayerData.citizenid
    }, function(_)
        phoneDataCache[Player.PlayerData.citizenid] = nil
        cb({ success = true })
    end)
end)

QBCore.Functions.CreateCallback('phone:server:clearNotifications', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false }) end
    MySQL.Async.execute('DELETE FROM phone_notifications WHERE citizenid = ?', {
        Player.PlayerData.citizenid
    }, function(_)
        phoneDataCache[Player.PlayerData.citizenid] = nil
        cb({ success = true })
    end)
end)

QBCore.Functions.CreateCallback('phone:server:deleteNotification', function(source, cb, id)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false }) end
    MySQL.Async.execute('DELETE FROM phone_notifications WHERE id = ? AND citizenid = ?', {
        id, Player.PlayerData.citizenid
    }, function(affected)
        if affected.affectedRows > 0 then
            phoneDataCache[Player.PlayerData.citizenid] = nil
            cb({ success = true })
        else
            cb({ success = false })
        end
    end)
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
        if affected.affectedRows > 0 then
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

    -- Input validation (Security Hardening)
    if not contactName or #contactName == 0 or #contactName > 30 then
        return cb({ success = false, message = 'Name must be between 1 and 30 characters' })
    end
    if not contactNumber or #contactNumber == 0 or #contactNumber > 15 then
        return cb({ success = false, message = 'Number must be between 1 and 15 digits' })
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

-- Batch endpoint: get all hotline statuses in one call
QBCore.Functions.CreateCallback('phone:server:getAllHotlineStatus', function(source, cb)
    local result = {}
    local jobTypes = { 'police', 'surrender', 'ambulance', 'mechanic', 'mayor', 'bank' }
    local playerJobs = {}

    for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
        local identity = exports['custom-career']:GetPlayerIdentity(pid)
        if identity then
            local role = identity.primary_role
            playerJobs[role] = (playerJobs[role] or 0) + 1
        end
    end

    for _, jt in ipairs(jobTypes) do
        result[jt] = playerJobs[jt] or 0
    end

    cb(result)
end)

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

-- ----------------------------------------------------
-- Phone Call System (real server-side implementation)
-- ----------------------------------------------------

-- In-memory active calls: { [callId] = { caller, receiver, startTime, status } }
local activeCalls = {}

QBCore.Functions.CreateCallback('phone:server:initiateCall', function(source, cb, targetNumber)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    local callerNumber = Player.PlayerData.charinfo.phone
    local callerName = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname

    if targetNumber == callerNumber then
        return cb({ success = false, message = 'Cannot call yourself' })
    end
    if not targetNumber or #targetNumber == 0 then
        return cb({ success = false, message = 'Invalid number' })
    end

    -- Find target player
    local targetPlayer = nil
    for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
        local P = QBCore.Functions.GetPlayer(pid)
        if P and P.PlayerData.charinfo.phone == targetNumber then
            targetPlayer = P
            break
        end
    end

    if not targetPlayer then
        -- Offline: record as missed call
        MySQL.Async.insert('INSERT INTO phone_calls (caller, receiver, status) VALUES (?, ?, ?)', {
            callerNumber, targetNumber, 'missed'
        })
        return cb({ success = false, message = 'Number unreachable. Left a missed call.' })
    end

    -- Create call record
    MySQL.Async.insert('INSERT INTO phone_calls (caller, receiver, status) VALUES (?, ?, ?)', {
        callerNumber, targetNumber, 'ringing'
    }, function(callId)
        if not callId then return cb({ success = false, message = 'Database error' }) end

        activeCalls[callId] = {
            caller = source,
            receiver = targetPlayer.PlayerData.source,
            callerNumber = callerNumber,
            receiverNumber = targetNumber,
            startTime = os.time(),
            status = 'ringing'
        }

        -- Push incoming call to target
        TriggerClientEvent('phone:client:incomingCall', targetPlayer.PlayerData.source, {
            callId = callId,
            callerNumber = callerNumber,
            callerName = callerName
        })

        cb({ success = true, callId = callId, message = 'Calling ' .. targetNumber .. '...' })
    end)
end)

QBCore.Functions.CreateCallback('phone:server:answerCall', function(source, cb, callId)
    local call = activeCalls[callId]
    if not call then return cb({ success = false, message = 'Call not found' }) end
    if call.receiver ~= source then return cb({ success = false, message = 'Not your call' }) end

    call.status = 'ongoing'
    call.startTime = os.time()

    MySQL.Async.execute('UPDATE phone_calls SET status = ? WHERE id = ?', { 'ongoing', callId })

    -- Notify caller that call was answered
    TriggerClientEvent('phone:client:callAnswered', call.caller, { callId = callId })

    cb({ success = true, message = 'Call connected' })
end)

QBCore.Functions.CreateCallback('phone:server:rejectCall', function(source, cb, callId)
    local call = activeCalls[callId]
    if not call then return cb({ success = false, message = 'Call not found' }) end

    local isCaller = (call.caller == source)
    local isReceiver = (call.receiver == source)
    if not isCaller and not isReceiver then return cb({ success = false, message = 'Not your call' }) end

    local status = 'missed'
    local duration = 0
    if isCaller then
        status = 'cancelled'
    end

    MySQL.Async.execute('UPDATE phone_calls SET status = ?, duration = ? WHERE id = ?', { status, duration, callId })

    local otherParty = isCaller and call.receiver or call.caller
    TriggerClientEvent('phone:client:callEnded', otherParty, { callId = callId, status = status })
    TriggerClientEvent('phone:client:callEnded', source, { callId = callId, status = status })

    activeCalls[callId] = nil
    cb({ success = true })
end)

QBCore.Functions.CreateCallback('phone:server:hangupCall', function(source, cb, callId)
    local call = activeCalls[callId]
    if not call then return cb({ success = false, message = 'Call not found' }) end

    local isCaller = (call.caller == source)
    local isReceiver = (call.receiver == source)
    if not isCaller and not isReceiver then return cb({ success = false, message = 'Not your call' }) end

    local duration = os.time() - call.startTime
    local status = 'completed'
    if call.status == 'ringing' and isCaller then
        status = 'cancelled'
    elseif call.status == 'ringing' then
        status = 'missed'
    end

    MySQL.Async.execute('UPDATE phone_calls SET status = ?, duration = ? WHERE id = ?', { status, duration, callId })

    local otherParty = isCaller and call.receiver or call.caller
    TriggerClientEvent('phone:client:callEnded', otherParty, { callId = callId, status = status })
    TriggerClientEvent('phone:client:callEnded', source, { callId = callId, status = status })

    activeCalls[callId] = nil
    cb({ success = true })
end)
