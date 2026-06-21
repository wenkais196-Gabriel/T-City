-- main.lua — custom-vehicles 服务端入口
--
-- 职责:
--   1. 网络事件处理（钥匙请求 / 热线发动 / 撬锁 / 引擎/锁控制）
--   2. 注册 exports（11 个对外接口）
--   3. 注册到 core-framework Bus
--   4. 安全校验（物理距离 / Rate Limit / 背包物品检查）

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- Rate Limit 追踪
-- ==============================================================

local rateLimits = {} -- [src] = { hotwire = timestamp, lockpick = timestamp }

local function checkRateLimit(src, action)
    local now = os.clock() * 1000
    if not rateLimits[src] then rateLimits[src] = {} end
    local last = rateLimits[src][action] or 0
    local limit = Config.Vehicles.Security.RateLimitMs
    if now - last < limit then return false end
    rateLimits[src][action] = now
    return true
end

-- ==============================================================
-- 事件: 请求钥匙状态（客户端查询自己的钥匙列表）
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.REQUEST_KEYS, function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local keys = KeyManager.GetKeysForCitizen(Player.PlayerData.citizenid)
    TriggerClientEvent(Config.Vehicles.Events.KEYS_UPDATED, src, keys)
end)

-- ==============================================================
-- 事件: 授予钥匙
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.GIVE_KEYS, function(plate, targetId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    if not plate then return end

    -- 只有车主可以授予他人钥匙
    local owner = KeyManager.GetOwner(plate)
    if owner and owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, '你不是车主，无法授予钥匙', 'error')
        return
    end

    local targetPlayer = QBCore.Functions.GetPlayer(targetId)
    if not targetPlayer then
        TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error')
        return
    end

    KeyManager.GiveKeys(plate, targetPlayer.PlayerData.citizenid, 'shared')

    TriggerClientEvent('QBCore:Notify', src, ('已将 [%s] 的钥匙分享给 %s'):format(plate, targetPlayer.PlayerData.charinfo.firstname), 'success')
    TriggerClientEvent('QBCore:Notify', targetId, ('%s 与你分享了车辆 [%s] 的钥匙'):format(Player.PlayerData.charinfo.firstname, plate), 'success')

    -- 通知相关客户端更新
    TriggerClientEvent(Config.Vehicles.Events.KEYS_UPDATED, targetId, { plate = plate, hasKeys = true })
end)

-- ==============================================================
-- 事件: 移除钥匙
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.REMOVE_KEYS, function(plate, targetId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    if not plate then return end

    local targetCitizenid
    if targetId then
        local targetPlayer = QBCore.Functions.GetPlayer(targetId)
        if targetPlayer then
            targetCitizenid = targetPlayer.PlayerData.citizenid
        end
    end

    -- 如果未指定目标，移除自己的钥匙
    local removeCid = targetCitizenid or Player.PlayerData.citizenid

    -- 不能移除车主的钥匙
    local owner = KeyManager.GetOwner(plate)
    if owner == removeCid and removeCid ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, '无法移除车主的钥匙', 'error')
        return
    end

    KeyManager.RemoveKeys(plate, removeCid)

    TriggerClientEvent('QBCore:Notify', src, '钥匙已移除', 'success')
end)

-- ==============================================================
-- 事件: 检查钥匙（客户端拉取单个车辆状态）
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.CHECK_KEYS, function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local hasKey, keyType = KeyManager.HasKeys(plate, Player.PlayerData.citizenid)
    TriggerClientEvent(Config.Vehicles.Events.KEYS_UPDATED, src, {
        plate = plate,
        hasKeys = hasKey,
        keyType = keyType,
    })
end)

-- ==============================================================
-- 事件: 热线发动（Hotwire）
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.HOTWIRE_ATTEMPT, function(vehNetId, vehClass)
    local src = source

    -- Rate Limit
    if not checkRateLimit(src, 'hotwire') then
        TriggerClientEvent('QBCore:Notify', src, '请等待后再尝试', 'error')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 验证车辆存在
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if not veh or veh == 0 then
        TriggerClientEvent('QBCore:Notify', src, '车辆不存在', 'error')
        return
    end

    -- 2. 物理距离校验
    local ped = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(ped)
    local vehCoords = GetEntityCoords(veh)
    local dist = #(playerCoords - vehCoords)
    if dist > Config.Vehicles.Security.MaxInteractionDistance then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('热线发动距离异常',
                ('**%s** (%s) | Dist: %.1fm | NetID: %d'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid, dist, vehNetId),
                16711680)
        end
        return
    end

    -- 3. 检查玩家是否已有钥匙
    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    local hasKey = KeyManager.HasKeys(plate, Player.PlayerData.citizenid)
    if hasKey then
        TriggerClientEvent('QBCore:Notify', src, '你已经有这辆车的钥匙', 'error')
        return
    end

    -- 4. 概率判定
    local chance = Config.Vehicles.Security.HotwireSuccessChance
    local roll = math.random(1, 100)

    if roll <= chance then
        -- ✅ 热线成功: 授钥 + 清除 lockpicked (车辆进入正常驾驶状态)
        KeyManager.GiveKeys(plate, Player.PlayerData.citizenid, 'temp')
        Entity(veh).state.lockpicked = nil
        TriggerClientEvent('custom-vehicles:client:setStolen', -1, vehNetId, true)
        Entity(veh).state.isStolen = true
        TriggerClientEvent(Config.Vehicles.Events.KEYS_UPDATED, src, {
            plate = plate, hasKeys = true, keyType = 'temp',
        })

        local alarmRoll = math.random(1, 100)
        local alarmThreshold = (vehClass == 18) and 100 or Config.Vehicles.Security.AlarmChance
        if alarmRoll <= alarmThreshold then
            TriggerEvent('police:server:autoAlert', vehCoords, ('🚨 车辆热线发动: %s'):format(plate))
        end

        TriggerClientEvent('QBCore:Notify', src, '热线发动成功！引擎已解锁', 'success')
    else
        -- 失败
        TriggerClientEvent('QBCore:Notify', src, '热线发动失败，触发了防盗系统', 'error')
        -- 热线失败 100% 报警
        TriggerEvent('police:server:autoAlert', vehCoords, ('🚨 热线发动失败: %s'):format(plate))
        -- 锁死车辆
        TriggerClientEvent('custom-vehicles:client:setDoorLock', src, vehNetId, 2)

        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('热线发动失败',
                ('**%s** (%s) | Plate: %s | Dist: %.1fm'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid, plate, dist),
                16744576)
        end
    end
end)

-- ==============================================================
-- 事件: 撬锁（Lockpick）
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.LOCKPICK_ATTEMPT, function(vehNetId, vehClass)
    local src = source

    -- Rate Limit
    if not checkRateLimit(src, 'lockpick') then
        TriggerClientEvent('QBCore:Notify', src, '请等待后再尝试', 'error')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 验证车辆存在
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if not veh or veh == 0 then
        TriggerClientEvent('QBCore:Notify', src, '车辆不存在', 'error')
        return
    end

    -- 2. 物理距离校验
    local ped = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(ped)
    local vehCoords = GetEntityCoords(veh)
    local dist = #(playerCoords - vehCoords)
    if dist > Config.Vehicles.Security.MaxInteractionDistance then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('撬锁距离异常',
                ('**%s** (%s) | Dist: %.1fm'):format(GetPlayerName(src), Player.PlayerData.citizenid, dist),
                16711680)
        end
        return
    end

    -- 3. 验证玩家背包中有 lockpick
    local hasLockpick = false
    if exports['qb-inventory'] and exports['qb-inventory'].GetItemCount then
        hasLockpick = exports['qb-inventory']:GetItemCount(src, 'lockpick') > 0
    else
        local items = Player.PlayerData.items or {}
        for _, item in ipairs(items) do
            if item.name == 'lockpick' then
                hasLockpick = true
                break
            end
        end
    end

    if not hasLockpick then
        TriggerClientEvent('QBCore:Notify', src, '你需要撬锁工具', 'error')
        return
    end

    -- 4. 概率判定
    local chance = Config.Vehicles.Security.LockpickSuccessChance
    local roll = math.random(1, 100)

    if roll <= chance then
        -- ✅ 撬锁成功: 解锁 + 标记 lockpicked + isStolen，不给钥匙
        local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
        Entity(veh).state.lockpicked = true
        Entity(veh).state.isStolen = true
        TriggerClientEvent('custom-vehicles:client:setDoorLock', src, vehNetId, 0)
        TriggerClientEvent('custom-vehicles:client:setStolen', -1, vehNetId, true)
        TriggerClientEvent('QBCore:Notify', src, '车门已撬开 — 需热线发动引擎', 'success')
    else
        -- 失败: 消耗撬锁工具，触发警报
        if exports['qb-inventory'] and exports['qb-inventory'].RemoveItem then
            exports['qb-inventory']:RemoveItem(src, 'lockpick', 1)
        else
            Player.Functions.RemoveItem('lockpick', 1)
        end

        TriggerClientEvent('QBCore:Notify', src, '撬锁工具断裂！', 'error')

        -- 触发警报
        local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
        local alarmRoll = math.random(1, 100)
        local alarmThreshold = (vehClass == 18) and 100 or Config.Vehicles.Security.AlarmChance
        if alarmRoll <= alarmThreshold then
            TriggerEvent('police:server:autoAlert', vehCoords, ('🚨 撬锁失败: %s'):format(plate))
        end

        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('撬锁失败',
                ('**%s** (%s) | Plate: %s'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid, plate),
                16744576)
        end
    end
end)

-- ==============================================================
-- Exports
-- ==============================================================

exports('GiveKeys', function(plate, citizenid)
    return KeyManager.GiveKeys(plate, citizenid, 'shared')
end)
exports('RemoveKeys', function(plate, citizenid)
    return KeyManager.RemoveKeys(plate, citizenid)
end)
exports('HasKeys', function(plate, citizenid)
    return KeyManager.HasKeys(plate, citizenid)
end)
exports('GiveTempKeys', function(plate, citizenid)
    return KeyManager.GiveTempKeys(plate, citizenid)
end)
exports('GetOwner', function(plate)
    return KeyManager.GetOwner(plate)
end)
exports('SetOwner', function(plate, citizenid)
    return KeyManager.SetOwner(plate, citizenid)
end)
exports('GetKeyHolders', function(plate)
    return KeyManager.GetKeyHolders(plate)
end)
exports('ClearTempKeys', function(citizenid)
    return KeyManager.ClearTempKeys(citizenid)
end)
exports('KeyManagerStats', function()
    return KeyManager.Stats()
end)

-- ==============================================================
-- 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('vehicles', {
        GiveKeys      = KeyManager.GiveKeys,
        RemoveKeys    = KeyManager.RemoveKeys,
        HasKeys       = KeyManager.HasKeys,
        GiveTempKeys  = KeyManager.GiveTempKeys,
        GetOwner      = KeyManager.GetOwner,
        SetOwner      = KeyManager.SetOwner,
        GetKeyHolders = KeyManager.GetKeyHolders,
        ClearTempKeys = KeyManager.ClearTempKeys,
        Stats         = KeyManager.Stats,
    })
end

-- ==============================================================
-- v0.8: 中控屏排他锁 + 驾驶模式服务端权威
-- ==============================================================

local dashboardLocks = {}  -- [plate] = citizenid

--- 请求打开中控屏: 检查是否有其他人占用
RegisterNetEvent('custom-vehicles:server:requestDashboard', function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not plate then
        TriggerClientEvent('custom-vehicles:client:dashboardLockResult', src, false, '系统错误')
        return
    end

    local citizenid = Player.PlayerData.citizenid
    local currentHolder = dashboardLocks[plate]

    -- 自己可以重新打开（关闭后立即重开）
    if currentHolder and currentHolder ~= citizenid then
        TriggerClientEvent('custom-vehicles:client:dashboardLockResult', src, false,
            '中控屏正被车内另一位乘员使用中，请稍后再试')
        return
    end

    -- 获取锁
    dashboardLocks[plate] = citizenid
    TriggerClientEvent('custom-vehicles:client:dashboardLockResult', src, true, nil)
end)

--- 释放中控屏锁
RegisterNetEvent('custom-vehicles:server:releaseDashboard', function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not plate then return end

    local citizenid = Player.PlayerData.citizenid
    if dashboardLocks[plate] == citizenid then
        dashboardLocks[plate] = nil
    end
end)

--- 驾驶模式切换 (服务端广播给车内所有人)
RegisterNetEvent('custom-vehicles:server:setDriveMode', function(vehNetId, mode)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if not veh or veh == 0 then return end

    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()

    -- 只有持有中控屏锁的人可以切换模式
    if dashboardLocks[plate] ~= citizenid then
        TriggerClientEvent('QBCore:Notify', src, '你没有中控屏操作权限', 'error')
        return
    end

    -- 广播模式变更给所有客户端, 各自检查是否在目标车内
    TriggerClientEvent('custom-vehicles:client:applyDriveMode', -1, vehNetId, mode)
end)

-- 玩家掉线 → 释放其持有的所有中控屏锁
AddEventHandler('playerDropped', function(reason)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not Player.PlayerData then return end

    local citizenid = Player.PlayerData.citizenid
    for plate, holder in pairs(dashboardLocks) do
        if holder == citizenid then
            dashboardLocks[plate] = nil
        end
    end
end)

print('[custom-vehicles] 🚗 载具钥匙系统已启动 (v0.8)')
print('[custom-vehicles]   Exports: GiveKeys, RemoveKeys, HasKeys, GiveTempKeys, GetOwner, SetOwner, GetKeyHolders, ClearTempKeys, KeyManagerStats')
print('[custom-vehicles]   Compat: qb-vehiclekeys 旧版 exports/events 全部桥接')
print('[custom-vehicles]   Bus: service_vehicles_* 可用')
