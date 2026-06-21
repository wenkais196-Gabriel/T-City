-- compat.lua — qb-vehiclekeys 向后兼容桥
--
-- 无缝替代 qb-vehiclekeys:
--   1. 暴露相同的 exports: HasKeys / GiveKeys / RemoveKeys
--   2. 监听相同的网络事件: qb-vehiclekeys:server:GiveKeys 等
--   3. 暴露相同的全局回调: QBCore.Functions.OnGiveKeys 等
--
-- 外部脚本（qb-garages / qb-policejob / qb-ambulancejob 等）无需修改

local QBCore = exports['qb-core']:GetCoreObject()

-- 兼容桥开关
local compatEnabled = Config.Vehicles.CompatEnabled
if not compatEnabled then
    print('[custom-vehicles] ⚠️ 兼容桥已禁用 (vehicles_compat_enable=false)')
    return
end

-- ==============================================================
-- 兼容 exports（替代 exports['qb-vehiclekeys']）
-- ==============================================================

--- qb-vehiclekeys 旧版 export: HasKeys(plate)
exports('HasKeys', function(plate)
    local src = source
    if not src or src == 0 then return false end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    local hasKey = KeyManager.HasKeys(plate, Player.PlayerData.citizenid)
    return hasKey
end)

--- qb-vehiclekeys 旧版 export: GiveKeys(id, plate)
exports('GiveKeys', function(id, plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(id or src)
    if not Player then return false end

    return KeyManager.GiveKeys(plate, Player.PlayerData.citizenid, 'shared')
end)

--- qb-vehiclekeys 旧版 export: RemoveKeys(id, plate)
exports('RemoveKeys', function(id, plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(id or src)
    if not Player then return false end

    return KeyManager.RemoveKeys(plate, Player.PlayerData.citizenid)
end)

-- ==============================================================
-- 兼容网络事件
-- ==============================================================

--- qb-vehiclekeys 旧版事件: qb-vehiclekeys:server:GiveKeys
RegisterNetEvent('qb-vehiclekeys:server:GiveKeys', function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    KeyManager.GiveKeys(plate, Player.PlayerData.citizenid, 'shared')

    -- 通知相关客户端
    TriggerClientEvent('custom-vehicles:client:keysUpdated', src, {
        plate = plate,
        hasKeys = true,
    })
end)

--- qb-vehiclekeys 旧版事件: qb-vehiclekeys:server:RemoveKeys
RegisterNetEvent('qb-vehiclekeys:server:RemoveKeys', function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    KeyManager.RemoveKeys(plate, Player.PlayerData.citizenid)
end)

--- qb-vehiclekeys 旧版事件: qb-vehiclekeys:server:AcquireVehicleKeys
RegisterNetEvent('qb-vehiclekeys:server:AcquireVehicleKeys', function(plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 🛡️ 安全: 服务端权威校验
    -- 1. 若车辆已有车主，仅原车主可重新声明所有权
    -- 2. 若车辆无主（新建/刷出），首位声明者获得所有权
    --    └─ 不再校验 GetVehiclePedIsIn — /car 命令在 Warp 前触发 SetOwner，
    --       服务器处理时玩家尚未入车，旧校验会导致 KeyManager 未注册
    local owner = KeyManager.GetOwner(plate)
    if owner and owner ~= Player.PlayerData.citizenid then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('钥匙所有权冒领拦截',
                ('**%s** (%s) | Plate: %s | Owner: %s'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid, plate, owner),
                16711680)
        end
        return
    end

    KeyManager.GiveKeys(plate, Player.PlayerData.citizenid, 'owner')

    -- 立即推送客户端缓存，防止冷缓存导致误锁车门
    TriggerClientEvent(Config.Vehicles.Events.KEYS_UPDATED, src, {
        plate = plate,
        hasKeys = true,
        keyType = 'owner',
    })
end)

--- qb-vehiclekeys 旧版事件: qb-vehiclekeys:server:ToggleEngine
RegisterNetEvent('qb-vehiclekeys:server:ToggleEngine', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local ped = GetPlayerPed(src)
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end

    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    local hasKey = KeyManager.HasKeys(plate, Player.PlayerData.citizenid)

    if hasKey then
        TriggerClientEvent('custom-vehicles:client:engineToggle', src, true)
    end
end)

-- ==============================================================
-- 兼容 QBCore.Functions 回调
-- ==============================================================

-- qb-vehiclekeys 会在玩家加载后通过此回调同步自有车辆钥匙
-- 我们直接注册同名回调，在玩家上线时自动从 player_vehicles 表加载钥匙
if QBCore.Functions.OnGiveKeys then
    -- 如果旧版已注册，我们 hook 进去
    local origOnGiveKeys = QBCore.Functions.OnGiveKeys
    QBCore.Functions.OnGiveKeys = function(citizenid, plate)
        KeyManager.GiveKeys(plate, citizenid, 'owner')
        origOnGiveKeys(citizenid, plate)
    end
else
    -- 新注册
    QBCore.Functions.OnGiveKeys = function(citizenid, plate)
        KeyManager.GiveKeys(plate, citizenid, 'owner')
    end
end

-- ==============================================================
-- 自有车辆自动加载（玩家上线时从 player_vehicles 表同步）
-- ==============================================================

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end

    local citizenid = Player.PlayerData.citizenid

    -- 从 DB 加载玩家的自有车辆
    MySQL.query('SELECT plate FROM player_vehicles WHERE citizenid = ?', {
        citizenid
    }, function(result)
        if not result then return end

        local count = 0
        for _, row in ipairs(result) do
            if row.plate then
                KeyManager.GiveKeys(row.plate, citizenid, 'owner')
                count = count + 1
            end
        end

        if count > 0 then
            -- 🔒 Security: citizenid 脱敏
            local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
            print(('[custom-vehicles] 🔑 Loaded %d owned vehicles for %s'):format(count, maskedCid))
        end

        -- 立即推送钥匙状态到客户端，消除冷缓存窗口
        --（此前依赖客户端 2s 后主动 REQUEST_KEYS，存在误锁风险）
        local keys = KeyManager.GetKeysForCitizen(citizenid)
        if #keys > 0 then
            local src = Player.PlayerData.source
            TriggerClientEvent(Config.Vehicles.Events.KEYS_UPDATED, src, keys)
        end
    end)
end)

-- ==============================================================
-- 玩家下线: 清退临时钥匙 + 清理缓存
-- ==============================================================

AddEventHandler('playerDropped', function(reason)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not Player.PlayerData then return end

    local citizenid = Player.PlayerData.citizenid
    local cleared = KeyManager.ClearTempKeys(citizenid)
    if cleared > 0 then
        -- 🔒 Security: citizenid 脱敏
        local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
        print(('[custom-vehicles] 🗑️ Cleared %d temp keys for offline player %s'):format(cleared, maskedCid))
    end
end)

print('[custom-vehicles] 🔄 向后兼容桥已激活 — qb-vehiclekeys exports/events 全部接管')
