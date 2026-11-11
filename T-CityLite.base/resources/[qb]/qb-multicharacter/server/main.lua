local QBCore = exports['qb-core']:GetCoreObject()

--- I-6：角色卡的数据来自 DB，任何一列脏数据（手工改库、旧版本字段）都会让
--- json.decode 抛错，结果是**所有**角色卡都卡在加载界面。这里逐列容错：
--- 解不开就给默认值，玩家至少能进游戏（并在卡片上看到金额为 0 而不是白屏）。
local function safeDecode(raw, fallback)
    if type(raw) ~= 'string' then return raw or fallback end
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then return decoded end
    print(('[qb-multicharacter] ⚠️ 角色数据解码失败，已用默认值：%s'):format(raw:sub(1, 80)))
    return fallback
end

local hasDonePreloading = {}
local Countries = json.decode(LoadResourceFile(GetCurrentResourceName(), '/countries.json'))

-- Functions

local function GiveStarterItems(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    for _, v in pairs(QBCore.Shared.StarterItems) do
        local info = {}
        if v.item == 'id_card' then
            info.citizenid = Player.PlayerData.citizenid
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.gender = Player.PlayerData.charinfo.gender
            info.nationality = Player.PlayerData.charinfo.nationality
        elseif v.item == 'driver_license' then
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.type = 'Class C Driver License'
        end
        exports['qb-inventory']:AddItem(src, v.item, v.amount, false, info, 'qb-multicharacter:GiveStarterItems')
    end
end

local function loadHouseData(src)
    local HouseGarages = {}
    local Houses = {}
    local result = MySQL.query.await('SELECT * FROM houselocations', {})
    if result[1] ~= nil then
        for _, v in pairs(result) do
            local owned = false
            if tonumber(v.owned) == 1 then
                owned = true
            end
            local garage = v.garage ~= nil and json.decode(v.garage) or {}
            Houses[v.name] = {
                coords = json.decode(v.coords),
                owned = owned,
                price = v.price,
                locked = true,
                adress = v.label,
                tier = v.tier,
                garage = garage,
                decorations = {},
            }
            HouseGarages[v.name] = {
                label = v.label,
                takeVehicle = garage,
            }
        end
    end
    TriggerClientEvent('qb-garages:client:houseGarageConfig', src, HouseGarages)
    TriggerClientEvent('qb-houses:client:setHouseConfig', src, Houses)
end

-- Commands

QBCore.Commands.Add('logout', Lang:t('commands.logout_description'), {}, false, function(source)
    local src = source
    QBCore.Player.Logout(src)
    TriggerClientEvent('qb-multicharacter:client:chooseChar', src)
end, 'admin')

QBCore.Commands.Add('closeNUI', Lang:t('commands.closeNUI_description'), {}, false, function(source)
    local src = source
    TriggerClientEvent('qb-multicharacter:client:closeNUI', src)
end)

-- Events

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    Wait(1000) -- 1 second should be enough to do the preloading in other resources
    hasDonePreloading[Player.PlayerData.source] = true
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    hasDonePreloading[src] = false
end)

RegisterNetEvent('qb-multicharacter:server:disconnect', function()
    local src = source
    DropPlayer(src, Lang:t('commands.droppedplayer'))
end)

RegisterNetEvent('qb-multicharacter:server:loadUserData', function(cData)
    local src = source
    -- 🔒 cData 来自客户端：不是表时 `cData.citizenid` 直接抛错；citizenid 不是字符串时
    --    下面的 `:sub(1,4)` 也会抛错。归属校验在 qb-core 的 Player.Login 里（license 不匹配会 Drop）。
    if type(cData) ~= 'table' then return end
    if type(cData.citizenid) ~= 'string' or #cData.citizenid == 0 or #cData.citizenid > 32 then return end
    if QBCore.Player.Login(src, cData.citizenid) then
        repeat
            Wait(10)
        until hasDonePreloading[src]
        -- 🔒 Security: citizenid 脱敏
        local maskedCid = cData.citizenid:sub(1,4) .. '...' .. cData.citizenid:sub(-4)
        print('^2[qb-core]^7 ' .. GetPlayerName(src) .. ' (CID: ' .. maskedCid .. ') has successfully loaded!')
        QBCore.Commands.Refresh(src)
        loadHouseData(src)
        if Config.SkipSelection then
            local coords = type(cData.position) == 'string' and json.decode(cData.position) or nil
            TriggerClientEvent('qb-multicharacter:client:spawnLastLocation', src, coords, cData)
        else
            if GetResourceState('qb-apartments') == 'started' then
                -- I-3：这是"选已有角色"的路径，服务端打标；客户端传什么都覆盖掉，
                -- 否则老角色可以自称新角色，从而绕过上次位置、走公寓选择流程。
                cData.isNew = false
                TriggerClientEvent('apartments:client:setupSpawnUI', src, cData)
            else
                TriggerClientEvent('qb-spawn:client:setupSpawns', src, cData, false, nil)
                TriggerClientEvent('qb-spawn:client:openUI', src, true)
            end
        end
        local discordId = QBCore.Functions.GetIdentifier(src, 'discord')
        discordId = discordId and discordId:gsub('discord:', '') or 'unknown'
        local playerIp = QBCore.Functions.GetIdentifier(src, 'ip') or 'undefined'
        local playerLicense = QBCore.Functions.GetIdentifier(src, 'license') or 'undefined'
        TriggerEvent('qb-log:server:CreateLog', 'joinleave', 'Loaded', 'green', '**' .. GetPlayerName(src) .. '** (<@' .. discordId .. '> |  ||' .. playerIp .. '|| | ' .. playerLicense .. ' | ' .. cData.citizenid .. ' | ' .. src .. ') loaded..')
    end
end)

RegisterNetEvent('qb-multicharacter:server:createCharacter', function(data)
    local src = source
    local license = QBCore.Functions.GetIdentifier(src, 'license')

    -- Check actual number of characters already owned
    local countResult = MySQL.query.await('SELECT COUNT(*) as count FROM players WHERE license = ?', { license })
    local currentCount = countResult[1] and countResult[1].count or 0

    -- Determine max characters allowed
    local maxChars = Config.DefaultNumberOfCharacters
    if next(Config.PlayersNumberOfCharacters) then
        for _, v in pairs(Config.PlayersNumberOfCharacters) do
            if v.license == license then
                maxChars = v.numberOfChars
                break
            end
        end
    end

    if currentCount >= maxChars then
        TriggerClientEvent('QBCore:Notify', src, 'You have already reached the maximum number of characters allowed!', 'error')
        return
    end

    -- 🔒 charinfo 完全来自客户端（`newData.charinfo = data`）：不校验就等于让客户端往
    --    players.charinfo 里写任意大小/结构的内容。这里做类型与长度收敛，并只保留白名单字段。
    if type(data) ~= 'table' then return end
    local charinfo = {}
    for _, field in ipairs({
        'firstname', 'lastname', 'birthdate', 'gender', 'nationality', 'phone', 'cid', 'account',
    }) do
        local value = data[field]
        if type(value) == 'string' and #value <= 64 then
            charinfo[field] = value
        elseif type(value) == 'number' then
            charinfo[field] = value
        end
    end
    if type(charinfo.firstname) ~= 'string' or type(charinfo.lastname) ~= 'string' then return end
    local newData = {}
    newData.cid = tonumber(data.cid) or 1
    newData.charinfo = charinfo
    if QBCore.Player.Login(src, false, newData) then
        repeat
            Wait(10)
        until hasDonePreloading[src]
        if GetResourceState('qb-apartments') == 'started' and Apartments.Starting then
            local randbucket = (GetPlayerPed(src) .. math.random(1, 999))
            SetPlayerRoutingBucket(src, randbucket)
            print('^2[qb-core]^7 ' .. GetPlayerName(src) .. ' has successfully loaded!')
            QBCore.Commands.Refresh(src)
            loadHouseData(src)
            TriggerClientEvent('qb-multicharacter:client:closeNUI', src)
            newData.isNew = true   -- I-3：只有这条路是真·新角色
            TriggerClientEvent('apartments:client:setupSpawnUI', src, newData)
            GiveStarterItems(src)
        else
            print('^2[qb-core]^7 ' .. GetPlayerName(src) .. ' has successfully loaded!')
            QBCore.Commands.Refresh(src)
            loadHouseData(src)
            TriggerClientEvent('qb-multicharacter:client:closeNUIdefault', src)
            GiveStarterItems(src)
            TriggerEvent('apartments:client:SetHomeBlip', nil)
        end
    end
end)

RegisterNetEvent('qb-multicharacter:server:deleteCharacter', function(citizenid)
    local src = source
    if not Config.EnableDeleteButton then return end
    if type(citizenid) ~= 'string' or #citizenid == 0 or #citizenid > 32 then return end
    QBCore.Player.DeleteCharacter(src, citizenid)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('notifications.char_deleted'), 'success')
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-multicharacter:server:GetUserCharacters', function(source, cb)
    local src = source
    local license = QBCore.Functions.GetIdentifier(src, 'license')

    MySQL.query('SELECT * FROM players WHERE license = ?', { license }, function(result)
        cb(result)
    end)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:GetServerLogs', function(_, cb)
    MySQL.query('SELECT * FROM server_logs', {}, function(result)
        cb(result)
    end)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:GetNumberOfCharacters', function(source, cb)
    local src = source
    local license = QBCore.Functions.GetIdentifier(src, 'license')
    local numOfChars = 0

    if next(Config.PlayersNumberOfCharacters) then
        for _, v in pairs(Config.PlayersNumberOfCharacters) do
            if v.license == license then
                numOfChars = v.numberOfChars
                break
            else
                numOfChars = Config.DefaultNumberOfCharacters
            end
        end
    else
        numOfChars = Config.DefaultNumberOfCharacters
    end
    cb(numOfChars, Countries)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:setupCharacters', function(source, cb)
    local license = QBCore.Functions.GetIdentifier(source, 'license')
    local plyChars = {}
    MySQL.query('SELECT * FROM players WHERE license = ?', { license }, function(result)
        for i = 1, (#result), 1 do
            result[i].charinfo = safeDecode(result[i].charinfo, {})
            result[i].money = safeDecode(result[i].money, { cash = 0, bank = 0 })
            result[i].job = safeDecode(result[i].job, { name = 'unemployed', label = '无业', grade = { level = 0, name = '—' } })
            result[i].metadata = safeDecode(result[i].metadata, {})
            result[i].position = safeDecode(result[i].position, { x = 0.0, y = 0.0, z = 0.0, a = 0.0 })
            -- I-1：角色卡是**数据库快照**，必须把"这是什么时候的"一起告诉玩家。
            -- players.last_updated 是 ON UPDATE CURRENT_TIMESTAMP，保存时会刷新。
            result[i].lastUpdated = result[i].last_updated
            plyChars[#plyChars + 1] = result[i]
        end
        cb(plyChars)
    end)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:getSkin', function(_, cb, cid)
    local result = MySQL.query.await('SELECT * FROM playerskins WHERE citizenid = ? AND active = ?', { cid, 1 })
    if result[1] ~= nil then
        cb(result[1].model, result[1].skin)
    else
        cb(nil)
    end
end)

QBCore.Commands.Add('deletechar', Lang:t('commands.deletechar_description'), { { name = Lang:t('commands.citizenid'), help = Lang:t('commands.citizenid_help') } }, false, function(source, args)
    if args and args[1] then
        QBCore.Player.ForceDeleteCharacter(tostring(args[1]))
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notifications.deleted_other_char', { citizenid = tostring(args[1]) }))
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notifications.forgot_citizenid'), 'error')
    end
end, 'god')
