local QBCore = exports['qb-core']:GetCoreObject()

--- 车库服务端反馈（V-3）：扣押缴费这类动作必须有回执，否则玩家不知道钱扣没扣。
local function feedback(src, kind, title, body)
    pcall(function()
        exports['custom-notify']:Push(src, kind, title, body)
    end)
end

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
local OutsideVehicles = {}

-- Handler

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        Wait(100)
        if Config['AutoRespawn'] then
            MySQL.update('UPDATE player_vehicles SET state = 1 WHERE state = 0', {})
        else
            MySQL.update('UPDATE player_vehicles SET depotprice = 500 WHERE state = 0', {})
        end
    end
end)

-- Functions

local vehicleClasses = {
    compacts = 0,
    sedans = 1,
    suvs = 2,
    coupes = 3,
    muscle = 4,
    sportsclassics = 5,
    sports = 6,
    super = 7,
    motorcycles = 8,
    offroad = 9,
    industrial = 10,
    utility = 11,
    vans = 12,
    cycles = 13,
    boats = 14,
    helicopters = 15,
    planes = 16,
    service = 17,
    emergency = 18,
    military = 19,
    commercial = 20,
    trains = 21,
    openwheel = 22,
}

local function arrayToSet(array)
    local set = {}
    for _, item in ipairs(array) do
        set[item] = true
    end
    return set
end

local function filterVehiclesByCategory(vehicles, category)
    local filtered = {}
    local categorySet = arrayToSet(category)

    for _, vehicle in pairs(vehicles) do
        local vehicleData = QBCore.Shared.Vehicles[vehicle.vehicle]
        local vehicleCategoryString = vehicleData and vehicleData.category or 'compacts'
        local vehicleCategoryNumber = vehicleClasses[vehicleCategoryString]

        if vehicleCategoryNumber and categorySet[vehicleCategoryNumber] then
            filtered[#filtered + 1] = vehicle
        end
    end

    return filtered
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-garages:server:getHouseGarage', function(_, cb, house)
    local houseInfo = MySQL.single.await('SELECT * FROM houselocations WHERE name = ?', { house })
    cb(houseInfo)
end)

QBCore.Functions.CreateCallback('qb-garages:server:GetGarageVehicles', function(source, cb, garage, type, category)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local citizenId = Player.PlayerData.citizenid

    local vehicles

    if type == 'depot' then
        vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND depotprice > 0', { citizenId })
    elseif Config.SharedGarages then
        vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenId })
        print(('[qb-garages] shared query citizen=%s garage=%s -> %d vehicles'):format(
            citizenId:sub(1, 4) .. '...', tostring(garage), #(vehicles or {})))
    else
        vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ?', { citizenId, garage })
    end
    if #vehicles == 0 then
        -- Phase 6: 诊断日志 — 区分"没车"与"车停在别的车库"
        local owned = MySQL.scalar.await(
            'SELECT COUNT(*) FROM player_vehicles WHERE citizenid = ?', { citizenId }) or 0
        local rows = MySQL.query.await(
            'SELECT garage, COUNT(*) AS c FROM player_vehicles WHERE citizenid = ? GROUP BY garage',
            { citizenId }) or {}
        local where = {}
        for _, row in ipairs(rows) do
            where[#where + 1] = ('%s=%d'):format(row.garage or 'nil', row.c)
        end
        print(('[qb-garages] 🔍 No vehicles at garage=%s (citizen=%s owned=%d: %s)'):format(
            tostring(garage), citizenId:sub(1, 4) .. '...', owned, table.concat(where, ', ')))

        -- 玩家在错误车库时给出明确提示（车辆集中在哪个车库）
        if owned > 0 then
            local hints = {}
            for _, row in ipairs(rows) do
                local cfg = Config.Garages[row.garage]
                hints[#hints + 1] = ('%s ×%d'):format(
                    cfg and cfg.label or tostring(row.garage), row.c)
            end
            TriggerClientEvent('QBCore:Notify', source,
                ('本车库没有车辆。你的车停在：%s'):format(table.concat(hints, ' / ')),
                'primary', 8000)
        end

        cb(nil)
        return
    end
    if Config.ClassSystem then
        local filteredVehicles = filterVehiclesByCategory(vehicles, category)
        cb(filteredVehicles)
    else
        cb(vehicles)
    end
end)

-- Backwards Compat
local vehicleTypes = { -- https://docs.fivem.net/natives/?_0xA273060E
    motorcycles = 'bike',
    boats = 'boat',
    helicopters = 'heli',
    planes = 'plane',
    submarines = 'submarine',
    trailer = 'trailer',
    train = 'train'
}

local function GetVehicleTypeByModel(model)
    local vehicleData = QBCore.Shared.Vehicles[model]
    if not vehicleData then return 'automobile' end
    local category = vehicleData.category
    local vehicleType = vehicleTypes[category]
    return vehicleType or 'automobile'
end
-- 车辆类别 → 证件类型映射
local VehicleClassLicenseMap = {
    [0] = 'driver', [1] = 'driver', [2] = 'driver', [3] = 'driver', [4] = 'driver',
    [5] = 'driver', [6] = 'driver', [7] = 'driver', [8] = 'driver', [9] = 'driver',
    [10] = 'heavy', [11] = 'heavy', [17] = 'heavy', [19] = 'heavy', [20] = 'heavy',
    [12] = 'driver', [13] = 'driver', [18] = 'driver', [22] = 'driver',
    [14] = 'boat',
    [15] = 'pilot', [16] = 'pilot',
}
-- Backwards Compat

-- Spawns a vehicle and returns its network ID and properties.
-- 🔒 服务端证件验证：防止客户端绕过车库 blip/zone 门控
QBCore.Functions.CreateCallback('qb-garages:server:spawnvehicle', function(source, cb, plate, vehicle, coords)
    local Player = QBCore.Functions.GetPlayer(source)
    print(('[qb-garages] spawnvehicle request src=%s plate=%s vehicle=%s'):format(
        tostring(source), tostring(plate), tostring(vehicle)))
    if Player then
        -- 🚗 每人最多 3 辆载具在车库外
        local outsideCount = MySQL.scalar.await('SELECT COUNT(*) FROM player_vehicles WHERE citizenid = ? AND state = 0', { Player.PlayerData.citizenid })
        if outsideCount >= 3 then
            print(('[qb-garages] spawnvehicle rejected: outsideCount=%d'):format(outsideCount))
            TriggerClientEvent('QBCore:Notify', source, '你已经有 3 辆载具在外面了，先存一辆再取', 'error', 5000)
            cb(nil)
            return
        end

        -- 🔒 plate / vehicle / coords 全部来自客户端：
        --    ① 车牌必须属于调用者；② 车型必须与库里登记的一致；③ 生成点必须在自己附近
        --    （否则可以拿别人的车牌 / 换一个自己的车牌生成任意模型 / 全图任意点刷车）。
        if type(plate) ~= 'string' or type(vehicle) ~= 'string' then
            cb(nil)
            return
        end
        local owned = MySQL.single.await(
            'SELECT citizenid, vehicle FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
        if not owned or owned.citizenid ~= Player.PlayerData.citizenid then
            print(('[qb-garages] spawnvehicle rejected: plate %s 不属于 src=%s'):format(
                tostring(plate), tostring(source)))
            cb(nil)
            return
        end
        if tostring(owned.vehicle) ~= vehicle then
            print(('[qb-garages] spawnvehicle rejected: 车型不符 plate=%s db=%s req=%s'):format(
                tostring(plate), tostring(owned.vehicle), tostring(vehicle)))
            cb(nil)
            return
        end
        -- ⚠️ 客户端传的是 `GetSpawnPoint(garage)` 的返回值，即 **vector4**（`type()` == 'vector4'），
        --    不是 table。只认 table 会把所有正常取车（公共车库 / 房车 / 赎车）全拒掉。
        local ctype = type(coords)
        if ctype ~= 'table' and ctype ~= 'vector3' and ctype ~= 'vector4' then
            cb(nil)
            return
        end
        local cx, cy, cz = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
        if not cx or not cy or not cz then
            cb(nil)
            return
        end
        local ped = GetPlayerPed(source)
        local pcoords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
        if not pcoords or #(pcoords - vector3(cx, cy, cz)) > 100.0 then
            print(('[qb-garages] spawnvehicle rejected: 生成点离玩家太远 plate=%s'):format(tostring(plate)))
            cb(nil)
            return
        end

        local vehData = QBCore.Shared.Vehicles[vehicle]
        local vehCategory = vehData and vehData.category
        local vehClassNum = vehCategory and vehicleClasses[vehCategory]
        local requiredLicense = vehClassNum and VehicleClassLicenseMap[vehClassNum]
        if requiredLicense then
            local licences = Player.PlayerData.metadata['licences']
            if not licences or not licences[requiredLicense] then
                print(('[qb-garages] spawnvehicle rejected: missing license=%s'):format(tostring(requiredLicense)))
                TriggerClientEvent('QBCore:Notify', source, 'You need a valid license to spawn this vehicle type!', 'error', 5000)
                cb(nil)
                return
            end
        end
    end
    local vehType = QBCore.Shared.Vehicles[vehicle] and QBCore.Shared.Vehicles[vehicle].type or GetVehicleTypeByModel(vehicle)
    local veh = CreateVehicleServerSetter(GetHashKey(vehicle), vehType, coords.x, coords.y, coords.z, coords.w)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetVehicleNumberPlateText(veh, plate)
    local vehProps = {}
    local result = MySQL.single.await('SELECT mods FROM player_vehicles WHERE plate = ?', { plate })
    if result then vehProps = json.decode(result.mods) end
    OutsideVehicles[plate] = { netID = netId, entity = veh }
    cb(netId, vehProps, plate)
end)

-- Checks if a vehicle can be spawned based on its type and location.
QBCore.Functions.CreateCallback('qb-garages:server:IsSpawnOk', function(_, cb, plate, type)
    if OutsideVehicles[plate] and DoesEntityExist(OutsideVehicles[plate].entity) then
        cb(false)
        return
    end
    cb(true)
end)

QBCore.Functions.CreateCallback('qb-garages:server:canDeposit', function(source, cb, plate, type, garage, state)
    local Player = QBCore.Functions.GetPlayer(source)
    local isOwned = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    print(('[qb-garages] canDeposit plate=%s type=%s garage=%s state=%s owner=%s player=%s'):format(
        tostring(plate), tostring(type), tostring(garage), tostring(state),
        tostring(isOwned), tostring(Player.PlayerData.citizenid)))
    if isOwned ~= Player.PlayerData.citizenid then
        cb(false)
        return
    end
    if type == 'house' and not exports['qb-houses']:hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, Config.Garages[garage].houseName) then
        cb(false)
        return
    end
    if state == 1 then
        MySQL.update('UPDATE player_vehicles SET state = ?, garage = ? WHERE plate = ?', { state, garage, plate })
        cb(true)
    else
        cb(false)
    end
end)

-- Events

RegisterNetEvent('qb-garages:server:updateVehicleStats', function(plate, fuel, engine, body)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(plate) ~= 'string' then return end
    -- 🔒 三个数值都来自客户端：夹到合理区间，别让 fuel=999999 这种脏数据进库
    fuel = math.max(0, math.min(100, tonumber(fuel) or 0))
    engine = math.max(0, math.min(1000, tonumber(engine) or 0))
    body = math.max(0, math.min(1000, tonumber(body) or 0))
    MySQL.update('UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', { fuel, engine, body, plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('qb-garages:server:updateVehicleState', function(state, plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(plate) ~= 'string' then return end
    -- 🔒 state 只允许 0（在外）/1（在库）/2（扣押）；其它值会把车卡成任何状态
    state = tonumber(state)
    if state ~= 0 and state ~= 1 and state ~= 2 then return end
    MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = ? WHERE plate = ? AND citizenid = ?', { state, 0, plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('qb-garages:server:UpdateOutsideVehicle', function(plate, vehicleNetID)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(plate) ~= 'string' then return end
    -- 🔒 原来任何玩家都能把任意 (车牌, netID) 塞进 OutsideVehicles：
    --    既能把别人的车标成"在外"，也能劫持 trackVehicle 的坐标。
    local owner = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if owner ~= Player.PlayerData.citizenid then return end
    -- ⚠️ 客户端唯一的调用点传的是 `nil`（存车时通知"这台车不再在外面"）——
    --    这里必须当成**删除**处理，不能当成"非法参数"早退，否则 OutsideVehicles 永远清不掉，
    --    IsSpawnOk 会一直认为车还在外面，玩家存车后再也取不出来。
    if vehicleNetID == nil then
        OutsideVehicles[plate] = nil
        return
    end
    local netId = tonumber(vehicleNetID)
    if not netId then return end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    OutsideVehicles[plate] = { netID = netId, entity = entity }
end)

RegisterNetEvent('qb-garages:server:trackVehicle', function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(plate) ~= 'string' then return end
    -- 🔒 只能追踪自己名下的车（原来任何车牌都能拿到实时坐标）
    local owner = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if owner ~= Player.PlayerData.citizenid then return end
    local vehicleData = OutsideVehicles[plate]
    if vehicleData and DoesEntityExist(vehicleData.entity) then
        TriggerClientEvent('qb-garages:client:trackVehicle', src, GetEntityCoords(vehicleData.entity))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_tracked'), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_tracked'), 'error')
    end
end)

RegisterNetEvent('qb-garages:server:PayDepotPrice', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or type(data.plate) ~= 'string' then return end
    local plate = tostring(data.plate)
    local cashBalance = Player.PlayerData.money['cash']
    local bankBalance = Player.PlayerData.money['bank']
    -- ⚠️ 扣款必须在**同步段**做。原来扣款写在 MySQL.scalar 的回调里，而
    -- `Player.Functions.RemoveMoney` 是 qb-core 的跨资源函数引用 —— 在 oxmysql 的
    -- 异步回调里调用会抛 `Execution of function reference in script host failed`
    -- （同一形态在 2026-11-01 真机的进角色路径上已经复现过一次）。
    -- 修法：把价格取回到本资源线程（await），再走原有的判断与扣款。
    -- 🔒 只认自己名下的车；价格从库里取，不采信客户端。
    -- 口径与资源自身一致：被判"扣押"要么 state=2（警察 /impound*），要么挂着 depotprice
    -- （`Config.AutoRespawn = false` 时 onResourceStart 给所有在外车辆标 500）。只认 state=2
    -- 会在 AutoRespawn 关掉的服务器上让赎车永远失败。
    local row = MySQL.single.await(
        'SELECT depotprice, citizenid, state FROM player_vehicles WHERE plate = ? LIMIT 1', { data.plate })
    if not row then
        feedback(src, 'error', '这辆车不存在或已被转移')
        return
    end
    if row.citizenid ~= Player.PlayerData.citizenid then
        feedback(src, 'error', '这不是你的车')
        return
    end
    local depotPrice = tonumber(row.depotprice)
    local impounded = tonumber(row.state) == 2 or (depotPrice or 0) > 0
    if not impounded then
        feedback(src, 'error', '这辆车没有被扣押')
        return
    end
    if depotPrice and depotPrice > 0 then
        if cashBalance >= depotPrice then
            Player.Functions.RemoveMoney('cash', depotPrice, 'paid-depot')
            feedback(src, 'feed', ('已缴 $%d 取回 %s'):format(depotPrice, plate),
                ('现金余额 $%d'):format(Player.PlayerData.money['cash']))
            TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
        elseif bankBalance >= depotPrice then
            Player.Functions.RemoveMoney('bank', depotPrice, 'paid-depot')
            feedback(src, 'feed', ('已缴 $%d 取回 %s'):format(depotPrice, plate),
                ('银行余额 $%d'):format(Player.PlayerData.money['bank']))
            TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
        else
            local have = math.max(cashBalance, bankBalance)
            feedback(src, 'error', ('取回需要 $%d，你有 $%d，还差 $%d'):format(
                depotPrice, have, math.max(0, depotPrice - have)))
        end
    end
end)

-- House Garages

RegisterNetEvent('qb-garages:server:syncGarage', function(updatedGarages)
    local src = source
    if type(updatedGarages) ~= 'table' then return end

    -- 控制台 / 管理员：整表覆盖（配置类操作）
    if src == 0 or QBCore.Functions.HasPermission(src, 'admin') then
        Config.Garages = updatedGarages
        return
    end

    -- 🔒 普通玩家：**只接受房车条目**，逐条校验后合并。
    --    客户端发的是整张 `Config.Garages`（qb-houses 建房/加载房车时追加 `type = 'house'` 的条目），
    --    所以不能"全拒"—— 全拒会让服务端缺房车条目，`canDeposit` 里
    --    `Config.Garages[garage].houseName` 索引 nil 直接抛错、存车流程中断。
    --    也不能"全收"—— 否则任何玩家都能改公共车库的点位/开关。
    -- 房车点位必须与 qb-houses 里登记的 `houselocations.garage` 一致（50 米内）：
    -- 否则玩家可以给自己的房子塞一个任意坐标的"车库点"，取车时就在那个点生成载具
    -- （服务端只校验"离玩家 100 米内"，等于把生成点搬到他想去的地方）。
    local houses = {}
    for _, row in ipairs(MySQL.query.await('SELECT name, garage FROM houselocations', {}) or {}) do
        if type(row) == 'table' and type(row.name) == 'string' then
            local anchor = nil
            local decoded = nil
            if type(row.garage) == 'string' and row.garage ~= '' then
                local ok, parsed = pcall(json.decode, row.garage)
                if ok then decoded = parsed end
            elseif type(row.garage) == 'table' then
                decoded = row.garage
            end
            if type(decoded) == 'table' then
                local ax, ay, az = tonumber(decoded.x), tonumber(decoded.y), tonumber(decoded.z)
                if ax and ay and az then anchor = { x = ax, y = ay, z = az } end
            end
            houses[row.name] = anchor or false
        end
    end

    local accepted = 0
    for key, entry in pairs(updatedGarages) do
        -- 同名的既有条目如果不是房车，玩家不能顶掉它（否则可以拿"legion"这类公共车库名当 key）
        local existing = Config.Garages[key]
        local collides = existing ~= nil and type(existing) == 'table' and existing.type ~= 'house'
        if not collides and type(key) == 'string' and type(entry) == 'table' and entry.type == 'house'
            and type(entry.label) == 'string' and type(entry.houseName) == 'string'
            and houses[entry.houseName] and type(entry.spawnPoint) == 'table' then
            local point = entry.spawnPoint[1]
            local ptype = type(point)
            if ptype == 'table' or ptype == 'vector3' or ptype == 'vector4' then
                local px, py, pz = tonumber(point.x), tonumber(point.y), tonumber(point.z)
                local anchor = houses[entry.houseName]
                if px and py and pz and anchor then
                    local dx, dy, dz = px - anchor.x, py - anchor.y, pz - anchor.z
                    if math.sqrt(dx * dx + dy * dy + dz * dz) <= 50.0 then
                        Config.Garages[key] = entry
                        accepted = accepted + 1
                    end
                end
            end
        end
    end
    if accepted > 0 then
        print(('[qb-garages] syncGarage: src=%s 合并了 %d 个房车条目'):format(tostring(src), accepted))
    end
end)

--Call from qb-phone

QBCore.Functions.CreateCallback('qb-garages:server:GetPlayerVehicles', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    local Vehicles = {}

    MySQL.query('SELECT * FROM player_vehicles WHERE citizenid = ?', { Player.PlayerData.citizenid }, function(result)
        if result[1] then
            for _, v in pairs(result) do
                local VehicleData = QBCore.Shared.Vehicles[v.vehicle]

                local VehicleGarage = Lang:t('error.no_garage')
                if v.garage ~= nil then
                    if Config.Garages[v.garage] ~= nil then
                        VehicleGarage = Config.Garages[v.garage].label
                    else
                        VehicleGarage = Lang:t('info.house')
                    end
                end

                local stateTranslation
                if v.state == 0 then
                    stateTranslation = Lang:t('status.out')
                elseif v.state == 1 then
                    stateTranslation = Lang:t('status.garaged')
                elseif v.state == 2 then
                    stateTranslation = Lang:t('status.impound')
                end

                local fullname
                if VehicleData and VehicleData['brand'] then
                    fullname = VehicleData['brand'] .. ' ' .. VehicleData['name']
                else
                    fullname = VehicleData and VehicleData['name'] or 'Unknown Vehicle'
                end

                Vehicles[#Vehicles + 1] = {
                    fullname = fullname,
                    brand = VehicleData and VehicleData['brand'] or '',
                    model = VehicleData and VehicleData['name'] or '',
                    plate = v.plate,
                    garage = VehicleGarage,
                    state = stateTranslation,
                    fuel = v.fuel,
                    engine = v.engine,
                    body = v.body
                }
            end
            cb(Vehicles)
        else
            cb(nil)
        end
    end)
end)

local function getAllGarages()
    local garages = {}
    for k, v in pairs(Config.Garages) do
        garages[#garages + 1] = {
            name = k,
            label = v.label,
            type = v.type,
            takeVehicle = v.takeVehicle,
            putVehicle = v.putVehicle,
            spawnPoint = v.spawnPoint,
            showBlip = v.showBlip,
            blipName = v.blipName,
            blipNumber = v.blipNumber,
            blipColor = v.blipColor,
            vehicle = v.vehicle
        }
    end
    return garages
end

exports('getAllGarages', getAllGarages)
