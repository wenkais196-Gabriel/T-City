local QBCore = exports['qb-core']:GetCoreObject()
local skinCache = {}

-- ⚠️ qb-core 重启后，上面的顶层缓存是**旧 script host 的快照**，表里的函数引用全部失效
-- （真机 2026-11-07 实测：`Execution of function reference in script host failed`）。
-- 本资源没有 `dependency 'qb-core'`，所以 `restart qb-core` 不会停它 —— 必须自己重解析。
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'qb-core' then return end
    -- ⚠️ 不能在事件里同步调：真机实测此刻 export 引用可能还指向 qb-core 旧 script host，
    -- 会抛 `Execution of function reference in script host failed`。放线程里重试到拿到新表。
    CreateThread(function()
        for _ = 1, 30 do
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
                return
            end
            Wait(500)
        end
    end)
end)

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
            -- 🔒 Security: citizenid 脱敏
            local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
            print(("[qb-clothing] 成功将角色服装 RAM 脏数据 (%s) 批量持久化同步至数据库。"):format(maskedCid))
        end)
    end
end

-- 皮肤数据来自客户端：结构必须是有界的哈希（不是数组、不是几 MB 的字符串），
-- 否则一次请求就能把 RAM 缓存与 playerskins 列写爆。
local function isValidSkinPayload(model, skin)
    if type(model) ~= 'string' or #model > 64 then return false end
    if type(skin) ~= 'table' then return false end
    local entries = 0
    for key, value in pairs(skin) do
        entries = entries + 1
        if entries > 64 then return false end
        if type(key) ~= 'string' and type(key) ~= 'number' then return false end
        if type(value) ~= 'string' and type(value) ~= 'number' and type(value) ~= 'boolean' then
            return false
        end
    end
    return true
end

RegisterServerEvent("qb-clothing:saveSkin", function(model, skin)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if isValidSkinPayload(model, skin) then
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
    -- 🔒 这是 qb-core 服务端内部事件（服务端触发时 source 是 0）：客户端不能自己发一份，
    --    更不能用别人的 src 去强制写盘别人的皮肤。
    if source ~= 0 then return end
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

local MAX_OUTFITS_PER_PLAYER = 30

RegisterServerEvent("qb-clothes:saveOutfit", function(outfitName, model, skinData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 🔒 三个参数都来自客户端：名字要短、模型要合法、皮肤要有界；
    --    而且必须有条数上限 —— 原来可以无限插 `player_outfits`（每次插入还会全表回读）。
    if type(outfitName) ~= 'string' or #outfitName == 0 or #outfitName > 48 then return end
    if not isValidSkinPayload(model, skinData) then return end
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid }) or 0
    if count >= MAX_OUTFITS_PER_PLAYER then
        TriggerClientEvent('QBCore:Notify', src, ('最多保存 %d 套服装'):format(MAX_OUTFITS_PER_PLAYER), 'error')
        return
    end
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
    if not Player then return end
    if type(outfitName) ~= 'string' or type(outfitId) ~= 'string' then return end
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
