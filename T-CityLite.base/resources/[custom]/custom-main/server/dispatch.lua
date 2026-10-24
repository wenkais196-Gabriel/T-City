local QBCore = exports['qb-core']:GetCoreObject()
local WantedPlayers = {} -- 缓存当前在线且被通缉的玩家 { [citizenid] = { source = id, wantedLevel = lv } }

-- 通缉上报限流: 每名玩家 5 秒一次（客户端正常 GPS 脉冲间隔为 8 秒）
local HandoverCooldowns = {}
local HANDOVER_COOLDOWN_MS = 5000
local MAP_COORD_LIMIT = 10000

-- 校验并规范化客户端坐标，拒绝非数字/NaN/超出地图范围的输入
local function SanitizeCoords(coords)
    local x, y, z
    if type(coords) == 'vector3' then
        x, y, z = coords.x, coords.y, coords.z
    elseif type(coords) == 'table' then
        x, y, z = tonumber(coords.x) or tonumber(coords[1]),
                  tonumber(coords.y) or tonumber(coords[2]),
                  tonumber(coords.z) or tonumber(coords[3])
    end

    if not x or not y or not z then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end -- NaN
    if x < -MAP_COORD_LIMIT or x > MAP_COORD_LIMIT
        or y < -MAP_COORD_LIMIT or y > MAP_COORD_LIMIT
        or z < -MAP_COORD_LIMIT or z > MAP_COORD_LIMIT then
        return nil
    end

    return vector3(x, y, z)
end

AddEventHandler('playerDropped', function()
    HandoverCooldowns[source] = nil
end)

-- ==========================================
--        接 收 警 星 移 交 及 GPS 脉 冲
-- ==========================================
RegisterNetEvent('custom-main:server:policeHandoverAlert', function(coords, streetName, wantedLevel)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 防刷: 超频请求直接丢弃
    local now = GetGameTimer()
    local lastAlert = HandoverCooldowns[src]
    if lastAlert and (now - lastAlert) < HANDOVER_COOLDOWN_MS then return end
    HandoverCooldowns[src] = now

    -- 参数校验: 坐标必须是数字且在合理地图范围；通缉星级夹紧到 1..5；街道名截断
    coords = SanitizeCoords(coords)
    if not coords then return end

    local level = tonumber(wantedLevel)
    if not level or level ~= level then return end
    wantedLevel = math.max(1, math.min(5, math.floor(level)))
    streetName = tostring(streetName or '未知地点'):sub(1, 64)
    
    local citizenid = Player.PlayerData.citizenid
    local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    
    -- 判断是否为首次触发通缉警报（避免后续每 8 秒的 GPS 定位脉冲重复触发全局大横幅通知）
    local isFirstAlert = false
    if not WantedPlayers[citizenid] then
        isFirstAlert = true
        WantedPlayers[citizenid] = {
            source = src,
            wantedLevel = wantedLevel
        }
        
        -- 更新 QBCore 元数据持久化（写入数据库，防下线逃避）
        Player.Functions.SetMetaData('wanted', wantedLevel)
        local record = Player.PlayerData.metadata['criminalrecord'] or {}
        record.hasRecord = true
        record.date = os.date('%Y-%m-%d %H:%M:%S')
        Player.Functions.SetMetaData('criminalrecord', record)
        
        -- 🔒 Security: citizenid 脱敏
        local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
        print(("[custom-main][police-dispatch] Citizen '%s' (%s) entered player wanted state. Level: %d stars."):format(charName, maskedCid, wantedLevel))
        exports['custom-logs']:LogGeneric("高星通缉移交", string.format("**嫌疑人**: %s\n**CitizenID**: %s\n**通缉星级**: %d 星\n**案发街道**: %s\n**状态**: 原生 AI 警车已清除，通缉权已移交玩家警察！", charName, citizenid, wantedLevel, streetName), 16711680) -- 红色
    end
    
    -- 向所有在线且执勤中的玩家警察发送 GPS 雷达脉冲和通知
    local players = QBCore.Functions.GetPlayers()
    for i = 1, #players do
        local targetId = players[i]
        local cop = QBCore.Functions.GetPlayer(targetId)
        if cop and cop.PlayerData.job.name == 'police' and cop.PlayerData.job.onduty then
            if isFirstAlert then
                -- 仅限首次触发通缉时发送全局警报声和警报详情
                TriggerClientEvent('QBCore:Notify', targetId, string.format("【高星通缉】在逃犯 %s (%d星) 最后出现在 %s！", charName, wantedLevel, streetName), "police", 10000)
            end
            
            -- 更新警察雷达上的红色 blip 标记
            TriggerClientEvent('custom-main:client:updateSuspectBlip', targetId, src, coords, charName, wantedLevel)
        end
    end
end)

-- ==========================================
--        指 令：清 除 通 缉 状 态
-- ==========================================
local function ClearWantedCallback(source, args)
    local src = source
    local cop = QBCore.Functions.GetPlayer(src)
    if not cop then return end
    
    -- 安全校验：必须是执勤中的警察才能清除通缉
    if cop.PlayerData.job.name ~= 'police' or not cop.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_no_permission'), "error")
        return
    end
    
    local targetId = tonumber(args[1])
    if not targetId then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_invalid_id'), "error")
        return
    end
    
    local suspect = QBCore.Functions.GetPlayer(targetId)
    if not suspect then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_player_offline'), "error")
        return
    end
    
    local suspectCitizenId = suspect.PlayerData.citizenid
    local suspectName = suspect.PlayerData.charinfo.firstname .. " " .. suspect.PlayerData.charinfo.lastname
    
    -- 清除服务器缓存状态
    if WantedPlayers[suspectCitizenId] then
        WantedPlayers[suspectCitizenId] = nil
    end
    
    -- 清除数据库和元数据持久化
    suspect.Functions.SetMetaData('wanted', 0)
    
    -- 1. 通知被通缉的玩家，恢复其警星状态
    TriggerClientEvent('custom-main:client:clearLocalWanted', targetId)
    
    -- 2. 通知所有警察删除该嫌疑人的雷达 Blip
    local players = QBCore.Functions.GetPlayers()
    for i = 1, #players do
        local tempId = players[i]
        local tempCop = QBCore.Functions.GetPlayer(tempId)
        if tempCop and tempCop.PlayerData.job.name == 'police' and tempCop.PlayerData.job.onduty then
            TriggerClientEvent('custom-main:client:clearSuspectBlip', tempId, targetId)
            TriggerClientEvent('QBCore:Notify', tempId, string.format("【通缉销案】嫌疑人 %s 的通缉已被警官 %s 销案清除！", suspectName, cop.PlayerData.charinfo.lastname), "success")
        end
    end
    
    exports['custom-logs']:LogGeneric("通缉销案记录", string.format("**销案警官**: %s\n**原嫌疑人**: %s\n**CitizenID**: %s\n**状态**: 通缉状态已安全清除，GPS 追踪信号已被解除。", cop.PlayerData.charinfo.lastname, suspectName, suspectCitizenId), 65280) -- 绿色
end

QBCore.Commands.Add('clearwanted', '清除玩家的在逃通缉状态 (仅限值班警察)', { { name = 'id', help = '嫌疑人的玩家 ID' } }, true, ClearWantedCallback)
QBCore.Commands.Add('clearwarrant', '清除玩家的在逃通缉状态 (仅限值班警察)', { { name = 'id', help = '嫌疑人的玩家 ID' } }, true, ClearWantedCallback)

-- ==========================================
--        断 线 与 上 线 状 态 恢 复 处 理
-- ==========================================
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local citizenid = Player.PlayerData.citizenid
    local savedWanted = Player.PlayerData.metadata['wanted'] or 0
    
    -- 若玩家数据库中记录了大于 0 的通缉状态，上线后自动恢复服务器通缉缓存
    if savedWanted > 0 then
        WantedPlayers[citizenid] = {
            source = src,
            wantedLevel = savedWanted
        }
        
        -- 提示玩家他们依然处于通缉中
        SetTimeout(6000, function()
            TriggerClientEvent('QBCore:Notify', src, string.format("【逃犯警告】你上次离线时处于 %d 星通缉，警方已恢复雷达定位！", savedWanted), "error", 10000)
            -- 激活客户端的自定义通缉状态
            TriggerClientEvent('QBCore:Client:SetMetaData', src, 'wanted', savedWanted)
        end)
    end
end)

-- ==========================================
--    管理员强制清除通缉（custom-admin 调用）
-- ==========================================
AddEventHandler('custom-main:server:adminClearWanted', function(citizenid)
    if WantedPlayers[citizenid] then
        WantedPlayers[citizenid] = nil
        -- 🔒 Security: citizenid 脱敏
        local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
        print(('[custom-main] Admin cleared wanted status for %s'):format(maskedCid))
    end
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    -- 玩家离线时，从活动通缉缓存中移除（但保留数据库 metadata 记录，下次上线自动恢复）
    for cid, data in pairs(WantedPlayers) do
        if data.source == src then
            WantedPlayers[cid] = nil
            
            -- 同时通知警察该嫌疑人的雷达定位暂时丢失（离线）
            local players = QBCore.Functions.GetPlayers()
            for i = 1, #players do
                local tempId = players[i]
                local tempCop = QBCore.Functions.GetPlayer(tempId)
                if tempCop and tempCop.PlayerData.job.name == 'police' and tempCop.PlayerData.job.onduty then
                    TriggerClientEvent('custom-main:client:clearSuspectBlip', tempId, src)
                end
            end
            break
        end
    end
end)

-- ==========================================
--        指 令：快 速 切 换 执 勤 / 下 班 状态 (含防逃课安全拦截)
-- ==========================================
QBCore.Commands.Add('duty', '快速切换执勤 (On Duty) / 下班 (Off Duty) 状态', {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    
    local citizenid = Player.PlayerData.citizenid
    local savedWanted = Player.PlayerData.metadata['wanted'] or 0
    
    -- 逃犯安全拦截：在逃通缉犯不能使用指令打卡上班/下班以逃避追踪
    if WantedPlayers[citizenid] or savedWanted > 0 then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_wanted_block_duty'), "error", 8000)
        return
    end
    
    local jobName = Player.PlayerData.job.name
    local currentDuty = Player.PlayerData.job.onduty
    local newDuty = not currentDuty
    if jobName == 'police' then
        -- FIT-01: police duty has a single writer in custom-police. Never
        -- touch PlayerData.job.onduty from custom-main for a police officer.
        local callOk, dutyOk, dutyErr = pcall(function()
            return exports['custom-police']:SetDutyForSource(src, newDuty, 'quick_command')
        end)
        if not callOk or dutyOk ~= true then
            local reason = callOk and tostring(dutyErr or 'duty_failed') or tostring(dutyOk)
            TriggerClientEvent('QBCore:Notify', src,
                ('切换执勤失败（%s），请稍后重试'):format(reason), "error", 6000)
            return
        end
    elseif jobName == 'ambulance' or jobName == 'mechanic' or jobName == 'taxi' then
        -- FIT-01: 非 leo / ambulance/mechanic/taxi keep qb-core's own
        -- projection; only police duty is owned by custom-police.
        Player.Functions.SetJobDuty(newDuty)
    else
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_no_duty_switch'), "error")
        return
    end

    if newDuty then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_on_duty'), "success")
    else
        TriggerClientEvent('QBCore:Notify', src, "你已成功进入【下班休息】状态！", "warning")
    end
end, 'user')

-- ==========================================
--        通 缉 逃 犯 执 勤 锁 死 (防 任何物理值班点 exploit 漏洞)
-- ==========================================
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    
    local citizenid = Player.PlayerData.citizenid
    local savedWanted = Player.PlayerData.metadata['wanted'] or 0
    
    -- 如果玩家处于通缉在逃状态，且其新状态为执勤上班 (job.onduty == true)
    if (WantedPlayers[citizenid] or savedWanted > 0) and job.onduty then
        local jobName = job.name or Player.PlayerData.job.name
        if jobName == 'police' then
            -- FIT-01: police duty is owned by custom-police. Force the
            -- projection through the service so the unit row and audit stay
            -- consistent; never fall back to a direct write here.
            local callOk, dutyOk, dutyErr = pcall(function()
                return exports['custom-police']:SetDutyForSource(src, false, 'wanted_lock')
            end)
            if not callOk or dutyOk ~= true then
                local maskedCid = citizenid:sub(1, 4) .. '...' .. citizenid:sub(-4)
                print(('[custom-main] wanted duty lock failed for %s: %s'):format(
                    maskedCid, callOk and tostring(dutyErr or 'duty_failed') or tostring(dutyOk)))
            end
        else
            -- FIT-01: 非 leo / ambulance/mechanic/taxi keep qb-core's own
            -- projection; only police duty is owned by custom-police.
            Player.Functions.SetJobDuty(false)
        end
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'dispatch_wanted_block_clock'), "error", 8000)
    end
end)
