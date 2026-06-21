local QBCore = exports['qb-core']:GetCoreObject()
local PlayerData = {}

-- ==========================================
--  客户端缓存（高性能：内存查询，零 DB 访问）
-- ==========================================

local licenseCache = {}       -- { driver = true, pilot = false, ... }
local certStatusCache = {}    -- { driver = 'held', pilot = 'unclaimed', ... }

--- 刷新本地缓存（从 PlayerData 读取，O(1)）
local function RefreshCache()
    if not PlayerData or not PlayerData.metadata then return end
    local licences = PlayerData.metadata['licences']
    local certStatus = PlayerData.metadata['cert_status']

    if licences then
        licenseCache = licences
    end
    if certStatus then
        certStatusCache = certStatus
    end
end

-- ==========================================
--  Exports（供 qb-garages 等其他资源以 O(1) 客户端速度查询）
-- ==========================================

--- 检查玩家是否持有指定证件
exports('HasLicense', function(certType)
    return licenseCache[certType] == true
end)

--- 获取证件状态字符串
exports('GetLicenseStatus', function(certType)
    return certStatusCache[certType] or 'unclaimed'
end)

--- 获取所有证件状态
exports('GetAllLicenses', function()
    local result = {}
    for certType, config in pairs(Config.CertificateTypes) do
        result[certType] = {
            label = config.label,
            hasAuthority = licenseCache[certType] == true,
            status = certStatusCache[certType] or 'unclaimed',
        }
    end
    return result
end)

--- 根据车辆类别获取所需的证件类型
exports('GetRequiredLicenseForVehicleClass', function(vehicleClass)
    for certType, config in pairs(Config.CertificateTypes) do
        for _, vc in ipairs(config.vehicleClasses) do
            if vc == vehicleClass then
                return certType
            end
        end
    end
    return nil
end)

--- 检查玩家是否可以驾驶指定车辆类别
--- 🔧 P0 修复: 恢复真实校验 — 航空器(15/16)必须持有 pilot 执照且状态为 held
exports('CanDriveVehicleClass', function(vehicleClass)
    local requiredLicense = nil
    for certType, config in pairs(Config.CertificateTypes) do
        for _, vc in ipairs(config.vehicleClasses) do
            if vc == vehicleClass then
                requiredLicense = certType
                break
            end
        end
        if requiredLicense then break end
    end
    -- 无证件要求的车辆类别（如 emergency、military、cycle 等）始终允许
    if not requiredLicense then return true end

    -- 🛡️ 航空器(15=直升机, 16=飞机)强制校验
    if vehicleClass == 15 or vehicleClass == 16 then
        -- 豁免: 警局/医护执勤期间 (方便救援/拦截)
        local jobData = QBCore.Functions.GetPlayerData().job
        if jobData and (jobData.type == 'leo' or jobData.type == 'ems') and jobData.onduty then
            return true
        end
        -- 平民玩家必须持有 pilot 执照且状态为 held
        return licenseCache['pilot'] == true and certStatusCache['pilot'] == 'held'
    end

    -- 其他需要执照的载具类别：允许无证驾驶以方便警察扮演
    return true
end)

-- ==========================================
--  事件处理：数据同步
-- ==========================================

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = QBCore.Functions.GetPlayerData()
    RefreshCache()
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(val)
    PlayerData = val
    RefreshCache()
end)

-- 🔧 强制刷新缓存 —— 服务端发完执照后直接推送，绕开 QBCore 事件链路竞态
RegisterNetEvent('custom-certificates:client:ForceRefreshCache', function()
    PlayerData = QBCore.Functions.GetPlayerData()
    RefreshCache()
end)

-- ==========================================
--  启动
-- ==========================================

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    PlayerData = QBCore.Functions.GetPlayerData()
    RefreshCache()
end)

-- 🔧 P0 修复: 1000ms 慢循环 — 无证平民驾驶航空器时强制切断引擎并踢出
CreateThread(function()
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            if GetPedInVehicleSeat(veh, -1) == ped then
                local vehClass = GetVehicleClass(veh)
                if vehClass == 15 or vehClass == 16 then
                    -- 豁免警医执勤
                    local jobData = QBCore.Functions.GetPlayerData().job
                    local isService = jobData and (jobData.type == 'leo' or jobData.type == 'ems') and jobData.onduty
                    if not isService then
                        local hasLicense = licenseCache['pilot'] == true and certStatusCache['pilot'] == 'held'
                        if not hasLicense then
                            SetVehicleEngineOn(veh, false, true, true)
                            TaskLeaveVehicle(ped, veh, 0)
                            QBCore.Functions.Notify('🚨 警告：你没有飞行执照，系统已强行切断航空器引擎！', 'error', 5000)
                        end
                    end
                end
            end
        end
    end
end)
