local QBCore = exports['qb-core']:GetCoreObject()

-- 冷却时间管理状态表
local UserCooldowns = {}

-- 辅助调试打印
local function DebugPrint(msg)
    if QBConfig.Custom.General.EnableDebug then
        print(('[custom-main][security] %s'):format(msg))
    end
end

-- ==========================================
--              频 率 限 制 器 (Rate Limiter)
-- ==========================================

-- 校验玩家某操作是否触发频率限制
-- @param src number 玩家服务器 ID
-- @param action string 操作标识名
-- @param cooldownMs number 冷却毫秒数
-- @return boolean 是否允许操作 (true: 允许; false: 被限流拦截)
local function CheckRateLimit(src, action, cooldownMs)
    local now = os.time() * 1000 + math.floor((os.clock() % 1) * 1000)
    
    if not UserCooldowns[src] then
        UserCooldowns[src] = {}
    end

    local lastTrigger = UserCooldowns[src][action] or 0
    local diff = now - lastTrigger

    if diff < cooldownMs then
        -- 触发限流，拒绝操作
        DebugPrint(("RateLimit Triggered: Player=%s, Action=%s, Interval=%dms (Limit=%dms)"):format(
            GetPlayerName(src) or "unknown", action, diff, cooldownMs
        ))
        return false
    end

    UserCooldowns[src][action] = now
    return true
end

exports('CheckRateLimit', CheckRateLimit)

-- 清理掉线玩家的冷却记录，防内存泄露与 Combat Logging 离线逃脱审计
AddEventHandler('playerDropped', function(reason)
    local src = source
    
    -- 1. 清除冷却缓存
    if UserCooldowns[src] then
        UserCooldowns[src] = nil
    end

    -- 2. 检查 Combat Logging
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local ped = GetPlayerPed(src)
    local health = ped ~= 0 and GetEntityHealth(ped) or 200
    local isWounded = health < 120
    local isDead = Player.PlayerData.metadata['isdead'] or Player.PlayerData.metadata['inlaststand'] or false
    local isHandcuffed = Player.PlayerData.metadata['handcuffed'] or Player.PlayerData.metadata['ishandcuffed'] or false

    if isDead or isWounded or isHandcuffed then
        local cid = Player.PlayerData.citizenid
        local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
        local coords = ped ~= 0 and GetEntityCoords(ped) or vector3(0, 0, 0)
        local cash = Player.Functions.GetMoney('cash') or 0
        local bank = Player.Functions.GetMoney('bank') or 0
        local policeCount = QBCore.Functions.GetDutyCount('police')

        -- 强行进行重伤状态的持久化锁定，防止下线洗状态
        local currentMetadata = Player.PlayerData.metadata
        local statusAction = "无特殊变动"
        if isWounded and not isDead then
            currentMetadata['isdead'] = true
            statusAction = "强行标记重伤落盘"
        end

        -- 异步写入数据库以保证极致性能
        MySQL.Async.execute(
            'UPDATE players SET metadata = ? WHERE citizenid = ?', 
            { json.encode(currentMetadata), cid }, 
            function(rowsChanged)
                if rowsChanged and rowsChanged > 0 then
                    DebugPrint(("Persistent metadata saved for logged CID %s due to Combat Logging"):format(cid))
                end
            end
        )

        -- 组装 Discord 安全审计嵌入数据
        local alertText = ("**玩家名**: %s (%s)\n**断连原因**: %s\n**状态**: %s\n**物理血量**: %d/200 (重伤判定: %s)\n**倒地死亡判定**: %s\n**手铐判定**: %s\n**坐标位置**: `%.2f, %.2f, %.2f`\n**钱包现金**: $%d | 银行余额: $%d\n**在线执勤警员**: %d 名"):format(
            charName, cid, tostring(reason), statusAction, health, tostring(isWounded), tostring(isDead), tostring(isHandcuffed),
            coords.x, coords.y, coords.z, cash, bank, policeCount
        )
        
        exports['custom-main']:LogSecurity("战斗逃脱警报 (Combat Logging)", alertText, 13631488) -- 红色警报
    end
end)

-- ==========================================
--             资 金 突 变 审 计 (AddMoney)
-- ==========================================

AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 or action ~= "add" then return end

    local maxLimit = QBConfig.Custom.Security.MaxAddMoneyLimit
    if amount > maxLimit then
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then return end

        local isadmin = QBCore.Functions.HasPermission(src, 'admin') or QBCore.Functions.HasPermission(src, 'god')
        
        -- 构建安全日志
        local alertText = ("**警报级别**: %s\n**玩家名**: %s (%s)\n**物理ID**: %d\n**资产变动**: +$%d (%s)\n**来源事由**: %s\n**是否特权账号**: %s"):format(
            isadmin and "⚠️ 提示 (管理员操作)" or "🚨 严重高危 (瞬间巨额流入)",
            GetPlayerName(src) or "unknown",
            Player.PlayerData.citizenid or "unknown",
            src, amount, moneytype, reason or "unknown",
            tostring(isadmin)
        )

        if not isadmin then
            -- 非管理员玩家触发巨额变动，立刻引发安全审计警报
            exports['custom-main']:LogSecurity("巨额资产异常流入", alertText, 16711680) -- 红色
        else
            -- 管理员变动仅作为系统备案审计
            exports['custom-main']:LogGeneric("管理员划账审计", alertText, 10079487) -- 蓝紫色
        end
    end
end)

-- ==========================================
--             帮 派 变 动 审 计 (SetGang)
-- ==========================================

AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
    local Player = QBCore.Functions.GetPlayer(src)
    local name = Player and GetPlayerName(src) or "unknown"
    local citizenid = Player and Player.PlayerData.citizenid or "unknown"

    DebugPrint(('GangUpdate: Player=%s, Gang=%s, Grade=%s'):format(
        name,
        gang and gang.name or 'nil',
        gang and gang.grade and gang.grade.level or 'nil'
    ))

    local text = ("**玩家名**: %s (%s)\n**新帮派**: %s (%s)\n**帮派阶级**: %d (是否主管: %s)"):format(
        name, citizenid, 
        gang and gang.label or "nil", gang and gang.name or "nil",
        gang and gang.grade and gang.grade.level or 0, 
        tostring(gang and gang.isboss or false)
    )
    exports['custom-main']:LogGeneric("帮派关系更新审计", text, 16738657) -- 粉橙色
end)

-- ==========================================
--            回 调 拦 截 与 劫 持 层
-- ==========================================

CreateThread(function()
    -- 稍作等待，确保 qb-core 和 qb-inventory 资源都已注册好它们的 ServerCallbacks
    Wait(1500)

    -- 1. 劫持并防刷商店交易行为 ('qb-inventory:server:attemptPurchase')
    local origAttemptPurchase = QBCore.ServerCallbacks['qb-inventory:server:attemptPurchase']
    if origAttemptPurchase then
        QBCore.ServerCallbacks['qb-inventory:server:attemptPurchase'] = function(source, cb, data)
            local rateLimitMs = QBConfig.Custom.Security.RateLimitMs
            
            -- 检查冷却限制
            if not CheckRateLimit(source, "shop_purchase", rateLimitMs) then
                TriggerClientEvent('QBCore:Notify', source, _L(src, 'security_too_frequent'), "error")
                cb(false)
                return
            end

            -- 校验通过，移交控制权
            origAttemptPurchase(source, cb, data)
        end
        DebugPrint("已成功劫持 `attemptPurchase` (商店购买防刷挂载完成)")
    else
        print("[custom-main][security][WARNING] 无法找到 `qb-inventory:server:attemptPurchase` 注册信息，跳过劫持。")
    end

    -- 2. 劫持并防刷服务器车辆生成 ('QBCore:Server:SpawnVehicle')
    local origSpawnVehicle = QBCore.ServerCallbacks['QBCore:Server:SpawnVehicle']
    if origSpawnVehicle then
        QBCore.ServerCallbacks['QBCore:Server:SpawnVehicle'] = function(source, cb, model, coords, warp)
            local Player = QBCore.Functions.GetPlayer(source)
            if not Player then
                cb(false)
                return
            end

            -- 判定是否允许刷车
            if QBConfig.Custom.Security.CheckVehicleSpawn then
                local isadmin = QBCore.Functions.HasPermission(source, 'admin') or QBCore.Functions.HasPermission(source, 'god')
                local jobName = Player.PlayerData.job.name
                local onDuty = Player.PlayerData.job.onduty
                
                -- 白名单合法生成车辆职业 (例如警察、医生、公交、拖车司机且必须处于 OnDuty 状态)
                local authorizedJobs = { police = true, ambulance = true, taxi = true, mechanic = true, tow = true, garbage = true }
                local isJobAuthorized = authorizedJobs[jobName] and onDuty

                if not isadmin and not isJobAuthorized then
                    -- 既非管理员又非合法执勤职业，属于非法刷车请求，予以拒绝
                    local text = ("**异常操作**: 非法生成车辆\n**玩家**: %s (%s)\n**申请载具型号**: %s\n**玩家当前职业**: %s (执勤状态: %s)"):format(
                        GetPlayerName(source), Player.PlayerData.citizenid, tostring(model), jobName, tostring(onDuty)
                    )
                    exports['custom-main']:LogSecurity("拦截非法刷车企图", text, 16711680)
                    
                    TriggerClientEvent('QBCore:Notify', source, _L(src, 'security_no_car_perm'), "error")
                    cb(false)
                    return
                end

                -- 频率限制：非管理员限频，每 5 秒只能刷 1 辆车，防止刷车搞崩服务器
                if not isadmin and not CheckRateLimit(source, "vehicle_spawn", 5000) then
                    TriggerClientEvent('QBCore:Notify', source, _L(src, 'security_car_cooldown'), "error")
                    cb(false)
                    return
                end
            end

            -- 验证通过，正常刷车
            origSpawnVehicle(source, cb, model, coords, warp)
        end
        DebugPrint("已成功劫持 `QBCore:Server:SpawnVehicle` (安全防护挂载完成)")
    end

    -- 3. 劫持并防刷长距离车辆生成 ('QBCore:Server:CreateVehicle')
    local origCreateVehicle = QBCore.ServerCallbacks['QBCore:Server:CreateVehicle']
    if origCreateVehicle then
        QBCore.ServerCallbacks['QBCore:Server:CreateVehicle'] = function(source, cb, model, coords, warp)
            local Player = QBCore.Functions.GetPlayer(source)
            if not Player then
                cb(false)
                return
            end

            if QBConfig.Custom.Security.CheckVehicleSpawn then
                local isadmin = QBCore.Functions.HasPermission(source, 'admin') or QBCore.Functions.HasPermission(source, 'god')
                local jobName = Player.PlayerData.job.name
                local onDuty = Player.PlayerData.job.onduty
                local authorizedJobs = { police = true, ambulance = true, taxi = true, mechanic = true }
                local isJobAuthorized = authorizedJobs[jobName] and onDuty

                if not isadmin and not isJobAuthorized then
                    local text = ("**异常操作**: 非法生成长距载具\n**玩家**: %s (%s)\n**申请载具型号**: %s\n**玩家当前职业**: %s"):format(
                        GetPlayerName(source), Player.PlayerData.citizenid, tostring(model), jobName
                    )
                    exports['custom-main']:LogSecurity("拦截非法长距车企图", text, 16711680)
                    cb(false)
                    return
                end

                -- 频率限制：非管理员 5 秒冷却
                if not isadmin and not CheckRateLimit(source, "vehicle_spawn", 5000) then
                    cb(false)
                    return
                end
            end

            origCreateVehicle(source, cb, model, coords, warp)
        end
        DebugPrint("已成功劫持 `QBCore:Server:CreateVehicle` (安全防护挂载完成)")
    end
end)
