-- Variables
QBCore = exports['qb-core']:GetCoreObject()
local updatingCops = false

-- 自动警情限流: source -> 上次触发时间 (模块级)
local autoAlertCooldown = {}
local AUTO_ALERT_COOLDOWN = 10

-- 平民报警 (qb-drugs / qb-storerobbery / qb-houserobbery / custom-vehicles 的
-- 热接线报警都会触发 policeAlert) 每 source 15 秒 1 次。
local policeAlertCooldown = {}
local POLICE_ALERT_COOLDOWN = 15

local function sanitizeAlertCoords(coords)
    if type(coords) ~= 'table' then return nil end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return nil end
    -- Reject NaN/inf and absurd coordinates instead of forwarding client data.
    if x ~= x or y ~= y or z ~= z then return nil end
    if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or math.abs(z) > 10000.0 then
        return nil
    end
    return { x = x, y = y, z = z }
end

--- UTF-8-safe head slice: `limit` counts characters, not bytes.
local function utf8Clip(text, limit)
    if #text <= limit then return text end
    if utf8 and utf8.len and utf8.offset then
        local ok, length = pcall(utf8.len, text)
        if ok and length then
            if length <= limit then return text end
            local offsetOk, byteEnd = pcall(utf8.offset, text, limit + 1)
            if offsetOk and byteEnd then return text:sub(1, byteEnd - 1) end
            return text
        end
    end
    return text:sub(1, limit)
end

local function sanitizeAlertText(text)
    if type(text) ~= 'string' then return nil end
    -- Control characters are stripped first: alert text is printed to the
    -- server console and pushed to every on-duty officer, so a newline in it
    -- could forge log lines.
    text = text:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return nil end
    return utf8Clip(text, 200)
end

-- Functions

local function UpdateBlips()
    local dutyPlayers = {}
    local players = QBCore.Functions.GetQBPlayers()
    for i = 1, #players do
        local v = players[i]
        if v and (v.PlayerData.job.type == 'leo' or v.PlayerData.job.type == 'ems') and v.PlayerData.job.onduty then
            local coords = GetEntityCoords(GetPlayerPed(v.PlayerData.source))
            local heading = GetEntityHeading(GetPlayerPed(v.PlayerData.source))
            dutyPlayers[#dutyPlayers + 1] = {
                source = v.PlayerData.source,
                label = v.PlayerData.metadata['callsign'],
                job = v.PlayerData.job.name,
                location = {
                    x = coords.x,
                    y = coords.y,
                    z = coords.z,
                    w = heading
                }
            }
        end
    end
    TriggerClientEvent('police:client:UpdateBlips', -1, dutyPlayers)
end

local function GetCurrentCops()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    return amount
end

-- Callbacks

QBCore.Functions.CreateCallback('police:GetDutyPlayers', function(_, cb)
    local dutyPlayers = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            dutyPlayers[#dutyPlayers + 1] = {
                source = v.PlayerData.source,
                label = v.PlayerData.metadata['callsign'],
                job = v.PlayerData.job.name
            }
        end
    end
    cb(dutyPlayers)
end)

QBCore.Functions.CreateCallback('police:GetCops', function(_, cb)
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    cb(amount)
end)

QBCore.Functions.CreateCallback('police:server:isPlayerDead', function(_, cb, playerId)
    local Player = QBCore.Functions.GetPlayer(playerId)
    cb(Player.PlayerData.metadata['isdead'])
end)

QBCore.Functions.CreateCallback('police:IsSilencedWeapon', function(source, cb, weapon)
    local Player = QBCore.Functions.GetPlayer(source)
    local itemInfo = Player.Functions.GetItemByName(QBCore.Shared.Weapons[weapon]['name'])
    local retval = false
    if itemInfo then
        if itemInfo.info and itemInfo.info.attachments then
            for k in pairs(itemInfo.info.attachments) do
                if itemInfo.info.attachments[k].component == 'COMPONENT_AT_AR_SUPP_02' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_AR_SUPP' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_PI_SUPP_02' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_PI_SUPP' then
                    retval = true
                end
            end
        end
    end
    cb(retval)
end)

QBCore.Functions.CreateCallback('police:server:IsPoliceForcePresent', function(_, cb)
    local retval = false
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.grade.level >= 2 then
            retval = true
            break
        end
    end
    cb(retval)
end)

-- Events

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        CreateThread(function()
            MySQL.query("DELETE FROM inventories WHERE identifier = 'policetrash'")
        end)
    end
end)

RegisterNetEvent('qb-policejob:server:stash', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    local citizenId = Player.PlayerData.citizenid
    local stashName = 'policestash_' .. citizenId
    exports['qb-inventory']:OpenInventory(src, stashName)
end)

RegisterNetEvent('qb-policejob:server:trash', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    exports['qb-inventory']:OpenInventory(src, 'policetrash', {
        maxweight = 4000000,
        slots = 300,
    })
end)

RegisterNetEvent('qb-policejob:server:evidence', function(currentEvidence)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    exports['qb-inventory']:OpenInventory(src, currentEvidence, {
        maxweight = 4000000,
        slots = 500,
    })
end)

--- 把一条警报变成警情单，返回建单结果（合并时 merged = true）。
--- PoliceDispatch 由 server/p0.lua 在加载时挂到全局；本文件先加载，所以只能运行时取。
---@return table|nil incident
local function createIncidentForAlert(creatorOrSource, message, coords, priority)
    if type(PoliceDispatch) ~= 'table' then return nil end
    local payload = {
        code = '911',
        title = message,
        description = message,
        priority = priority or 2,
        x = coords.x, y = coords.y, z = coords.z,
    }
    local ok, result
    if type(creatorOrSource) == 'string' then
        ok, result = pcall(PoliceDispatch.CreateIncidentSystem, creatorOrSource, payload)
    else
        ok, result = pcall(PoliceDispatch.CreateIncident, creatorOrSource, payload)
    end
    if not ok then
        print(('[policeAlert] 建单失败: %s'):format(tostring(result)))
        return nil
    end
    if type(result) ~= 'table' then return nil end
    return result
end

-- 平民报警：qb-drugs / qb-storerobbery / qb-houserobbery / custom-vehicles 的
-- 热接线报警都从这里进来，所以**不能**只限警察。安全性靠三件事保证：
-- 坐标完全由服务端从报警者 ped 上取（客户端不发坐标）、文本清洗截断、
-- 每 source 15 秒最多 1 次。
RegisterNetEvent('police:server:policeAlert', function(text)
    local src = source
    if not QBCore.Functions.GetPlayer(src) then return end
    local now = os.time()
    for otherSrc, lastAt in pairs(policeAlertCooldown) do
        if now - lastAt > 120 then policeAlertCooldown[otherSrc] = nil end
    end
    local last = policeAlertCooldown[src]
    if last and now - last < POLICE_ALERT_COOLDOWN then return end
    local message = sanitizeAlertText(text)
    if not message then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    -- Server-authoritative location: a caller cannot place the alert elsewhere.
    local coords = GetEntityCoords(ped)
    local alertCoords = { x = coords.x, y = coords.y, z = coords.z }
    policeAlertCooldown[src] = now

    -- 报警必须进警情板。以前这里只发通知 + 插旗，于是"被抢了报警"在 MDT 里
    -- 等于没发生：不能派单、不能清场、不留记录、进不了统计。
    local incident = createIncidentForAlert(src, message, alertCoords, 2)

    -- 通知与地图标记都由建单负责（projectIncident），这里只留日志。
    print(('[policeAlert] src=%s | #%s | %s | 值班警察: %d 人'):format(
        tostring(src), tostring(incident and incident.id or '-'), message,
        tonumber(incident and incident.alerted) or 0))
end)

-- 系统自动警报 (车辆盗窃等) — 仅限在勤警察调用 + 每 source 10 秒 1 次
RegisterNetEvent('police:server:autoAlert', function(coords, text)
    local src = source
    -- source 0 means a trusted server-side resource (e.g. custom-vehicles
    -- hotwire alarms) used TriggerEvent; client-originated calls must still be
    -- on-duty police.
    local isSystem = src == 0
    if not isSystem then
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or not PolicePolicy.Can(Player.PlayerData, 'incident.create') then return end
    end
    local cooldownKey = isSystem and 'system' or src

    local now = os.time()
    for otherSrc, lastAt in pairs(autoAlertCooldown) do
        if now - lastAt > 60 then autoAlertCooldown[otherSrc] = nil end
    end
    local last = autoAlertCooldown[cooldownKey]
    if last and now - last < AUTO_ALERT_COOLDOWN then return end

    local alertCoords = sanitizeAlertCoords(coords)
    local message = sanitizeAlertText(text)
    if not alertCoords or not message then return end
    autoAlertCooldown[cooldownKey] = now

    -- 系统警报同样进警情板：车辆防盗、脚本事件都从这里来。
    -- src == 0 没有玩家可校验，所以走系统路径并标明来源。
    local incident
    if isSystem then
        incident = createIncidentForAlert('resource:system', message, alertCoords, 2)
    else
        incident = createIncidentForAlert(src, message, alertCoords, 2)
    end

    print(('[autoAlert] #%s | %s | 值班警察: %d 人'):format(
        tostring(incident and incident.id or '-'), message,
        tonumber(incident and incident.alerted) or 0))
end)

RegisterNetEvent('police:server:UpdateCurrentCops', function()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    if updatingCops then return end
    updatingCops = true
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    TriggerClientEvent('police:SetCopCount', -1, amount)
    updatingCops = false
end)

RegisterNetEvent('police:server:SetHandcuffStatus', function(isHandcuffed)
    local src = source
    -- 🔒 Security: 仅接受 boolean 类型 + 仅限 LEO 或 EMS 调用
    if type(isHandcuffed) ~= 'boolean' then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        -- 只有执法/医疗人员才能设置他人手铐状态；玩家自己不能解锁
        local jobType = Player.PlayerData.job.type
        if isHandcuffed == false then
            -- 解锁手铐：必须是 LEO 或 EMS
            if jobType ~= 'leo' and Player.PlayerData.job.name ~= 'ambulance' then return end
        end
        Player.Functions.SetMetaData('ishandcuffed', isHandcuffed)
    end
end)

RegisterNetEvent('police:server:showFingerprint', function(playerId)
    local src = source
    -- 指纹比对是警察取证动作：在勤 + lookup.citizen 能力
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not PolicePolicy.Can(Player.PlayerData, 'lookup.citizen') then return end
    if not QBCore.Functions.GetPlayer(tonumber(playerId)) then return end
    TriggerClientEvent('police:client:showFingerprint', playerId, src)
    TriggerClientEvent('police:client:showFingerprint', src, playerId)
end)

RegisterNetEvent('police:server:showFingerprintId', function(sessionId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not PolicePolicy.Can(Player.PlayerData, 'lookup.citizen') then return end
    local metadata = Player.PlayerData.metadata
    local fid = type(metadata) == 'table' and metadata['fingerprint'] or nil
    if type(fid) ~= 'string' then return end
    TriggerClientEvent('police:client:showFingerprintId', sessionId, fid)
    TriggerClientEvent('police:client:showFingerprintId', src, fid)
end)

RegisterNetEvent('police:server:SetTracker', function(targetId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local actor = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(targetId)
    -- 电子脚镣是警察动作：在勤 + arrest.create 能力
    if not actor or not Target or not PolicePolicy.Can(actor.PlayerData, 'arrest.create') then return end

    local TrackerMeta = Target.PlayerData.metadata['tracker']
    if TrackerMeta then
        Target.Functions.SetMetaData('tracker', false)
        TriggerClientEvent('QBCore:Notify', targetId, Lang:t('success.anklet_taken_off'), 'success')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.took_anklet_from', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname }), 'success')
        TriggerClientEvent('police:client:SetTracker', targetId, false)
    else
        Target.Functions.SetMetaData('tracker', true)
        TriggerClientEvent('QBCore:Notify', targetId, Lang:t('success.put_anklet'), 'success')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.put_anklet_on', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname }), 'success')
        TriggerClientEvent('police:client:SetTracker', targetId, true)
    end
end)

RegisterNetEvent('police:server:SendTrackerLocation', function(coords, requestId)
    local src = source
    -- 只有真的戴着电子脚镣的人（自己的 metadata）才能上报自己的位置；
    -- 坐标由服务端清洗，requestId 必须是服务器 id，避免拿它当广播目标。
    local Target = QBCore.Functions.GetPlayer(src)
    if not Target then return end
    local metadata = Target.PlayerData.metadata
    if type(metadata) ~= 'table' or metadata['tracker'] ~= true then return end
    local targetSrc = tonumber(requestId)
    if not targetSrc or not QBCore.Functions.GetPlayer(targetSrc) then return end
    local where = sanitizeAlertCoords(coords)
    if not where then return end
    local msg = Lang:t('info.target_location', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname })
    local alertData = {
        title = Lang:t('info.anklet_location'),
        coords = where,
        description = msg
    }
    TriggerClientEvent('police:client:TrackerMessage', targetSrc, msg, where)
    TriggerClientEvent('qb-phone:client:addPoliceAlert', targetSrc, alertData)
end)

-- Threads

CreateThread(function()
    while true do
        Wait(1000 * 60 * 10)
        local curCops = GetCurrentCops()
        TriggerClientEvent('police:SetCopCount', -1, curCops)
    end
end)

CreateThread(function()
    while true do
        Wait(5000)
        UpdateBlips()
    end
end)

-- Items

QBCore.Functions.CreateUseableItem('handcuffs', function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player.Functions.GetItemByName('handcuffs') then return end
    TriggerClientEvent('police:client:CuffPlayerSoft', src)
end)

QBCore.Functions.CreateUseableItem('moneybag', function(source, item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not Player.Functions.GetItemByName('moneybag') or not item.info or item.info == '' then return end
    if not Player.PlayerData.job.type == 'leo' then return end
    if not exports['qb-inventory']:RemoveItem(src, 'moneybag', 1, item.slot, 'qb-policejob:moneybag') then return end
    Player.Functions.AddMoney('cash', tonumber(item.info.cash), 'qb-policejob:moneybag')
end)

-- ==============================================================
-- 警情自动结算：申领 / 到场
-- ==============================================================
-- 到场检测在客户端跑（每秒一次距离），但裁定在这里：服务端用自己的 ped 坐标复算，
-- 客户端坐标一概不采信；nonce 一次性，防止重放"我又到了"。

QBCore.Functions.CreateCallback('police:server:requestArriveNonce', function(source, cb, incidentId)
    if type(PoliceDispatch) ~= 'table' then return cb(nil) end
    local ok, token = pcall(PoliceDispatch.RequestArriveNonce, source, incidentId)
    cb(ok and token or nil)
end)

RegisterNetEvent('police:server:arriveIncident', function(incidentId, token, manual)
    local src = source
    if src == 0 then return end
    if type(PoliceDispatch) ~= 'table' then return end
    local ok, res = pcall(PoliceDispatch.ArriveIncident, src, incidentId, token,
        { manual = manual == true })
    if not ok then
        print(('[police] arrive error src=%s inc=%s %s'):format(
            tostring(src), tostring(incidentId), tostring(res)))
        return
    end
    if res then
        TriggerClientEvent('police:client:arriveResult', src, res)
    end
end)

-- P6-4 草稿箱：agent 解析出的 call 卡草稿（status='draft'）由警员采纳后才上板。
RegisterNetEvent('police:server:draftList', function()
    local src = source
    if src == 0 then return end
    local ok, res = pcall(function() return exports['custom-police']:ListDrafts(src) end)
    if not ok or not res then
        TriggerClientEvent('police:client:draftList', src, { ok = false })
        return
    end
    TriggerClientEvent('police:client:draftList', src, { ok = true, rows = res.rows, count = res.count })
end)

RegisterNetEvent('police:server:adoptDraft', function(incidentId)
    local src = source
    if src == 0 then return end
    -- 采纳是低风险但需要人点的动作：给自己 3 秒冷却，防止连点把整箱草稿一次性发布
    local allowed = true
    if RateLimit and RateLimit.Cooldown then
        allowed = RateLimit.Cooldown(('draft:adopt:%s'):format(src), 3000)
    end
    if not allowed then
        TriggerClientEvent('police:client:draftResult', src, { ok = false, error = 'rate_limited' })
        return
    end
    local ok, res, reason = pcall(function()
        return exports['custom-police']:AdoptDraft(src, incidentId)
    end)
    if not ok or not res then
        TriggerClientEvent('police:client:draftResult', src, { ok = false, error = tostring(reason or res) })
        return
    end
    TriggerClientEvent('police:client:draftResult', src, { ok = true, result = res })
end)

RegisterNetEvent('police:server:claimIncident', function(incidentId)
    local src = source
    if src == 0 then return end
    if type(PoliceDispatch) ~= 'table' then return end
    local ok, res, reason = pcall(PoliceDispatch.ClaimIncident, src, incidentId)
    if not ok or not res then
        TriggerClientEvent('police:client:claimResult', src, { ok = false, error = tostring(reason or res) })
        return
    end
    TriggerClientEvent('police:client:claimResult', src, { ok = true, result = res })
end)
