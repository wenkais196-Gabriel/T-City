-- Variables
local CurrentStatusList = {}
local Casings = {}
local CurrentCasing = nil
local Blooddrops = {}
local CurrentBlooddrop = nil
local Fingerprints = {}
local CurrentFingerprint = 0
local shotAmount = 0

local StatusList = {
    ['fight'] = Lang:t('evidence.red_hands'),
    ['widepupils'] = Lang:t('evidence.wide_pupils'),
    ['redeyes'] = Lang:t('evidence.red_eyes'),
    ['weedsmell'] = Lang:t('evidence.weed_smell'),
    ['gunpowder'] = Lang:t('evidence.gunpowder'),
    ['chemicals'] = Lang:t('evidence.chemicals'),
    ['heavybreath'] = Lang:t('evidence.heavy_breathing'),
    ['sweat'] = Lang:t('evidence.sweat'),
    ['handbleed'] = Lang:t('evidence.handbleed'),
    ['confused'] = Lang:t('evidence.confused'),
    ['alcohol'] = Lang:t('evidence.alcohol'),
    ['heavyalcohol'] = Lang:t('evidence.heavy_alcohol'),
    ['agitated'] = Lang:t('evidence.agitated')
}

local WhitelistedWeapons = {
    `weapon_unarmed`,
    `weapon_snowball`,
    `weapon_stungun`,
    `weapon_petrolcan`,
    `weapon_hazardcan`,
    `weapon_fireextinguisher`
}

-- Functions
local DrawText3D = CFShared and CFShared.DrawText3D
if not DrawText3D then
    print('[custom-police] ⚠ core-framework/client/shared.lua 未包含，3D 文字不显示')
    DrawText3D = function() end
end

-- 诊断（也是这个文件"真的在客户端跑起来了"的唯一证据：就绪信标只能证明 shared.lua 被包含）。
-- 服务端限流 10 条/分钟，所以这里只有进服一次 + 每次异常路径（节流 5 秒）才会说话。
local lastDiag = 0
local function reportDebug(message)
    if not (CFShared and CFShared.Report) then return end
    local now = GetGameTimer()
    if now - lastDiag < 5000 then return end
    lastDiag = now
    CFShared.Report('info', message)
end
reportDebug('evidence client loaded')

--- 这层用途单一：把"看不到弹壳"拆成三段——没检测到开枪 / 看到了但没发 / 发了服务端没建。
local function weaponLabel(weapon)
    return tostring(weapon)
end

local function WhitelistedWeapon(weapon)
    for i = 1, #WhitelistedWeapons do
        if WhitelistedWeapons[i] == weapon then
            return true
        end
    end
    return false
end

local function DropBulletCasing(weapon, ped)
    local randX = math.random() + math.random(-1, 1)
    local randY = math.random() + math.random(-1, 1)
    local coords = GetOffsetFromEntityInWorldCoords(ped, randX, randY, 0)
    -- 发**普通表**，不发 vector3：对面 sanitizeCoords 只接受 {x,y,z} 表，vector3 到了服务端
    -- 是原生类型，会被判成"坐标非法"。之前每一枪都因此被静默丢弃（日志只有 rejected）。
    local drop = { x = coords.x, y = coords.y, z = coords.z }
    TriggerServerEvent('evidence:server:CreateCasing', weapon, drop)
    reportDebug(('casing sent weapon=%s onduty=%s'):format(
        weaponLabel(weapon), tostring(type(PlayerJob) == 'table' and PlayerJob.onduty)))
    if GetConvarInt('tcity_evidence_debug', 0) == 1 then
        print(('[custom-police] casing sent weapon=%s at %.2f,%.2f,%.2f')
            :format(tostring(weapon), coords.x, coords.y, coords.z))
    end
    Wait(300)
end

local function DnaHash(s)
    local h = string.gsub(s, '.', function(c)
        return string.format('%02x', string.byte(c))
    end)
    return h
end

-- Events
RegisterNetEvent('evidence:client:SetStatus', function(statusId, time)
    if time > 0 and StatusList[statusId] then
        if (CurrentStatusList == nil or CurrentStatusList[statusId] == nil) or
            (CurrentStatusList[statusId] and CurrentStatusList[statusId].time < 20) then
            CurrentStatusList[statusId] = {
                text = StatusList[statusId],
                time = time
            }
            QBCore.Functions.Notify(CurrentStatusList[statusId].text, 'error')
        end
    elseif StatusList[statusId] then
        CurrentStatusList[statusId] = nil
    end
    TriggerServerEvent('evidence:server:UpdateStatus', CurrentStatusList)
end)

RegisterNetEvent('evidence:client:AddBlooddrop', function(bloodId, citizenid, bloodtype, coords)
    Blooddrops[bloodId] = {
        citizenid = citizenid,
        bloodtype = bloodtype,
        coords = {
            x = coords.x,
            y = coords.y,
            z = coords.z - 0.9
        }
    }
end)

RegisterNetEvent('evidence:client:RemoveBlooddrop', function(bloodId)
    Blooddrops[bloodId] = nil
    CurrentBlooddrop = 0
end)

RegisterNetEvent('evidence:client:AddFingerPrint', function(fingerId, fingerprint, coords)
    Fingerprints[fingerId] = {
        fingerprint = fingerprint,
        coords = {
            x = coords.x,
            y = coords.y,
            z = coords.z - 0.9
        }
    }
end)

RegisterNetEvent('evidence:client:RemoveFingerprint', function(fingerId)
    Fingerprints[fingerId] = nil
    CurrentFingerprint = 0
end)

RegisterNetEvent('evidence:client:ClearBlooddropsInArea', function()
    local pos = GetEntityCoords(PlayerPedId())
    local blooddropList = {}
    QBCore.Functions.Progressbar('clear_blooddrops', Lang:t('progressbar.blood_clear'), 5000, false, true, {
        disableMovement = false,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true
    }, {}, {}, {}, function() -- Done
        if Blooddrops and next(Blooddrops) then
            for bloodId, _ in pairs(Blooddrops) do
                if #(pos -
                        vector3(Blooddrops[bloodId].coords.x, Blooddrops[bloodId].coords.y, Blooddrops[bloodId].coords.z)) <
                    10.0 then
                    blooddropList[#blooddropList + 1] = bloodId
                end
            end
            TriggerServerEvent('evidence:server:ClearBlooddrops', blooddropList)
            QBCore.Functions.Notify(Lang:t('success.blood_clear'), 'success')
        end
    end, function() -- Cancel
        QBCore.Functions.Notify(Lang:t('error.blood_not_cleared'), 'error')
    end)
end)

RegisterNetEvent('evidence:client:AddCasing', function(casingId, weapon, coords, serie)
    Casings[casingId] = {
        type = weapon,
        serie = serie and serie or Lang:t('evidence.serial_not_visible'),
        coords = {
            x = coords.x,
            y = coords.y,
            z = coords.z - 0.9
        }
    }
end)

RegisterNetEvent('evidence:client:RemoveCasing', function(casingId)
    Casings[casingId] = nil
    CurrentCasing = 0
end)

RegisterNetEvent('evidence:client:ClearCasingsInArea', function()
    local pos = GetEntityCoords(PlayerPedId())
    local casingList = {}
    QBCore.Functions.Progressbar('clear_casings', Lang:t('progressbar.bullet_casing'), 5000, false, true, {
        disableMovement = false,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true
    }, {}, {}, {}, function() -- Done
        if Casings and next(Casings) then
            for casingId, _ in pairs(Casings) do
                if #(pos - vector3(Casings[casingId].coords.x, Casings[casingId].coords.y, Casings[casingId].coords.z)) <
                    10.0 then
                    casingList[#casingList + 1] = casingId
                end
            end
            TriggerServerEvent('evidence:server:ClearCasings', casingList)
            QBCore.Functions.Notify(Lang:t('success.bullet_casing_removed'), 'success')
        end
    end, function() -- Cancel
        QBCore.Functions.Notify(Lang:t('error.bullet_casing_not_removed'), 'error')
    end)
end)

-- ── 落点提示（执法特权） ────────────────────────────────────────────────────
-- 原生玩法只有"手电照着 + 1.5 米内"才浮出文字，实测结果就是：**地上有东西，没人发现**。
-- 这一层只负责"指位置"——值班执法人员在 25 米内能看到一枚小箭头 + 距离；
-- 拾取流程一点没变（仍然要走到 1.5 米内按 G）。平民和下班状态看不到，证据位置不对外暴露。
--
-- 三种地面证据（弹壳/血迹/指纹）共用这一层，只是颜色和标签不同：它们在图上的显示、
-- 采集方式（手电 + 1.5 米 + G + 空证据袋）完全一样，发现难度也就一样。
EvidenceHints = EvidenceHints or {}
local HINT_RANGE = 25.0

local function drawDrops(drops, pos, colour, label)
    local drawn = 0
    for _, drop in pairs(drops) do
        local c = drop.coords
        if c then
            local dist = #(pos - vector3(c.x, c.y, c.z))
            if dist <= HINT_RANGE then
                -- 细柱标出地面位置（DrawMarker 1 = 圆柱），上面再挂一个向下的箭头文字
                DrawMarker(1, c.x, c.y, c.z + 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.3, 0.3, 0.6, colour[1], colour[2], colour[3], 150, false, true, 2, false)
                DrawText3D(c.x, c.y, c.z + 1.1, ('▼ %s · %.1fm'):format(label, dist))
                drawn = drawn + 1
            end
        end
    end
    return drawn
end

--- 画当前所有落在范围内的地面证据提示，返回画了几个。
--- 抽成函数是为了能被单测直接调用（线程里的 while true 没法测）。
---@param pos vector3 玩家坐标
---@return number drawn
function EvidenceHints.DrawDrops(pos)
    if type(PlayerJob) ~= 'table' or PlayerJob.type ~= 'leo' or PlayerJob.onduty ~= true then
        return 0
    end
    return drawDrops(Casings, pos, { 255, 70, 70 }, Lang:t('info.casing'))
        + drawDrops(Blooddrops, pos, { 150, 25, 25 }, Lang:t('info.blood'))
        + drawDrops(Fingerprints, pos, { 90, 200, 255 }, Lang:t('info.fingerprint'))
end

-- Threads

CreateThread(function()
    while true do
        Wait(10000)
        if LocalPlayer.state.isLoggedIn then
            if CurrentStatusList and next(CurrentStatusList) then
                for k, _ in pairs(CurrentStatusList) do
                    if CurrentStatusList[k].time > 0 then
                        CurrentStatusList[k].time = CurrentStatusList[k].time - 10
                    else
                        CurrentStatusList[k].time = 0
                    end
                end
                TriggerServerEvent('evidence:server:UpdateStatus', CurrentStatusList)
            end
            if shotAmount > 0 then
                shotAmount = 0
            end
        end
    end
end)

CreateThread(function() -- Gunpowder Status when shooting
    while true do
        Wait(1)
        local ped = PlayerPedId()
        if IsPedShooting(ped) then
            local weapon = GetSelectedPedWeapon(ped)
            if WhitelistedWeapon(weapon) then
                -- 这些是"本来就不该掉弹壳"的武器（徒手/雪球/电击枪/油桶…），
                -- 但如果玩家以为自己在开枪却什么都没发生，这里必须留痕。
                reportDebug(('shot with non-casing weapon=%s'):format(weaponLabel(weapon)))
            else
                shotAmount = shotAmount + 1
                if shotAmount > 5 and (CurrentStatusList == nil or CurrentStatusList['gunpowder'] == nil) then
                    if math.random(1, 10) <= 7 then
                        TriggerEvent('evidence:client:SetStatus', 'gunpowder', 200)
                    end
                end
                DropBulletCasing(weapon, ped)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1)
        -- 每帧只取一次 ped 与坐标：三个分支各自 GetEntityCoords(PlayerPedId()) 是白跑的
        local playerPed = PlayerPedId()
        local pos = GetEntityCoords(playerPed)
        EvidenceHints.DrawDrops(pos)
        if CurrentCasing and CurrentCasing ~= 0 then
            if #(pos - vector3(Casings[CurrentCasing].coords.x, Casings[CurrentCasing].coords.y, Casings[CurrentCasing].coords.z)) < 1.5 then
                DrawText3D(Casings[CurrentCasing].coords.x, Casings[CurrentCasing].coords.y, Casings[CurrentCasing].coords.z, Lang:t('info.bullet_casing', { value = Casings[CurrentCasing].type }))
                if IsControlJustReleased(0, 47) then
                    local s1, s2 = GetStreetNameAtCoord(Casings[CurrentCasing].coords.x, Casings[CurrentCasing].coords.y, Casings[CurrentCasing].coords.z)
                    local street1 = GetStreetNameFromHashKey(s1)
                    local street2 = GetStreetNameFromHashKey(s2)
                    local streetLabel = street1
                    if street2 then
                        streetLabel = streetLabel .. ' | ' .. street2
                    end
                    local info = {
                        label = Lang:t('info.casing'),
                        type = 'casing',
                        street = streetLabel:gsub("%'", ''),
                        ammolabel = Config.AmmoLabels[QBCore.Shared.Weapons[Casings[CurrentCasing].type]['ammotype']],
                        ammotype = Casings[CurrentCasing].type,
                        serie = Casings[CurrentCasing].serie
                    }
                    TriggerServerEvent('evidence:server:AddCasingToInventory', CurrentCasing, info)
                end
            end
        end

        if CurrentBlooddrop and CurrentBlooddrop ~= 0 then
            if #(pos - vector3(Blooddrops[CurrentBlooddrop].coords.x, Blooddrops[CurrentBlooddrop].coords.y,
                    Blooddrops[CurrentBlooddrop].coords.z)) < 1.5 then
                DrawText3D(Blooddrops[CurrentBlooddrop].coords.x, Blooddrops[CurrentBlooddrop].coords.y, Blooddrops[CurrentBlooddrop].coords.z, Lang:t('info.blood_text', { value = DnaHash(Blooddrops[CurrentBlooddrop].citizenid) }))
                if IsControlJustReleased(0, 47) then
                    local s1, s2 = GetStreetNameAtCoord(Blooddrops[CurrentBlooddrop].coords.x, Blooddrops[CurrentBlooddrop].coords.y, Blooddrops[CurrentBlooddrop].coords.z)
                    local street1 = GetStreetNameFromHashKey(s1)
                    local street2 = GetStreetNameFromHashKey(s2)
                    local streetLabel = street1
                    if street2 then
                        streetLabel = streetLabel .. ' | ' .. street2
                    end
                    local info = {
                        label = Lang:t('info.blood'),
                        type = 'blood',
                        street = streetLabel:gsub("%'", ''),
                        dnalabel = DnaHash(Blooddrops[CurrentBlooddrop].citizenid),
                        bloodtype = Blooddrops[CurrentBlooddrop].bloodtype
                    }
                    TriggerServerEvent('evidence:server:AddBlooddropToInventory', CurrentBlooddrop, info)
                end
            end
        end

        if CurrentFingerprint and CurrentFingerprint ~= 0 then
            if #(pos - vector3(Fingerprints[CurrentFingerprint].coords.x, Fingerprints[CurrentFingerprint].coords.y,
                    Fingerprints[CurrentFingerprint].coords.z)) < 1.5 then
                DrawText3D(Fingerprints[CurrentFingerprint].coords.x, Fingerprints[CurrentFingerprint].coords.y, Fingerprints[CurrentFingerprint].coords.z, Lang:t('info.fingerprint_text'))
                if IsControlJustReleased(0, 47) then
                    local s1, s2 = GetStreetNameAtCoord(Fingerprints[CurrentFingerprint].coords.x, Fingerprints[CurrentFingerprint].coords.y, Fingerprints[CurrentFingerprint].coords.z)
                    local street1 = GetStreetNameFromHashKey(s1)
                    local street2 = GetStreetNameFromHashKey(s2)
                    local streetLabel = street1
                    if street2 then
                        streetLabel = streetLabel .. ' | ' .. street2
                    end
                    local info = {
                        label = Lang:t('info.fingerprint'),
                        type = 'fingerprint',
                        street = streetLabel:gsub("%'", ''),
                        fingerprint = Fingerprints[CurrentFingerprint].fingerprint
                    }
                    TriggerServerEvent('evidence:server:AddFingerprintToInventory', CurrentFingerprint, info)
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(10)
        if LocalPlayer.state.isLoggedIn then
            if PlayerJob.type == 'leo' and PlayerJob.onduty then
                if IsPlayerFreeAiming(PlayerId()) and GetSelectedPedWeapon(PlayerPedId()) == `WEAPON_FLASHLIGHT` then
                    if next(Casings) then
                        local pos = GetEntityCoords(PlayerPedId(), true)
                        for k, v in pairs(Casings) do
                            local dist = #(pos - vector3(v.coords.x, v.coords.y, v.coords.z))
                            if dist < 1.5 then
                                CurrentCasing = k
                            end
                        end
                    end
                    if next(Blooddrops) then
                        local pos = GetEntityCoords(PlayerPedId(), true)
                        for k, v in pairs(Blooddrops) do
                            local dist = #(pos - vector3(v.coords.x, v.coords.y, v.coords.z))
                            if dist < 1.5 then
                                CurrentBlooddrop = k
                            end
                        end
                    end
                    if next(Fingerprints) then
                        local pos = GetEntityCoords(PlayerPedId(), true)
                        for k, v in pairs(Fingerprints) do
                            local dist = #(pos - vector3(v.coords.x, v.coords.y, v.coords.z))
                            if dist < 1.5 then
                                CurrentFingerprint = k
                            end
                        end
                    end
                else
                    Wait(1000)
                end
            else
                Wait(5000)
            end
        end
    end
end)
