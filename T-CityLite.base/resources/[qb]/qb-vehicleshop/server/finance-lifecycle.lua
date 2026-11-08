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

-- 在职车行店员判定（闸门按 net_event_guard_helpers.json 登记的名字核对）
local function dealerOnDuty(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData and Player.PlayerData.job
    if type(job) ~= 'table' then return false end
    return job.name == 'cardealer' and job.onduty == true
end

-- ==============================================================
-- 玩家时长追踪 (分期计时器)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:addPlayer', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 🔒 客户端传的 citizenid 不可信：原来任何玩家都能重置**别人**的分期计时起点，
    --    等于随意延长/压缩别人的扣款倒计时。这里只认调用者自己的。
    local citizenid = Player.PlayerData.citizenid
    financetimer[citizenid] = os.time()
end)

-- ⚡ Performance Fix: 异步化查询，避免在频繁触发的断线事件中阻塞主线程
RegisterNetEvent('qb-vehicleshop:server:removePlayer', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 🔒 同 addPlayer：只结算调用者自己的车
    local citizenid = Player.PlayerData.citizenid
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
    local src = source
    netId = tonumber(netId)
    if not netId then return end
    -- 🔒 原来 `netId` 直接进 `DeleteEntity`：任何玩家都能删掉任何实体（别人的车、NPC、玩家）。
    --    现在只认"本资源为这个玩家生成的试驾车"（`TestDriveVehicles` 记账）。
    if not IsOwnTestDrive(netId, src) then return end
    TestDriveVehicles[netId] = nil
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        DeleteEntity(vehicle)
    end
    -- Phase 5: 清理试驾钥匙 (避免 compat 安全校验拦截下次试驾)
    if plate then
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
    -- 🔒 换展车是店员操作，结果会向**全服**广播：原来任何玩家都能把任意 data 推给所有客户端
    --    （改别人的展车、伪造车型）。
    if not dealerOnDuty(src) then return end
    if type(data) ~= 'table' or type(data.toVehicle) ~= 'string' then return end
    TriggerClientEvent('qb-vehicleshop:client:swapVehicle', -1, data)
    Wait(1500)                                                -- 等新车生成
    TriggerClientEvent('qb-vehicleshop:client:homeMenu', src) -- 重开菜单
end)

-- 员工发送试驾
RegisterNetEvent('qb-vehicleshop:server:customTestDrive', function(vehicle, playerid)
    local src    = source
    -- 🔒 员工给顾客发试驾：原来任何玩家都能给任意人发**任意车型**（含警车/飞机），
    --    配合 3 米距离校验就能免费开走任何载具。
    if not dealerOnDuty(src) then return end
    if type(vehicle) ~= 'string' then return end
    local inShowroom = false
    for _, shop in pairs(Config.Shops) do
        for _, entry in pairs(shop['ShowroomVehicles'] or {}) do
            if type(entry) == 'table' and entry.chosenVehicle == vehicle then inShowroom = true end
        end
    end
    if not inShowroom then return end
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

local financeCheckedAt = {}

RegisterNetEvent('qb-vehicleshop:server:checkFinance', function()
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    -- 🔒 原来 `player` 为 nil 时直接索引 `player.PlayerData` 会抛错；而且这个 handler 里
    --    有 `Wait(Config.PaymentWarning * 60000)`，连点会堆出一串睡眠线程。
    if not player then return end
    local now = os.time()
    if financeCheckedAt[src] and (now - financeCheckedAt[src]) < 600 then return end
    financeCheckedAt[src] = now
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
