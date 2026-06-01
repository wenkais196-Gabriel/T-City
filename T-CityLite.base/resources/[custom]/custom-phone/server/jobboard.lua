local QBCore = exports['qb-core']:GetCoreObject()

-- Get coordinates based on job title
local function GetJobCoords(title)
    title = title:lower()
    if string.find(title, "dock") or string.find(title, "port") or string.find(title, "haul") then
        return vector3(1201.2, -3101.4, 5.8) -- LS Port Docks
    elseif string.find(title, "recycl") or string.find(title, "mirror") then
        return vector3(1039.8, -310.5, 59.0) -- Mirror Park Recycling
    elseif string.find(title, "hospital") or string.find(title, "medic") then
        return vector3(356.2, -584.8, 28.8) -- Pillbox Hospital
    elseif string.find(title, "police") or string.find(title, "sheriff") then
        return vector3(428.2, -984.2, 30.7) -- Mission Row PD
    else
        return vector3(-268.4, -957.5, 31.2) -- Maze Bank Tower Downtown
    end
end

-- 1. Accept job callback
QBCore.Functions.CreateCallback('phone:server:acceptJob', function(source, cb, id)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    local citizenid = Player.PlayerData.citizenid

    -- Retrieve job
    MySQL.Async.fetchAll('SELECT * FROM phone_jobboard WHERE id = ?', { id }, function(results)
        if not results or #results == 0 then
            return cb({ success = false, message = 'Urban Project not found' })
        end

        local job = results[1]
        if job.status ~= 'open' then
            return cb({ success = false, message = 'Project is already taken or completed' })
        end

        -- Server-side Career Tags Verification (Security Hardening)
        local targetTags = json.decode(job.target_tags)
        if targetTags then
            local success, matched = pcall(function()
                return exports['custom-career']:PlayerMatchesTags(source, targetTags)
            end)
            if success and not matched then
                return cb({ success = false, message = 'Unauthorized: You do not meet the career tag requirements for this project' })
            end
        end

        -- Update job state to taken
        MySQL.Async.execute('UPDATE phone_jobboard SET status = "taken", taken_by = ? WHERE id = ?', {
            citizenid, id
        }, function(affected)
            if affected > 0 then
                local coords = GetJobCoords(job.title)
                
                -- Broadcast state update to all players
                local jobUpdate = {
                    id = job.id,
                    task_id = job.task_id,
                    title = job.title,
                    description = job.description,
                    target_tags = json.decode(job.target_tags),
                    reward = job.reward,
                    status = 'taken',
                    taken_by = citizenid
                }
                TriggerClientEvent('phone:client:newJob', -1, jobUpdate)

                -- Send routing waypoint to the accepting client
                TriggerClientEvent('phone:client:routeGps', source, coords, job.title)

                -- Trigger client-side distance tracker in Lua
                TriggerClientEvent('phone:client:trackJobArrival', source, id, coords)

                cb({ success = true, message = 'Project accepted! GPS Waypoint routed.' })
            else
                cb({ success = false, message = 'Failed to lock project' })
            end
        end)
    end)
end)

-- 2. Post job callback (Mayor App)
QBCore.Functions.CreateCallback('phone:server:postJob', function(source, cb, title, description, reward)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not title or #title == 0 or #title > 50 then
        return cb({ success = false, message = 'Project title must be between 1 and 50 characters' })
    end
    if not description or #description == 0 or #description > 500 then
        return cb({ success = false, message = 'Project description must be between 1 and 500 characters' })
    end

    -- Verify leader permission
    local identity = exports['custom-career']:GetPlayerIdentity(source)
    if not identity or identity.rank_tier ~= 'leader' or identity.primary_role ~= 'mayor' then
        return cb({ success = false, message = 'Unauthorized: Executive clearance required' })
    end

    reward = tonumber(reward) or 0
    if reward <= 0 then return cb({ success = false, message = 'Invalid payout budget' }) end

    local target_tags = json.encode({ role = 'civilian', tier = 'entry' })
    local task_id = math.random(100, 999)

    MySQL.Async.insert('INSERT INTO phone_jobboard (task_id, title, description, target_tags, reward, status) VALUES (?, ?, ?, ?, ?, "open")', {
        task_id, title, description, target_tags, reward
    }, function(insertId)
        if insertId then
            local jobData = {
                id = insertId,
                task_id = task_id,
                title = title,
                description = description,
                target_tags = { role = 'civilian', tier = 'entry' },
                reward = reward,
                status = 'open',
                taken_by = nil,
                posted_at = os.date('%Y-%m-%d %H:%M:%S')
            }

            -- Broadcast new job to all citizens
            TriggerClientEvent('phone:client:newJob', -1, jobData)
            
            -- Push notification to all online players
            for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
                TriggerClientEvent('phone:client:newNotification', playerId, {
                    id = math.random(1000, 9999),
                    title = "📋 New Urban Project",
                    content = ("Project \"%s\" published by the Mayor! Payout: $%d."):format(title, reward),
                    timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                    is_read = false
                })
            end

            -- Discord Log
            local auditText = ("**市长**: %s (%s)\n**工程**: %s\n**预算**: $%d\n**详述**: %s"):format(
                GetPlayerName(source), Player.PlayerData.citizenid, title, reward, description
            )
            exports['custom-main']:LogEconomy("发布城市工程", auditText, 16776960)

            cb({ success = true, job = jobData, message = 'City Project published successfully!' })
        else
            cb({ success = false, message = 'Database error' })
        end
    end)
end)

-- 3. Job completion receiver event
RegisterNetEvent('phone:server:completeJob', function(id)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    MySQL.Async.fetchAll('SELECT * FROM phone_jobboard WHERE id = ?', { id }, function(results)
        if not results or #results == 0 then return end
        
        local job = results[1]
        if job.status ~= 'open' and (job.status ~= 'taken' or job.taken_by ~= citizenid) then return end

        -- Server-side Distance Verification (Antispoof / Anti-Cheat)
        local targetCoords = GetJobCoords(job.title)
        local ped = GetPlayerPed(src)
        if ped and ped > 0 then
            local playerCoords = GetEntityCoords(ped)
            local dist = #(playerCoords - targetCoords)
            if dist > 25.0 then -- Allow 25.0m buffer for sync latency
                local alertText = ("**玩家**: %s (%s)\n**欺骗交单**: %s\n**目标坐标**: %s\n**实际坐标**: %s\n**超限距离**: %.2f 米 (已强行拦截欺骗事件)"):format(
                    GetPlayerName(src), citizenid, job.title, tostring(targetCoords), tostring(playerCoords), dist
                )
                -- Trigger Security Alarm Discord log
                exports['custom-main']:LogEconomy("安全防刷拦截", alertText, 16711680) -- 鲜红高亮
                print(("[custom-phone][security] Blocked distance spoof for player %s. Distance: %.2f"):format(GetPlayerName(src), dist))
                return
            end
        end

        -- Update DB status to completed
        MySQL.Async.execute('UPDATE phone_jobboard SET status = "completed" WHERE id = ?', { id }, function(affected)
            if affected > 0 then
                -- Add money using the unified custom-economy export (AddScaledMoney)
                local finalAmount, scale = exports['custom-main']:AddScaledMoney(src, 'bank', job.reward, "Urban Project: " .. job.title)

                -- Push success notification to the player
                TriggerClientEvent('phone:client:newNotification', src, {
                    id = math.random(1000, 9999),
                    title = "📋 Project Completed!",
                    content = ("You completed \"%s\" and received $%d (scaled by %.2f multiplier)."):format(job.title, finalAmount, scale),
                    timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                    is_read = false
                })

                -- Push update to NUI
                local completedJob = {
                    id = job.id,
                    task_id = job.task_id,
                    title = job.title,
                    description = job.description,
                    target_tags = json.decode(job.target_tags),
                    reward = job.reward,
                    status = 'completed',
                    taken_by = citizenid
                }
                TriggerClientEvent('phone:client:newJob', -1, completedJob)
            end
        end)
    end)
end)
