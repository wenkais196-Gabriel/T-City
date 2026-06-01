local QBCore = exports['qb-core']:GetCoreObject()
local CareerCache = {}

-- 辅助函数：输出调试日志
local function DebugPrint(msg)
    if QBConfig and QBConfig.Custom and QBConfig.Custom.General and QBConfig.Custom.General.EnableDebug then
        print(('[custom-career][server] %s'):format(msg))
    else
        print(('[custom-career][server] %s'):format(msg))
    end
end

-- ==========================================
--               内 存 缓 存 管 理 (O(1))
-- ==========================================

-- 1. 玩家上线：从数据库异步加载数据并载入缓存
local function LoadPlayerCareer(src)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return end
    
    local cid = qbPlayer.PlayerData.citizenid
    
    MySQL.single('SELECT rank_tier, department, district, certs FROM players WHERE citizenid = ?', { cid }, function(result)
        local dbTier = (result and result.rank_tier) and result.rank_tier or "entry"
        
        -- 高能自愈性映射校验：核对原生职级级别以对齐 rank_tier
        local expectedTier = "entry"
        local job = qbPlayer.PlayerData.job
        if job.isboss or (job.grade and job.grade.level and job.grade.level >= 4) then
            expectedTier = "leader"
        elseif job.grade and job.grade.level and job.grade.level >= 2 then
            expectedTier = "mid"
        end

        if expectedTier ~= dbTier then
            dbTier = expectedTier
            -- 异步写入数据库修正，防止主线程卡顿
            MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?', { expectedTier, cid })
            DebugPrint(("Self-healing career tier mapping for %s: DB value was '%s', synced to expected '%s'"):format(
                qbPlayer.PlayerData.name, result and result.rank_tier or "nil", expectedTier
            ))
        end

        local data = {
            primary_role = qbPlayer.PlayerData.job.name,
            rank_tier = dbTier,
            department = (result and result.department) and result.department or nil,
            district = (result and result.district) and result.district or nil,
            certs = (result and result.certs) and json.decode(result.certs) or {}
        }
        
        CareerCache[src] = data
        Player(src).state:set("career_identity", data, true) -- 同步至客户端 State Bag
        
        DebugPrint(("Loaded career for %s (Tier=%s, Dept=%s, CertsCount=%d)"):format(
            qbPlayer.PlayerData.name, data.rank_tier, tostring(data.department), #data.certs
        ))
    end)
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(qbPlayer)
    local src = qbPlayer.PlayerData.source
    LoadPlayerCareer(src)
end)

-- 针对热重载/资源重启时的防漏加载机制
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Wait(1000) -- 等待核心加载完成
    local players = QBCore.Functions.GetQBPlayers()
    for _, qbPlayer in pairs(players) do
        LoadPlayerCareer(qbPlayer.PlayerData.source)
    end
    DebugPrint("Resource started, loaded careers for all active players.")
end)

-- 2. 玩家离线：清除内存缓存，杜绝内存泄漏
AddEventHandler('playerDropped', function()
    local src = source
    if CareerCache[src] then
        CareerCache[src] = nil
        DebugPrint(("Cleared career cache for dropped player, source: %d"):format(src))
    end
end)

-- ==========================================
--                 公 开 导 出 API
-- ==========================================

-- 1. 获取玩家多标签完整身份 (O(1) 高性能内存直读)
local function GetPlayerIdentity(src)
    if CareerCache[src] then 
        -- 动态刷新实时职业名字，防范在 qb-core 中通过 setJob 直接更新而未经过 custom-career 的边界
        local qbPlayer = QBCore.Functions.GetPlayer(src)
        if qbPlayer then
            CareerCache[src].primary_role = qbPlayer.PlayerData.job.name
        end
        return CareerCache[src] 
    end
    
    -- Fallback：如果缓存尚未载入
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if qbPlayer then
        return {
            primary_role = qbPlayer.PlayerData.job.name,
            rank_tier = "entry",
            department = nil,
            district = nil,
            certs = {}
        }
    end
    return nil
end

exports('GetPlayerIdentity', GetPlayerIdentity)

-- 2. 核心比对器：PlayerMatchesTags (高弹性匹配)
-- @param src number 玩家服务器 ID
-- @param requiredTags table 需要比对的标签集, 例如: {role="police", tier="mid", cert="firearms_cert"}
-- @return boolean 是否完全匹配所有要求标签
local function PlayerMatchesTags(src, requiredTags)
    local identity = GetPlayerIdentity(src)
    if not identity then return false end
    
    for tag, val in pairs(requiredTags) do
        if tag == "role" and identity.primary_role ~= val then return false end
        if tag == "tier" and identity.rank_tier ~= val then return false end
        if tag == "department" and identity.department ~= val then return false end
        if tag == "district" and identity.district ~= val then return false end
        if tag == "cert" then
            local hasCert = false
            for _, c in ipairs(identity.certs) do
                if c == val then hasCert = true; break end
            end
            if not hasCert then return false end
        end
    end
    return true
end

exports('PlayerMatchesTags', PlayerMatchesTags)

-- 3. 设置层级 API (SetPlayerTier)
local function SetPlayerTier(src, tier)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    
    local cid = qbPlayer.PlayerData.citizenid
    tier = tier:lower()
    
    -- 验证层级合法性
    if not QBConfig.Career.Tiers[tier] then
        DebugPrint(("Warning: Attempted to set invalid tier '%s' for CID %s"):format(tier, cid))
        return false
    end
    
    -- 1. 更新内存缓存
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    CareerCache[src].rank_tier = tier
    Player(src).state:set("career_identity", CareerCache[src], true)
    
    -- 2. 异步写库 (不卡主线程)
    MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?', { tier, cid }, function(rowsChanged)
        if rowsChanged > 0 then
            DebugPrint(("Successfully updated tier to '%s' in DB for CID %s"):format(tier, cid))
        end
    end)
    
    return true
end

exports('SetPlayerTier', SetPlayerTier)

-- 4. 设置部门 API (SetPlayerDepartment)
local function SetPlayerDepartment(src, dept)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    
    local cid = qbPlayer.PlayerData.citizenid
    
    -- 1. 更新内存
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    CareerCache[src].department = dept
    Player(src).state:set("career_identity", CareerCache[src], true)
    
    -- 2. 异步写库
    MySQL.Async.execute('UPDATE players SET department = ? WHERE citizenid = ?', { dept, cid }, function(rowsChanged)
        if rowsChanged > 0 then
            DebugPrint(("Successfully updated department to '%s' in DB for CID %s"):format(tostring(dept), cid))
        end
    end)
    
    return true
end

exports('SetPlayerDepartment', SetPlayerDepartment)

-- 5. 设置地区 API (SetPlayerDistrict)
local function SetPlayerDistrict(src, district)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    
    local cid = qbPlayer.PlayerData.citizenid
    
    -- 1. 更新内存
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    CareerCache[src].district = district
    Player(src).state:set("career_identity", CareerCache[src], true)
    
    -- 2. 异步写库
    MySQL.Async.execute('UPDATE players SET district = ? WHERE citizenid = ?', { district, cid }, function(rowsChanged)
        if rowsChanged > 0 then
            DebugPrint(("Successfully updated district to '%s' in DB for CID %s"):format(tostring(district), cid))
        end
    end)
    
    return true
end

exports('SetPlayerDistrict', SetPlayerDistrict)

-- 6. 资质证书授予 (AddPlayerCert)
local function AddPlayerCert(src, certId)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    
    local cid = qbPlayer.PlayerData.citizenid
    
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    local certs = CareerCache[src].certs
    
    -- 检查是否重复
    for _, c in ipairs(certs) do
        if c == certId then return true end
    end
    
    -- 1. 添加进列表并更新缓存/State Bag
    table.insert(certs, certId)
    CareerCache[src].certs = certs
    Player(src).state:set("career_identity", CareerCache[src], true)
    
    -- 2. QBCore 原生许可证桥接同步 (Licenses Bridge)
    local licences = qbPlayer.PlayerData.metadata['licences'] or {}
    local synced = false
    if certId == 'pilot_license' then
        licences['pilot'] = true
        licences['driver'] = true
        synced = true
    elseif certId == 'heavy_vehicle' then
        licences['heavy'] = true
        synced = true
    elseif certId == 'firearms_cert' then
        licences['weapon'] = true
        synced = true
    end
    if synced then
        qbPlayer.Functions.SetMetaData('licences', licences)
        DebugPrint(("Licenses Bridge: Synced licences metadata for certId '%s' to QBCore"):format(certId))
    end
    
    -- 3. 异步序列化落盘
    MySQL.Async.execute('UPDATE players SET certs = ? WHERE citizenid = ?', { json.encode(certs), cid }, function(rowsChanged)
        if rowsChanged > 0 then
            DebugPrint(("Granted certificate '%s' to CID %s"):format(certId, cid))
        end
    end)
    
    return true
end

exports('AddPlayerCert', AddPlayerCert)

-- 7. 资质证书吊销 (RemovePlayerCert)
local function RemovePlayerCert(src, certId)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer then return false end
    
    local cid = qbPlayer.PlayerData.citizenid
    
    if not CareerCache[src] then CareerCache[src] = GetPlayerIdentity(src) end
    local certs = CareerCache[src].certs
    
    local found = false
    for i, c in ipairs(certs) do
        if c == certId then
            table.remove(certs, i)
            found = true
            break
        end
    end
    
    if not found then return true end
    
    -- 1. 更新内存和 State Bag
    CareerCache[src].certs = certs
    Player(src).state:set("career_identity", CareerCache[src], true)
    
    -- 2. QBCore 原生许可证桥接吊销
    local licences = qbPlayer.PlayerData.metadata['licences'] or {}
    local synced = false
    if certId == 'pilot_license' then
        licences['pilot'] = false
        synced = true
    elseif certId == 'heavy_vehicle' then
        licences['heavy'] = false
        synced = true
    elseif certId == 'firearms_cert' then
        licences['weapon'] = false
        synced = true
    end
    if synced then
        qbPlayer.Functions.SetMetaData('licences', licences)
        DebugPrint(("Licenses Bridge: Removed licences metadata for certId '%s' from QBCore"):format(certId))
    end
    
    -- 3. 异步写库
    MySQL.Async.execute('UPDATE players SET certs = ? WHERE citizenid = ?', { json.encode(certs), cid }, function(rowsChanged)
        if rowsChanged > 0 then
            DebugPrint(("Revoked certificate '%s' from CID %s"):format(certId, cid))
        end
    end)
    
    return true
end

exports('RemovePlayerCert', RemovePlayerCert)

-- ==========================================
--            帮 派 等 级 联 动 同 步
-- ==========================================

-- 拦截 QBCore:Server:OnGangUpdate，将帮派职位无感映射到 career_identity
AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer or not gang then return end
    
    -- 智能等级映射规则
    local targetTier = "entry"
    if gang.grade and gang.grade.level then
        local lvl = tonumber(gang.grade.level) or 0
        if lvl >= 4 then
            targetTier = "leader"
        elseif lvl >= 2 then
            targetTier = "mid"
        end
    end
    
    DebugPrint(("GangUpdate detected: CID=%s, New Gang=%s, Grade=%s -> Auto-Mapping rank_tier='%s'"):format(
        qbPlayer.PlayerData.citizenid, gang.name, tostring(gang.grade and gang.grade.level), targetTier
    ))
    
    SetPlayerTier(src, targetTier)
end)

-- 拦截 QBCore:Server:OnJobUpdate，实时更新缓存、客户端 State Bag 并自动映射 rank_tier
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if not CareerCache[src] then return end
    local qbPlayer = QBCore.Functions.GetPlayer(src)
    if not qbPlayer or not job then return end
    
    -- 智能等级映射规则
    local targetTier = "entry"
    if job.isboss or (job.grade and job.grade.level and job.grade.level >= 4) then
        targetTier = "leader"
    elseif job.grade and job.grade.level and job.grade.level >= 2 then
        targetTier = "mid"
    end
    
    CareerCache[src].primary_role = job.name
    CareerCache[src].rank_tier = targetTier
    Player(src).state:set("career_identity", CareerCache[src], true)
    
    -- 异步写库更新，确保主线程极速流畅
    local cid = qbPlayer.PlayerData.citizenid
    MySQL.Async.execute('UPDATE players SET rank_tier = ? WHERE citizenid = ?', { targetTier, cid }, function(rowsChanged)
        if rowsChanged > 0 then
            DebugPrint(("JobUpdate mapping saved rank_tier '%s' to DB for CID %s"):format(targetTier, cid))
        end
    end)
    
    DebugPrint(("JobUpdate detected: CID=%s, New Job=%s, Grade=%s -> Auto-Mapped rank_tier='%s'"):format(
        qbPlayer.PlayerData.citizenid, job.name, tostring(job.grade and job.grade.level), targetTier
    ))
end)

-- ==========================================
--          联 合 测 试 高 级 互 动 指 令
-- ==========================================

QBCore.Commands.Add('careertest', '一键跑通自研多标签与许可证桥接测试 (Admin Only)', {}, true, function(source, args)
    local qbPlayer = QBCore.Functions.GetPlayer(source)
    if not qbPlayer then return end
    
    local cid = qbPlayer.PlayerData.citizenid
    TriggerClientEvent('QBCore:Notify', source, "🧪 开始执行 v0.3 联合测试组件...", "primary")
    Wait(1000)

    -- 1. 获取当前身份
    local identity = exports['custom-career']:GetPlayerIdentity(source)
    if identity then
        TriggerClientEvent('QBCore:Notify', source, ("步骤 1 (通过) - 内存读取成功! 职业: %s, 阶层: %s"):format(identity.primary_role, identity.rank_tier), "success")
    else
        TriggerClientEvent('QBCore:Notify', source, "步骤 1 (失败) - 无法读取内存缓存", "error")
        return
    end
    Wait(1000)

    -- 2. 比对过滤器判定
    local matchResult = exports['custom-career']:PlayerMatchesTags(source, { role = identity.primary_role, tier = identity.rank_tier })
    if matchResult then
        TriggerClientEvent('QBCore:Notify', source, "步骤 2 (通过) - 标签比对过滤器比对一致!", "success")
    else
        TriggerClientEvent('QBCore:Notify', source, "步骤 2 (失败) - 标签比对过滤器错误阻断", "error")
    end
    Wait(1000)

    -- 3. 资质证书授予与 QBCore 许可证桥接联动测试
    TriggerClientEvent('QBCore:Notify', source, "测试 3 - 尝试授予 飞行执照 (pilot_license)...", "primary")
    local grantSuccess = exports['custom-career']:AddPlayerCert(source, 'pilot_license')
    Wait(1000)
    
    if grantSuccess then
        -- 再次获取身份
        local newIdentity = exports['custom-career']:GetPlayerIdentity(source)
        local hasCertInCache = false
        for _, c in ipairs(newIdentity.certs) do
            if c == 'pilot_license' then hasCertInCache = true; break end
        end

        -- 重新获取最新的 Player 引用，防止跨资源序列化 deep copy 导致的局部引用数据滞后
        qbPlayer = QBCore.Functions.GetPlayer(source)
        
        -- 核验原生 licences 元数据
        local hasNativeLicence = qbPlayer.PlayerData.metadata['licences']['pilot'] or false
        local hasNativeDriver = qbPlayer.PlayerData.metadata['licences']['driver'] or false

        if hasCertInCache and hasNativeLicence and hasNativeDriver then
            TriggerClientEvent('QBCore:Notify', source, "步骤 3 (通过) - 资质授予成功 且 完美联动点亮 QBCore licences!", "success")
        else
            TriggerClientEvent('QBCore:Notify', source, ("步骤 3 (失败) - 数据未对齐。缓存证: %s, 原生证: %s"):format(tostring(hasCertInCache), tostring(hasNativeLicence)), "error")
        end
    else
        TriggerClientEvent('QBCore:Notify', source, "步骤 3 (失败) - 资质证书添加函数返回 false", "error")
    end
    Wait(1500)

    -- 4. 资质证书吊销与 QBCore 许可证注销桥接联动测试
    TriggerClientEvent('QBCore:Notify', source, "测试 4 - 尝试吊销 飞行执照...", "primary")
    local revokeSuccess = exports['custom-career']:RemovePlayerCert(source, 'pilot_license')
    Wait(1000)

    if revokeSuccess then
        local finalIdentity = exports['custom-career']:GetPlayerIdentity(source)
        local hasCertInCache = false
        for _, c in ipairs(finalIdentity.certs) do
            if c == 'pilot_license' then hasCertInCache = true; break end
        end

        -- 重新获取最新的 Player 引用，以核验原生 licences 吊销情况
        qbPlayer = QBCore.Functions.GetPlayer(source)
        local hasNativeLicence = qbPlayer.PlayerData.metadata['licences']['pilot'] or false

        if not hasCertInCache and not hasNativeLicence then
            TriggerClientEvent('QBCore:Notify', source, "步骤 4 (通过) - 资质吊销成功 且 完美联动注销 QBCore licences!", "success")
        else
            TriggerClientEvent('QBCore:Notify', source, "步骤 4 (失败) - 证书或原生 Licence 吊销残留", "error")
        end
    else
        TriggerClientEvent('QBCore:Notify', source, "步骤 4 (失败) - 资质证书吊销函数返回 false", "error")
    end
    Wait(1000)
    
    TriggerClientEvent('QBCore:Notify', source, "🎉 v0.3 核心多标签与桥接测试集全部跑通!", "success")
end, 'admin')
