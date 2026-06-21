local QBCore = exports['qb-core']:GetCoreObject()

-- ==========================================
--  内部辅助函数
-- ==========================================

--- 获取玩家的 cert_status 表（深拷贝避免直接引用）
local function GetCertStatus(player)
    if not player or not player.PlayerData or not player.PlayerData.metadata then
        return nil
    end
    return player.PlayerData.metadata['cert_status']
end

--- 获取玩家的 licences 表
local function GetLicences(player)
    if not player or not player.PlayerData or not player.PlayerData.metadata then
        return nil
    end
    return player.PlayerData.metadata['licences']
end

--- 验证证件类型是否合法
local function IsValidCertType(certType)
    return Config.CertificateTypes[certType] ~= nil
end

--- 生成序列号
local function GenerateSerial(player, certType)
    return Config.GenerateSerial(player.PlayerData.citizenid, certType)
end

-- ==========================================
--  核心 API：证件状态管理（服务端权威）
-- ==========================================

--- 设置证件状态（内部核心函数）
--- @param source number 玩家 source ID
--- @param certType string 证件类型
--- @param newStatus string 新状态: 'unclaimed' | 'held' | 'suspended' | 'revoked'
--- @return boolean success
--- @return string message
local function SetLicenseStatus(source, certType, newStatus)
    if not IsValidCertType(certType) then
        return false, ('invalid certificate type: %s'):format(certType)
    end

    local validStatuses = { unclaimed = true, held = true, suspended = true, revoked = true }
    if not validStatuses[newStatus] then
        return false, ('invalid status: %s'):format(newStatus)
    end

    local player = QBCore.Functions.GetPlayer(source)
    if not player then
        return false, 'player not found'
    end

    local certStatus = GetCertStatus(player)
    local licences = GetLicences(player)

    if not certStatus or not licences then
        return false, 'player metadata not available'
    end

    -- 更新状态
    certStatus[certType] = newStatus

    -- 同步 licences boolean 标志（向后兼容）
    if newStatus == 'held' then
        licences[certType] = true
    elseif newStatus == 'suspended' or newStatus == 'revoked' or newStatus == 'unclaimed' then
        licences[certType] = false
    end

    -- 持久化元数据
    player.Functions.SetMetaData('cert_status', certStatus)
    player.Functions.SetMetaData('licences', licences)

    return true, ('license %s status set to %s'):format(certType, newStatus)
end

--- 授予证件（设置 held 状态 + licences 标志）
--- @param source number
--- @param certType string
--- @return boolean success
--- @return string message
local function GrantLicense(source, certType)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false, 'player not found' end

    local certStatus = GetCertStatus(player)
    if not certStatus then return false, 'metadata not available' end

    local currentStatus = certStatus[certType] or 'unclaimed'
    if currentStatus == 'held' then
        return false, ('player already holds %s license'):format(certType)
    end

    return SetLicenseStatus(source, certType, 'held')
end

--- 吊销证件
local function RevokeLicense(source, certType)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false, 'player not found' end

    -- 移除实体证件物品
    local certConfig = Config.CertificateTypes[certType]
    if certConfig and certConfig.item then
        local items = player.PlayerData.items
        if items then
            for _, item in pairs(items) do
                if item and item.name == certConfig.item then
                    exports['qb-inventory']:RemoveItem(source, certConfig.item, 1, false, item.slot,
                        'certificates:revokeLicense')
                    break
                end
            end
        end
    end

    return SetLicenseStatus(source, certType, 'revoked')
end

--- 暂停证件
local function SuspendLicense(source, certType)
    return SetLicenseStatus(source, certType, 'suspended')
end

--- 恢复证件（从暂停/吊销恢复）
local function ReinstateLicense(source, certType)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false, 'player not found' end

    local certStatus = GetCertStatus(player)
    if not certStatus then return false, 'metadata not available' end

    local currentStatus = certStatus[certType] or 'unclaimed'
    if currentStatus ~= 'suspended' and currentStatus ~= 'revoked' then
        return false, ('license %s is not suspended or revoked (current: %s)'):format(certType, currentStatus)
    end

    return SetLicenseStatus(source, certType, 'held')
end

--- 发放实体证件物品（市政厅申领）
--- @param source number
--- @param certType string
--- @return boolean success
--- @return string message
local function IssueCertificate(source, certType)
    if not IsValidCertType(certType) then
        return false, ('invalid certificate type: %s'):format(certType)
    end
    if certType == 'weapon' then
        -- weaponlicense 走旧的市政厅逻辑
        return false, 'weapon license uses legacy cityhall flow'
    end

    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false, 'player not found' end

    local licences = GetLicences(player)
    if not licences or not licences[certType] then
        return false, ('you do not have %s authority — contact police or career system'):format(certType)
    end

    local certStatus = GetCertStatus(player)
    if not certStatus then return false, 'metadata not available' end

    local status = certStatus[certType] or 'unclaimed'
    if status == 'suspended' then
        return false, ('your %s is suspended — cannot issue certificate'):format(certType)
    end
    if status == 'revoked' then
        return false, ('your %s is revoked — cannot issue certificate'):format(certType)
    end

    local certConfig = Config.CertificateTypes[certType]
    local itemName = certConfig.item

    -- 检查背包是否已有实体证件
    local hasPhysical = false
    local items = player.PlayerData.items
    if items then
        for _, item in pairs(items) do
            if item and item.name == itemName then
                hasPhysical = true
                break
            end
        end
    end

    if hasPhysical then
        return false, ('you already have your %s certificate in your inventory'):format(certConfig.label)
    end

    -- 扣费 (routes through Player.Functions → EconomyService bridge → DirtyFlush + events)
    local cost = certConfig.cost
    if not player.Functions.RemoveMoney('cash', cost, ('certificate-%s'):format(certType)) then
        return false, ('you need $%s cash to issue the certificate'):format(cost)
    end

    -- 生成序列号并发放物品
    local serial = GenerateSerial(player, certType)
    local info = {
        firstname = player.PlayerData.charinfo.firstname,
        lastname = player.PlayerData.charinfo.lastname,
        birthdate = player.PlayerData.charinfo.birthdate,
        citizenid = player.PlayerData.citizenid,
        serial = serial,
        type = certConfig.label,
        certType = certType,
    }

    local added = exports['qb-inventory']:AddItem(source, itemName, 1, false, info,
        ('certificates:issueCertificate:%s'):format(certType))
    if not added then
        -- 退款
        player.Functions.AddMoney('cash', cost, 'certificate-refund')
        return false, 'failed to add certificate item — $%s refunded'
    end

    -- 如果之前是 unclaimed，更新状态为 held
    if status == 'unclaimed' then
        SetLicenseStatus(source, certType, 'held')
    end

    TriggerClientEvent('qb-inventory:client:ItemBox', source, QBCore.Shared.Items[itemName], 'add')
    TriggerClientEvent('QBCore:Notify', source,
        ('You have received your %s (Serial: %s) for $%s'):format(certConfig.label, serial, cost), 'success', 5000)

    return true, serial
end

-- ==========================================
--  Exports（供其他资源调用）
-- ==========================================

exports('GetLicenseStatus', function(source, certType)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return nil end
    local certStatus = GetCertStatus(player)
    if not certStatus then return nil end
    return certStatus[certType]
end)

exports('HasLicense', function(source, certType)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false end
    local licences = GetLicences(player)
    if not licences then return false end
    return licences[certType] == true
end)

exports('GetCertificateSerial', function(source, certType)
    -- 序列号在实体物品的 info 里，这里返回计算值
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return nil end
    local licences = GetLicences(player)
    if not licences or not licences[certType] then return nil end
    return Config.GenerateSerial(player.PlayerData.citizenid, certType)
end)

exports('SetLicenseStatus', SetLicenseStatus)
exports('GrantLicense', GrantLicense)
exports('RevokeLicense', RevokeLicense)
exports('SuspendLicense', SuspendLicense)
exports('ReinstateLicense', ReinstateLicense)
exports('IssueCertificate', IssueCertificate)
exports('GetVehicleLicenseMap', function()
    local map = {}
    for certType, config in pairs(Config.CertificateTypes) do
        for _, vc in ipairs(config.vehicleClasses) do
            map[vc] = certType
        end
    end
    return map
end)

-- ==========================================
--  网络事件（供 qb-menu / police / career 调用）
-- ==========================================

RegisterNetEvent('certificates:server:IssueCertificate', function(certType)
    local src = source
    local success, msg = IssueCertificate(src, certType)
    if not success then
        TriggerClientEvent('QBCore:Notify', src, msg, 'error', 5000)
    end
end)

RegisterNetEvent('certificates:server:GrantLicense', function(targetId, certType)
    local src = source
    -- 🛡️ Security: 权限检查 — 仅警察/法官/管理员可授予证件
    local caller = QBCore.Functions.GetPlayer(src)
    if not caller then return end
    local callerJob = caller.PlayerData.job.name
    local isAdmin = QBCore.Functions.HasPermission(src, 'admin')
    if callerJob ~= 'police' and callerJob ~= 'judge' and not isAdmin then
        print(('[SECURITY] certificates:server:GrantLicense blocked — unauthorized caller %s (job=%s)'):format(GetPlayerName(src), callerJob))
        return
    end
    local success, msg = GrantLicense(tonumber(targetId), certType)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('Granted %s license to player %s'):format(certType, targetId),
            'success', 5000)
    else
        TriggerClientEvent('QBCore:Notify', src, msg, 'error', 5000)
    end
end)

RegisterNetEvent('certificates:server:RevokeLicense', function(targetId, certType)
    local src = source
    -- 🛡️ Security: 权限检查
    local caller = QBCore.Functions.GetPlayer(src)
    if not caller then return end
    local callerJob = caller.PlayerData.job.name
    local isAdmin = QBCore.Functions.HasPermission(src, 'admin')
    if callerJob ~= 'police' and callerJob ~= 'judge' and not isAdmin then return end
    local success, msg = RevokeLicense(tonumber(targetId), certType)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('Revoked %s license from player %s'):format(certType, targetId),
            'success', 5000)
    else
        TriggerClientEvent('QBCore:Notify', src, msg, 'error', 5000)
    end
end)

RegisterNetEvent('certificates:server:SuspendLicense', function(targetId, certType)
    local src = source
    -- 🛡️ Security: 权限检查
    local caller = QBCore.Functions.GetPlayer(src)
    if not caller then return end
    local callerJob = caller.PlayerData.job.name
    local isAdmin = QBCore.Functions.HasPermission(src, 'admin')
    if callerJob ~= 'police' and callerJob ~= 'judge' and not isAdmin then return end
    local success, msg = SuspendLicense(tonumber(targetId), certType)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('Suspended %s license for player %s'):format(certType, targetId),
            'success', 5000)
    else
        TriggerClientEvent('QBCore:Notify', src, msg, 'error', 5000)
    end
end)

RegisterNetEvent('certificates:server:ReinstateLicense', function(targetId, certType)
    local src = source
    -- 🛡️ Security: 权限检查
    local caller = QBCore.Functions.GetPlayer(src)
    if not caller then return end
    local callerJob = caller.PlayerData.job.name
    local isAdmin = QBCore.Functions.HasPermission(src, 'admin')
    if callerJob ~= 'police' and callerJob ~= 'judge' and not isAdmin then return end
    local success, msg = ReinstateLicense(tonumber(targetId), certType)
    if success then
        TriggerClientEvent('QBCore:Notify', src, ('Reinstated %s license for player %s'):format(certType, targetId),
            'success', 5000)
    else
        TriggerClientEvent('QBCore:Notify', src, msg, 'error', 5000)
    end
end)

-- ==========================================
--  回调（供客户端查询）
-- ==========================================

QBCore.Functions.CreateCallback('certificates:server:GetPlayerLicenses', function(source, cb)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return cb({}) end

    local licences = GetLicences(player)
    local certStatus = GetCertStatus(player)
    local result = {}

    for certType, config in pairs(Config.CertificateTypes) do
        result[certType] = {
            label = config.label,
            hasAuthority = licences and licences[certType] == true or false,
            status = certStatus and certStatus[certType] or 'unclaimed',
            cost = config.cost,
            item = config.item,
        }
    end

    cb(result)
end)

-- ==========================================
--  启动日志
-- ==========================================

print('[custom-certificates] Certificate License System loaded successfully')
print('[custom-certificates] Registered types: driver, pilot, boat, heavy, weapon')
print('[custom-certificates] Exports: GetLicenseStatus, HasLicense, GetCertificateSerial, SetLicenseStatus, GrantLicense, RevokeLicense, SuspendLicense, ReinstateLicense, IssueCertificate')
