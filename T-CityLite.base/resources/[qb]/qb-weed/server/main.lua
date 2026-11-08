local QBCore = exports['qb-core']:GetCoreObject()

-- qb-core 重启后，上面这份快照里的函数引用会全部失效（P1-6，PR #196）：
-- 本文件原有的 onResourceStart 只处理**自己**启动（resource == GetCurrentResourceName()），
-- 不管 qb-core 重启，所以另挂一个专门重解析。
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

-- ⚠️ 这个表原来声明在文件末尾（第 126 行），而 placePlant / removeDeathPlant / harvestPlant /
-- foodPlant 都在它**之前**，于是它们引用的是全局 `plantCache`（nil），第一次调用就
-- `attempt to index a nil value (global 'plantCache')`。挪到所有 handler 之前。
local plantCache = {}

local MAX_PLANTS_PER_HOUSE = 20
local MAX_HARVEST_SEEDS = 6

local function isValidPlantName(name)
    return type(name) == 'string' and type(QBWeed) == 'table' and type(QBWeed.Plants) == 'table'
        and type(QBWeed.Plants[name]) == 'table'
end

-- 客户端发的是 `json.encode({x=,y=,z=})`（字符串），这里解码后校验三个坐标，
-- 返回**原始字符串**（DB 列一直存的就是它，不改存储格式）。
local function sanitizePlantCoords(raw)
    if type(raw) ~= 'string' or #raw > 256 then return nil end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then return nil end
    local x, y, z = tonumber(decoded.x), tonumber(decoded.y), tonumber(decoded.z)
    if not (x and y and z) then return nil end
    if math.abs(x) > 10000 or math.abs(y) > 10000 or math.abs(z) > 5000 then return nil end
    return raw
end

local function countPlantsInHouse(building)
    local count = 0
    for _, plant in pairs(plantCache) do
        if type(plant) == 'table' and plant.building == building then count = count + 1 end
    end
    return count
end

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
    -- 三个参数全来自客户端，而且这里原来**连 Player 都没取**：任何客户端都能往 house_plants
    -- 里塞任意行（building/sort/coords 全自己定），等于免费无限种。
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(currentHouse) ~= 'string' or #currentHouse == 0 or #currentHouse > 64 then return end
    if not isValidPlantName(sort) then return end
    coords = sanitizePlantCoords(coords)
    if not coords then return end
    if countPlantsInHouse(currentHouse) >= MAX_PLANTS_PER_HOUSE then return end

    local random = math.random(1, 2)
    local gender = (random == 1) and 'man' or 'woman'
    -- house_plants.plantid 是 varchar(50)：DB 回来的是字符串，
    -- 所以缓存键也必须用字符串，否则本次会话种下的植株在 removeDeathPlant / harvestPlant 里按字符串查会 miss。
    local plantId = tostring(math.random(111111, 999999))

    MySQL.insert('INSERT INTO house_plants (building, coords, gender, sort, plantid) VALUES (?, ?, ?, ?, ?)',
        { currentHouse, coords, gender, sort, plantId })
    -- ⚡ Cache update
    plantCache[plantId] = { building = currentHouse, coords = coords, gender = gender, sort = sort,
        plantid = plantId, food = 100, health = 100, progress = 0, stage = 0 }
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, currentHouse)
end)

RegisterNetEvent('qb-weed:server:removeDeathPlant', function(building, plantId)
    -- 原来谁发谁删：随便给一个 plantid 就能清掉别人屋里的植物
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(building) ~= 'string' or #building == 0 or #building > 64 then return end
    if plantId == nil then return end
    plantId = tostring(plantId)          -- 客户端回传的是 varchar 字符串，统一成字符串键

    local plant = plantCache[plantId]
    if type(plant) ~= 'table' or plant.building ~= building then return end

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
    if not Player then return end
    -- amount 只用来发种子：客户端给多少就发多少（可印物品），夹成 1..6
    amount = tonumber(amount)
    if not amount or amount < 1 then return end
    if amount > MAX_HARVEST_SEEDS then amount = MAX_HARVEST_SEEDS end
    amount = math.floor(amount)
    if type(house) ~= 'string' or #house == 0 or #house > 64 then return end
    if not isValidPlantName(plantName) then return end
    if plantId == nil then return end
    plantId = tostring(plantId)          -- 同上：统一字符串键

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
    -- 下面会读 QBWeed.Plants[plantName]['label']：plantName 不在白名单里就是 nil 索引崩线程
    if not isValidPlantName(plantName) then return end
    if type(house) ~= 'string' or #house == 0 or #house > 64 then return end
    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    if amount > 100 then amount = 100 end
    amount = math.floor(amount)
    if plantId == nil then return end
    plantId = tostring(plantId)          -- 同上：统一字符串键

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
-- 表本身声明在文件顶部（见那里的注释）；这里不能再 `local plantCache = {}`，否则遮蔽成两张表。

-- Load all plants on startup
CreateThread(function()
    local allPlants = MySQL.query.await('SELECT * FROM house_plants', {})
    if allPlants then
        for _, plant in ipairs(allPlants) do
            if type(plant) == 'table' and plant.plantid ~= nil then
                plantCache[tostring(plant.plantid)] = plant
            end
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
