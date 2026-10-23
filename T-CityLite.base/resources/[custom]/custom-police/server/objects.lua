local Objects = {}

local function CreateObjectId()
    if Objects then
        local objectId = math.random(10000, 99999)
        while Objects[objectId] do
            objectId = math.random(10000, 99999)
        end
        return objectId
    else
        local objectId = math.random(10000, 99999)
        return objectId
    end
end

RegisterNetEvent('police:server:spawnObject', function(type)
    local src = source
    -- 🔒 Security: 职业校验
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    local objectId = CreateObjectId()
    Objects[objectId] = type
    TriggerClientEvent('police:client:spawnObject', src, objectId, type, src)
end)

RegisterNetEvent('police:server:deleteObject', function(objectId)
    -- 🔒 Security: source + 职业校验
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    if not Objects[objectId] then return end
    TriggerClientEvent('police:client:removeObject', -1, objectId)
    Objects[objectId] = nil
end)

RegisterNetEvent('police:server:SyncSpikes', function(table)
    -- 🔒 Security: source + 职业校验
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    TriggerClientEvent('police:client:SyncSpikes', -1, table)
end)
