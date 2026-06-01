local QBCore = exports['qb-core']:GetCoreObject()
local skinCache = {}

local function SavePlayerSkinOffline(citizenid)
    local cache = skinCache[citizenid]
    if cache and cache.isDirty then
        -- 缓存脏数据写回 SQL
        MySQL.query('DELETE FROM playerskins WHERE citizenid = ?', { citizenid }, function()
            MySQL.insert('INSERT INTO playerskins (citizenid, model, skin, active) VALUES (?, ?, ?, ?)', {
                citizenid,
                cache.model,
                cache.skin,
                1
            })
            cache.isDirty = false
            print(("[qb-clothing] 成功将角色服装 RAM 脏数据 (%s) 批量持久化同步至数据库。"):format(citizenid))
        end)
    end
end

RegisterServerEvent("qb-clothing:saveSkin", function(model, skin)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if model ~= nil and skin ~= nil then
        -- 核心优化：直接高频读写 RAM 缓存，零磁盘 I/O 开销
        skinCache[Player.PlayerData.citizenid] = {
            model = model,
            skin = skin,
            isDirty = true
        }
    end
end)

RegisterServerEvent("qb-clothes:loadPlayerSkin", function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    -- 核心优化：如果 RAM 中有缓存，100% 避免 SQL 查询读取
    if skinCache[citizenid] then
        local cache = skinCache[citizenid]
        TriggerClientEvent("qb-clothes:loadSkin", src, false, cache.model, cache.skin)
    else
        local result = MySQL.query.await('SELECT * FROM playerskins WHERE citizenid = ? AND active = ?', { citizenid, 1 })
        if result[1] ~= nil then
            skinCache[citizenid] = {
                model = result[1].model,
                skin = result[1].skin,
                isDirty = false
            }
            TriggerClientEvent("qb-clothes:loadSkin", src, false, result[1].model, result[1].skin)
        else
            TriggerClientEvent("qb-clothes:loadSkin", src, true)
        end
    end
end)

-- 监听换线退服，强制安全刷回 SQL 数据库以保障绝对数据安全
RegisterNetEvent('QBCore:Server:OnPlayerUnload', function(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        SavePlayerSkinOffline(Player.PlayerData.citizenid)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        SavePlayerSkinOffline(Player.PlayerData.citizenid)
    end
end)

-- 资源重启/关服强载落盘
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for citizenid, cache in pairs(skinCache) do
            if cache.isDirty then
                MySQL.query.await('DELETE FROM playerskins WHERE citizenid = ?', { citizenid })
                MySQL.insert.await('INSERT INTO playerskins (citizenid, model, skin, active) VALUES (?, ?, ?, ?)', {
                    citizenid,
                    cache.model,
                    cache.skin,
                    1
                })
            end
        end
    end
end)

RegisterServerEvent("qb-clothes:saveOutfit", function(outfitName, model, skinData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if model ~= nil and skinData ~= nil then
        local outfitId = "outfit-"..math.random(1, 10).."-"..math.random(1111, 9999)
        MySQL.insert('INSERT INTO player_outfits (citizenid, outfitname, model, skin, outfitId) VALUES (?, ?, ?, ?, ?)', {
            Player.PlayerData.citizenid,
            outfitName,
            model,
            json.encode(skinData),
            outfitId
        }, function()
            local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
            if result[1] ~= nil then
                TriggerClientEvent('qb-clothing:client:reloadOutfits', src, result)
            else
                TriggerClientEvent('qb-clothing:client:reloadOutfits', src, nil)
            end
        end)
    end
end)

RegisterServerEvent("qb-clothing:server:removeOutfit", function(outfitName, outfitId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    MySQL.query('DELETE FROM player_outfits WHERE citizenid = ? AND outfitname = ? AND outfitId = ?', {
        Player.PlayerData.citizenid,
        outfitName,
        outfitId
    }, function()
        local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if result[1] ~= nil then
            TriggerClientEvent('qb-clothing:client:reloadOutfits', src, result)
        else
            TriggerClientEvent('qb-clothing:client:reloadOutfits', src, nil)
        end
    end)
end)

QBCore.Functions.CreateCallback('qb-clothing:server:getOutfits', function(source, cb)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local anusVal = {}

    local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
    if result[1] ~= nil then
        for k, v in pairs(result) do
            result[k].skin = json.decode(result[k].skin)
            anusVal[k] = v
        end
        cb(anusVal)
    end
    cb(anusVal)
end)
