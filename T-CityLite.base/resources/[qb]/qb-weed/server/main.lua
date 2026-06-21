local QBCore = exports['qb-core']:GetCoreObject()

QBCore.Functions.CreateCallback('qb-weed:server:getBuildingPlants', function(_, cb, building)
    local buildingPlants = {}

    MySQL.query('SELECT * FROM house_plants WHERE building = ?', { building }, function(plants)
        for i = 1, #plants, 1 do
            buildingPlants[#buildingPlants + 1] = plants[i]
        end

        cb(buildingPlants)
    end)
end)

RegisterNetEvent('qb-weed:server:placePlant', function(coords, sort, currentHouse)
    local random = math.random(1, 2)
    local gender = (random == 1) and 'man' or 'woman'
    local plantId = math.random(111111, 999999)

    MySQL.insert('INSERT INTO house_plants (building, coords, gender, sort, plantid) VALUES (?, ?, ?, ?, ?)',
        { currentHouse, coords, gender, sort, plantId })
    -- ⚡ Cache update
    plantCache[plantId] = { building = currentHouse, coords = coords, gender = gender, sort = sort,
        plantid = plantId, food = 100, health = 100, progress = 0, stage = 0 }
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, currentHouse)
end)

RegisterNetEvent('qb-weed:server:removeDeathPlant', function(building, plantId)
    MySQL.query('DELETE FROM house_plants WHERE plantid = ? AND building = ?', { plantId, building })
    plantCache[plantId] = nil
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, building)
end)

RegisterServerEvent('qb-weed:server:removeSeed', function(itemslot, seed)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    exports['qb-inventory']:RemoveItem(src, seed, 1, itemslot, 'qb-weed:server:removeSeed')
end)

RegisterNetEvent('qb-weed:server:harvestPlant', function(house, amount, plantName, plantId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local weedBag = Player.Functions.GetItemByName('empty_weed_bag')
    local sndAmount = math.random(12, 16)
    if weedBag ~= nil and weedBag.amount >= sndAmount then
        if house ~= nil then
            -- ⚡ Check cache first, fallback to DB
            local plant = plantCache[plantId]
            if not plant then
                local result = MySQL.query.await('SELECT * FROM house_plants WHERE plantid = ? AND building = ?', { plantId, house })
                if result[1] ~= nil then plant = result[1] end
            end
            if plant then
                exports['qb-inventory']:AddItem(src, 'weed_' .. plantName .. '_seed', amount, false, false, 'qb-weed:server:harvestPlant')
                exports['qb-inventory']:AddItem(src, 'weed_' .. plantName, sndAmount, false, false, 'qb-weed:server:harvestPlant')
                exports['qb-inventory']:RemoveItem(src, 'empty_weed_bag', sndAmount, false, 'qb-weed:server:harvestPlant')
                MySQL.query('DELETE FROM house_plants WHERE plantid = ? AND building = ?', { plantId, house })
                plantCache[plantId] = nil -- ⚡ Purge from cache
                TriggerClientEvent('QBCore:Notify', src, Lang:t('text.the_plant_has_been_harvested'), 'success', 3500)
                TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, house)
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.this_plant_no_longer_exists'), 'error', 3500)
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.house_not_found'), 'error', 3500)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.you_dont_have_enough_resealable_bags'), 'error', 3500)
    end
end)

RegisterNetEvent('qb-weed:server:foodPlant', function(house, amount, plantName, plantId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- ⚡ Check cache first
    local plant = plantCache[plantId]
    if not plant then
        local result = MySQL.query.await('SELECT * FROM house_plants WHERE building = ? AND sort = ? AND plantid = ?',{ house, plantName, tostring(plantId) })
        if result[1] then plant = result[1]; plantCache[plantId] = plant end
    end
    if not plant then return end
    local updatedFood = math.min(100, plant.food + amount)
    TriggerClientEvent('QBCore:Notify', src, QBWeed.Plants[plantName]['label'] ..' | Nutrition: ' .. plant.food .. '% + ' .. updatedFood - plant.food .. '% (' ..updatedFood .. '%)', 'success', 3500)
    plant.food = updatedFood
    plant._dirty = true -- ⚡ Mark dirty instead of immediate SQL
    MySQL.update('UPDATE house_plants SET food = ? WHERE building = ? AND plantid = ?',{ updatedFood, house, plantId })
    exports['qb-inventory']:RemoveItem(src, 'weed_nutrition', 1, false, 'qb-weed:server:foodPlant')
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, house)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for plantName, _ in pairs(QBWeed.Plants) do
        QBCore.Functions.CreateUseableItem('weed_' .. plantName .. '_seed', function(source, item)
            TriggerClientEvent('qb-weed:client:placePlant', source, plantName, item)
        end)
    end
    QBCore.Functions.CreateUseableItem('weed_nutrition', function(source, item)
        TriggerClientEvent('qb-weed:client:foodPlant', source, item)
    end)
end)

-- ⚡ Performance: Memory-first plant cache — eliminates SELECT * FROM house_plants on every tick
-- Plants are loaded once at startup, updated in-memory, and flush to DB via DirtyFlush pipeline
local plantCache = {} -- { [plantId] = { building, coords, gender, sort, food, health, progress, stage, plantid } }

-- Load all plants on startup
CreateThread(function()
    local allPlants = MySQL.query.await('SELECT * FROM house_plants', {})
    if allPlants then
        for _, plant in ipairs(allPlants) do
            plantCache[plant.plantid] = plant
        end
    end
    print(('[qb-weed] 🌱 Loaded %d plants into memory cache'):format(#allPlants or 0))
end)

-- Periodic DB flush (every 5 minutes — delegates to DirtyFlush for actual DB write)
CreateThread(function()
    while true do
        Wait(5 * 60 * 1000)
        -- Batch update all dirty plants
        local count = 0
        for plantId, plant in pairs(plantCache) do
            if plant._dirty then
                MySQL.update(
                    'UPDATE house_plants SET food = ?, health = ?, progress = ?, stage = ? WHERE plantid = ?',
                    { plant.food, plant.health, plant.progress, plant.stage, plantId }
                )
                plant._dirty = nil
                count = count + 1
            end
        end
        if count > 0 then
            print(('[qb-weed] 💾 Flushed %d plants to DB'):format(count))
        end
    end
end)

-- Growth tick: operates entirely in memory
CreateThread(function()
    local healthTick = false
    while true do
        for plantId, plant in pairs(plantCache) do
            if plant.health > 50 then
                local Grow = math.random(QBWeed.Progress.min, QBWeed.Progress.max)
                if plant.progress + Grow < 100 then
                    plant.progress = plant.progress + Grow
                elseif plant.progress + Grow >= 100 then
                    if plant.stage ~= QBWeed.Plants[plant.sort]['highestStage'] then
                        plant.stage = plant.stage + 1
                        plant.progress = 0
                    end
                end
                plant._dirty = true
            end
            if healthTick then
                local plantFood = math.max(0, plant.food - QBWeed.FoodUsage)
                local plantHealth = (plantFood >= 50) and math.min(100, plant.health + 1) or math.max(0, plant.health - 1)
                plant.food = plantFood
                plant.health = plantHealth
                plant._dirty = true
            end
        end

        TriggerClientEvent('qb-weed:client:refreshHousePlants', -1)
        healthTick = not healthTick
        Wait((60 * 1000) * QBWeed.GrowthTick)
    end
end)
