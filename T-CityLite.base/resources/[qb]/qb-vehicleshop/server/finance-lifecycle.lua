-- finance-lifecycle.lua — 玩家生命周期与车辆操作
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
-- Phase 2: 从 finance.lua 拆分
--
-- 职责:
--   1. 玩家在线时长追踪 (addPlayer / removePlayer / playerDropped)
--   2. 车辆操作事件 (deleteVehicle / swapVehicle / customTestDrive)
--   3. 逾期检查与回收 (checkFinance)

local QBCore   = exports['qb-core']:GetCoreObject()
local shopUtil = _G._vehicleshop
local financetimer = {}

-- ==============================================================
-- 玩家时长追踪 (分期计时器)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:addPlayer', function(citizenid)
    financetimer[citizenid] = os.time()
end)

-- ⚡ Performance Fix: 异步化查询，避免在频繁触发的断线事件中阻塞主线程
RegisterNetEvent('qb-vehicleshop:server:removePlayer', function(citizenid)
    if not financetimer[citizenid] then return end
    local playTime = financetimer[citizenid]
    MySQL.query('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenid }, function(financetime)
        if financetime then
            for _, v in pairs(financetime) do
                if v.balance >= 1 then
                    local newTime = (v.financetime - ((os.time() - playTime) / 60))
                    if newTime < 0 then newTime = 0 end
                    MySQL.update('UPDATE player_vehicles SET financetime = ? WHERE plate = ?',
                        { math.ceil(newTime), v.plate })
                end
            end
        end
    end)
    financetimer[citizenid] = nil
end)

-- ⚡ Performance Fix: 异步化查询，避免 playerDropped 阻塞事件循环
AddEventHandler('playerDropped', function()
    local src = source
    local license
    for _, v in pairs(GetPlayerIdentifiers(src)) do
        if string.sub(v, 1, string.len('license:')) == 'license:' then
            license = v
        end
    end
    if license then
        MySQL.query('SELECT * FROM player_vehicles WHERE license = ?', { license }, function(vehicles)
            if vehicles then
                for _, v in pairs(vehicles) do
                    local playTime = financetimer[v.citizenid]
                    if v.balance >= 1 and playTime then
                        local newTime = (v.financetime - ((os.time() - playTime) / 60))
                        if newTime < 0 then newTime = 0 end
                        MySQL.update('UPDATE player_vehicles SET financetime = ? WHERE plate = ?',
                            { math.ceil(newTime), v.plate })
                    end
                end
                if vehicles[1] and financetimer[vehicles[1].citizenid] then
                    financetimer[vehicles[1].citizenid] = nil
                end
            end
        end)
    end
end)

-- ==============================================================
-- 车辆操作事件
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:deleteVehicle', function(netId, plate)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    DeleteEntity(vehicle)
    -- Phase 5: 清理试驾钥匙 (避免 compat 安全校验拦截下次试驾)
    if plate then
        local src = source
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            pcall(function()
                exports['custom-vehicles']:RemoveKeys(plate, Player.PlayerData.citizenid)
            end)
        end
    end
end)

-- 同步展车切换
RegisterNetEvent('qb-vehicleshop:server:swapVehicle', function(data)
    local src = source
    TriggerClientEvent('qb-vehicleshop:client:swapVehicle', -1, data)
    Wait(1500)                                                -- 等新车生成
    TriggerClientEvent('qb-vehicleshop:client:homeMenu', src) -- 重开菜单
end)

-- 员工发送试驾
RegisterNetEvent('qb-vehicleshop:server:customTestDrive', function(vehicle, playerid)
    local src    = source
    local target = tonumber(playerid)
    if not QBCore.Functions.GetPlayer(target) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target))) < 3 then
        TriggerClientEvent('qb-vehicleshop:client:customTestDrive', target, vehicle)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
    end
end)

-- ==============================================================
-- 逾期检查 (玩家登录时触发)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:checkFinance', function()
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    local query  = 'SELECT * FROM player_vehicles WHERE citizenid = ? AND balance > 0 AND financetime < 1'
    local result = MySQL.query.await(query, { player.PlayerData.citizenid })

    if result[1] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('general.paymentduein', { time = Config.PaymentWarning }))
        Wait(Config.PaymentWarning * 60000)
        local vehicles = MySQL.query.await(query, { player.PlayerData.citizenid })
        for _, v in pairs(vehicles) do
            MySQL.query('DELETE FROM player_vehicles WHERE plate = @plate', { ['@plate'] = v.plate })
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.repossessed', { plate = v.plate }), 'error')
        end
    end
end)

print('[qb-vehicleshop] ⏱️  生命周期模块已加载 (finance-lifecycle.lua)')
