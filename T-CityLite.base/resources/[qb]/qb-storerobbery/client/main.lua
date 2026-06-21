local QBCore = exports['qb-core']:GetCoreObject()

local enableDebugLogs = false
local function DebugPrint(msg)
    if enableDebugLogs then
        print(msg)
    end
end

DebugPrint("^2[qb-storerobbery] Client script successfully loaded!")

local currentRegister = 0
local currentSafe = 0
local copsCalled = false
local CurrentCops = 0
local PlayerJob = {}
local onDuty = false
local usingAdvanced = false

CreateThread(function()
    Wait(1000)
    if QBCore.Functions.GetPlayerData().job ~= nil and next(QBCore.Functions.GetPlayerData().job) then
        PlayerJob = QBCore.Functions.GetPlayerData().job
    end
end)

CreateThread(function()
    while true do
        Wait(1000 * 60 * 5)
        if copsCalled then
            copsCalled = false
        end
    end
end)

CreateThread(function()
    Wait(1000)
    setupRegister()
    setupSafes()
    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local inRange = false
        for k in pairs(Config.Registers) do
            local dist = #(pos - Config.Registers[k][1].xyz)
            if dist <= 1 and Config.Registers[k].robbed then
                inRange = true
                DrawText3Ds(Config.Registers[k][1].xyz, Lang:t('text.the_cash_register_is_empty'))
            end
        end
        if not inRange then
            Wait(2000)
        end
        Wait(3)
    end
end)

-- =============================================================
-- 保险箱交互: ALT 模式 (qb-target CircleZone)
-- 按交互规范: 静态世界物体 → 统一使用 ALT（第三只眼）
-- 移除了旧版 E 键轮询线程（Wait(200) + 19 保险箱距离计算）
-- =============================================================

-- 打开保险箱的通用入口
local function OpenSafeInteraction(safe)
    if Config.Safes[safe].robbed then
        QBCore.Functions.Notify("该保险箱已被打开过了", "error")
        return
    end
    currentSafe = safe
    local pos = GetEntityCoords(PlayerPedId())

    if math.random(1, 100) <= 65 and not QBCore.Functions.IsWearingGloves() then
        TriggerServerEvent('evidence:server:CreateFingerDrop', pos)
    end
    if math.random(100) <= 50 then
        TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
    end

    if Config.Safes[safe].type == 'keypad' then
        SendNUIMessage({ action = 'openKeypad' })
        SetNuiFocus(true, true)
    else
        TriggerNpcFear()
        QBCore.Functions.TriggerCallback('qb-storerobbery:server:getPadlockCombination', function(combination)
            TriggerEvent('SafeCracker:StartMinigame', combination)
        end, safe)
    end

    if not copsCalled then
        local s1, s2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
        local street1 = GetStreetNameFromHashKey(s1)
        local street2 = GetStreetNameFromHashKey(s2)
        local streetLabel = street1
        if street2 ~= nil then streetLabel = streetLabel .. ' ' .. street2 end
        TriggerServerEvent('qb-storerobbery:server:callCops', 'safe', currentSafe, streetLabel, pos)
        copsCalled = true
    end
end

-- 为每个保险箱注册 qb-target 圆形区域（ALT 交互）
CreateThread(function()
    Wait(2000)  -- 等待 Config 加载完毕
    for safe, data in pairs(Config.Safes) do
        local coords = data[1] or data.xyz
        if coords then
            exports['qb-target']:AddCircleZone('storerobbery_safe_' .. safe, coords, 1.5, {
                name = 'storerobbery_safe_' .. safe,
                debugPoly = false,
                useZ = true,
            }, {
                options = {
                    {
                        type = "client",
                        event = "qb-storerobbery:client:trySafe",
                        icon = "fas fa-lock",
                        label = "尝试破解保险箱",
                        safeId = safe,
                    },
                    {
                        type = "client",
                        event = "qb-storerobbery:client:trySafe",
                        icon = "fas fa-check-circle",
                        label = "保险箱已打开",
                        safeId = safe,
                        canInteract = function()
                            return Config.Safes[safe] and Config.Safes[safe].robbed
                        end,
                    },
                },
                distance = 2.0,
            })
        end
    end
    -- storerobbery startup print removed
end)

RegisterNetEvent('qb-storerobbery:client:trySafe', function(data)
    local safe = data.safeId
    if not safe or not Config.Safes[safe] then return end

    -- 通过服务端回调实时校验警察数量（避免 CurrentCops 过期）
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:getMinPolice', function(minPolice)
        if CurrentCops < minPolice then
            QBCore.Functions.Notify(("需要至少 %d 名执勤警察才能打开保险箱"):format(minPolice), "error")
            return
        end
        OpenSafeInteraction(safe)
    end)
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerJob = QBCore.Functions.GetPlayerData().job
    onDuty = true
end)

RegisterNetEvent('QBCore:Client:SetDuty', function(duty)
    onDuty = duty
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    PlayerJob = JobInfo
    onDuty = true
end)

RegisterNetEvent('police:SetCopCount', function(amount)
    CurrentCops = amount
end)

-- 警察门槛读取辅助（优先级: GlobalState > Convar > 默认 2）
local function GetEffectiveMinPolice()
    if GlobalState and GlobalState.crime_min_police_storerobbery ~= nil then
        return GlobalState.crime_min_police_storerobbery
    end
    return Config.MinimumStoreRobberyPolice
end

-- 警察门槛变化时自动更新（GlobalState 自动同步，无需 TriggerClientEvent）
CreateThread(function()
    while true do
        Wait(3000)
        if GlobalState and GlobalState.crime_min_police_storerobbery ~= nil then
            Config.MinimumStoreRobberyPolice = GlobalState.crime_min_police_storerobbery
        end
    end
end)

RegisterNetEvent('lockpicks:UseLockpick', function(isAdvanced)
    DebugPrint("^3[qb-storerobbery] lockpicks:UseLockpick event triggered! isAdvanced: " .. tostring(isAdvanced))
    usingAdvanced = isAdvanced
    local foundRegister = false
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    DebugPrint("^3[qb-storerobbery] Player pos: " .. tostring(pos) .. " | CurrentCops: " .. tostring(CurrentCops) .. " | MinPoliceRequired: " .. tostring(Config.MinimumStoreRobberyPolice))
    for k in pairs(Config.Registers) do
        local dist = #(pos - Config.Registers[k][1].xyz)
        -- Print distances of close registers to avoid F8 spam, but show registers within 10 meters
        if dist < 10.0 then
            DebugPrint(string.format("^3[qb-storerobbery] Nearby Register [%d] dist: %.2f (robbed: %s)", k, dist, tostring(Config.Registers[k].robbed)))
        end
        if dist <= 1.8 and not Config.Registers[k].robbed then
            foundRegister = true
            DebugPrint("^2[qb-storerobbery] In range! Activating register " .. tostring(k))
            -- 使用 GetEffectiveMinPolice() 优先读取 GlobalState（/tccops 实时生效）
            -- 回退到 Config.MinimumStoreRobberyPolice（GlobalState 同步线程每 3 秒更新）
            if CurrentCops >= GetEffectiveMinPolice() then
                if usingAdvanced then
                    lockpick(true)
                    currentRegister = k
                    if not QBCore.Functions.IsWearingGloves() then
                        TriggerServerEvent('evidence:server:CreateFingerDrop', pos)
                    end
                    if not copsCalled then
                        local s1, s2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
                        local street1 = GetStreetNameFromHashKey(s1)
                        local street2 = GetStreetNameFromHashKey(s2)
                        local streetLabel = street1
                        if street2 ~= nil then
                            streetLabel = streetLabel .. ' ' .. street2
                        end
                        TriggerServerEvent('qb-storerobbery:server:callCops', 'cashier', currentRegister, streetLabel, pos)
                        copsCalled = true
                    end
                else
                    lockpick(true)
                    currentRegister = k
                    if not QBCore.Functions.IsWearingGloves() then
                        TriggerServerEvent('evidence:server:CreateFingerDrop', pos)
                    end
                    if not copsCalled then
                        local s1, s2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
                        local street1 = GetStreetNameFromHashKey(s1)
                        local street2 = GetStreetNameFromHashKey(s2)
                        local streetLabel = street1
                        if street2 ~= nil then
                            streetLabel = streetLabel .. ' ' .. street2
                        end
                        TriggerServerEvent('qb-storerobbery:server:callCops', 'cashier', currentRegister, streetLabel, pos)
                        copsCalled = true
                    end
                end
            else
                DebugPrint("^1[qb-storerobbery] Blocked: Not enough police!")
                QBCore.Functions.Notify(Lang:t('error.minimum_store_robbery_police', { MinimumStoreRobberyPolice = Config.MinimumStoreRobberyPolice }), 'error')
            end
        end
    end
    if not foundRegister then
        DebugPrint("^1[qb-storerobbery] lockpick failed: No register in 1.8m range.")
        QBCore.Functions.Notify("当前位置附近没有可抢劫的收银机！(需在 1.8 米内)", "error")
    end
end)

function setupRegister()
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:getRegisterStatus', function(Registers)
        for k in pairs(Registers) do
            Config.Registers[k].robbed = Registers[k].robbed
        end
    end)
end

function setupSafes()
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:getSafeStatus', function(Safes)
        for k in pairs(Safes) do
            Config.Safes[k].robbed = Safes[k].robbed
        end
    end)
end

DrawText3Ds = function(coords, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    BeginTextCommandDisplayText('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(coords, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    local factor = (string.len(text)) / 370
    DrawRect(0.0, 0.0 + 0.0125, 0.017 + factor, 0.03, 0, 0, 0, 75)
    ClearDrawOrigin()
end

function lockpick(bool)
    SetNuiFocus(bool, bool)
    SendNUIMessage({
        action = 'ui',
        toggle = bool,
    })
    SetCursorLocation(0.5, 0.2)
end

function loadAnimDict(dict)
    while (not HasAnimDictLoaded(dict)) do
        RequestAnimDict(dict)
        Wait(100)
    end
end

function takeAnim()
    local ped = PlayerPedId()
    while (not HasAnimDictLoaded('amb@prop_human_bum_bin@idle_b')) do
        RequestAnimDict('amb@prop_human_bum_bin@idle_b')
        Wait(100)
    end
    TaskPlayAnim(ped, 'amb@prop_human_bum_bin@idle_b', 'idle_d', 8.0, 8.0, -1, 50, 0, false, false, false)
    Wait(2500)
    TaskPlayAnim(ped, 'amb@prop_human_bum_bin@idle_b', 'exit', 8.0, 8.0, -1, 50, 0, false, false, false)
end

local openingDoor = false
local npcFearActive = false

-- ==============================================================
-- NPC 恐惧效果（保留原版，加4种反应增强）
-- ==============================================================
local scaredNpcs = {}

local function TriggerNpcFear()
    if npcFearActive then return end
    npcFearActive = true
    scaredNpcs = {}
    local playerPed = PlayerPedId()

    CreateThread(function()
        while npcFearActive do
            local pos = GetEntityCoords(playerPed)
            local nearbyPeds = GetGamePool('CPed')
            for _, ped in ipairs(nearbyPeds) do
                if not IsPedAPlayer(ped) and DoesEntityExist(ped) then
                    local pedHandle = ped
                    if not scaredNpcs[pedHandle] then
                        local pedPos = GetEntityCoords(ped)
                        local dist = #(pos - pedPos)
                        if dist < 40.0 and dist > 1.0 then
                            if not IsPedInAnyVehicle(ped, false) and not IsPedArmed(ped, 7) then
                                scaredNpcs[pedHandle] = true
                                local reactionType = math.random(1, 4)
                                Citizen.CreateThreadNow(function()
                                    Wait(math.random(0, 1200))
                                    if not DoesEntityExist(ped) then return end
                                    if reactionType == 1 then
                                        TaskSmartFleePed(ped, playerPed, 100.0, -1, 0, 0)
                                    elseif reactionType == 2 then
                                        TaskHandsUp(ped, 5000, playerPed, -1, false)
                                    elseif reactionType == 3 then
                                        TaskSmartFleePed(ped, playerPed, 200.0, -1, 0, 0)
                                    else
                                        TaskPause(ped, 2000)
                                        Wait(2000)
                                        if DoesEntityExist(ped) then
                                            TaskSmartFleePed(ped, playerPed, 100.0, -1, 0, 0)
                                        end
                                    end
                                end)
                            end
                        end
                    end
                end
            end
            Wait(5000)
        end
        scaredNpcs = {}
    end)
end

-- =============================================================
-- 良心弹窗通知（右侧30秒, 纯氛围文字, G键自首已移除）
-- 自首入口移至手机 ⚖️ 自首热线
-- =============================================================

RegisterNetEvent('qb-storerobbery:client:conscienceNotify', function(data)
    local msg
    if data.points >= 80 then
        local monologues = {
            "你拿着 $" .. data.reward .. "，手在发抖。这不是你想要的自己。",
            "钱到手了，但心里空落落的。你知道这是错的。",
            "你告诉自己这是最后一次。但上次你也是这么说的。",
        }
        msg = monologues[math.random(1, #monologues)]
    elseif data.points >= 40 then
        local monologues = {
            "你不再感到害怕。这更让人害怕。",
            "店主恐惧的眼神在你脑海里挥之不去。",
            "你开始习惯这种生活了。这真的是你想要的吗？",
        }
        msg = monologues[math.random(1, #monologues)]
    else
        local monologues = {
            "你已经分不清对错了。也许你从来就没在乎过。",
            "梦中你看到那些被你伤害的人。他们不说话，只是看着你。",
            "有人给你指了一条别的路。你还看得到吗？",
        }
        msg = monologues[math.random(1, #monologues)]
    end

    -- 发送到 NUI 右侧弹窗（纯独白，无其他元素）
    SendNUIMessage({
        action = 'openConscienceToast',
        monologue = msg,
    })
end)

-- =============================================================
-- 服务端权威抢劫（原版流程）
-- 撬锁成功 → startRobbery → 25s 动画 → 自动结算
-- =============================================================

RegisterNUICallback('success', function(_, cb)
    if currentRegister ~= 0 then
        lockpick(false)

        -- 通知服务端开始抢劫（服务端校验 + 25s权威计时器）
        TriggerServerEvent('qb-storerobbery:server:startRobbery', currentRegister)

        -- 客户端本地视觉：动画 + 进度条
        local lockpickTime = 25000
        LockpickDoorAnim(lockpickTime)
        QBCore.Functions.Progressbar('search_register', '正在翻收银机...', lockpickTime, false, true, {
            disableMovement = true,
            disableCarMovement = true,
            disableMouse = false,
            disableCombat = true,
        }, {
            animDict = 'veh@break_in@0h@p_m_one@',
            anim = 'low_force_entry_ds',
            flags = 16,
        }, {}, {}, function() -- Done
            openingDoor = false
            npcFearActive = false
            ClearPedTasks(PlayerPedId())
        end, function() -- Cancel / 逃跑
            openingDoor = false
            npcFearActive = false
            ClearPedTasks(PlayerPedId())
            TriggerServerEvent('qb-storerobbery:server:cancelRobbery', currentRegister)
            QBCore.Functions.Notify("已中断抢劫，按已花时间比例结算", "primary")
            currentRegister = 0
        end)
    else
        SendNUIMessage({ action = 'kekw' })
    end
    cb('ok')
end)

-- 服务端通知抢劫完成
RegisterNetEvent('qb-storerobbery:client:robberyComplete', function(register)
    currentRegister = 0
    QBCore.Functions.Notify("抢劫完成！战利品已放入背包", "success")
end)

function LockpickDoorAnim(time)
    time = time / 1000
    loadAnimDict('veh@break_in@0h@p_m_one@')
    TaskPlayAnim(PlayerPedId(), 'veh@break_in@0h@p_m_one@', 'low_force_entry_ds', 3.0, 3.0, -1, 16, 0, false, false, false)
    openingDoor = true
    TriggerNpcFear()
    CreateThread(function()
        while openingDoor do
            TaskPlayAnim(PlayerPedId(), 'veh@break_in@0h@p_m_one@', 'low_force_entry_ds', 3.0, 3.0, -1, 16, 0, 0, 0, 0)
            Wait(2000)
            time = time - 2
            if time <= 0 then
                openingDoor = false
                StopAnimTask(PlayerPedId(), 'veh@break_in@0h@p_m_one@', 'low_force_entry_ds', 1.0)
            end
        end
        npcFearActive = false
        currentRegister = 0
    end)
end

RegisterNUICallback('callcops', function(_, cb)
    TriggerEvent('police:SetCopAlert')
    cb('ok')
end)

RegisterNetEvent('SafeCracker:EndMinigame', function(won)
    npcFearActive = false  -- 保险箱小游戏结束，停止 NPC 恐惧
    if currentSafe ~= 0 then
        if won then
            if currentSafe ~= 0 then
                if not Config.Safes[currentSafe].robbed then
                    SetNuiFocus(false, false)
                    TriggerServerEvent('qb-storerobbery:server:SafeReward', currentSafe)
                    TriggerServerEvent('qb-storerobbery:server:setSafeStatus', currentSafe)
                    currentSafe = 0
                    takeAnim()
                end
            else
                SendNUIMessage({
                    action = 'kekw',
                })
            end
        end
    end
    copsCalled = false
end)

RegisterNUICallback('PadLockSuccess', function(_, cb)
    if currentSafe ~= 0 then
        if not Config.Safes[currentSafe].robbed then
            SendNUIMessage({
                action = 'kekw',
            })
        end
    else
        SendNUIMessage({
            action = 'kekw',
        })
    end
    cb('ok')
end)

RegisterNUICallback('PadLockClose', function(_, cb)
    SetNuiFocus(false, false)
    copsCalled = false
    cb('ok')
end)

RegisterNUICallback('CombinationFail', function(_, cb)
    PlaySound(-1, 'Place_Prop_Fail', 'DLC_Dmod_Prop_Editor_Sounds', 0, 0, 1)
    cb('ok')
end)

RegisterNUICallback('fail', function(_, cb)
    if usingAdvanced then
        if math.random(1, 100) < 20 then
            TriggerServerEvent('qb-storerobbery:server:removeAdvancedLockpick')
            TriggerEvent('qb-inventory:client:ItemBox', QBCore.Shared.Items['advancedlockpick'], 'remove')
        end
    else
        if math.random(1, 100) < 40 then
            TriggerServerEvent('qb-storerobbery:server:removeLockpick')
            TriggerEvent('qb-inventory:client:ItemBox', QBCore.Shared.Items['lockpick'], 'remove')
        end
    end
    if (not QBCore.Functions.IsWearingGloves() and math.random(1, 100) <= 25) then
        local pos = GetEntityCoords(PlayerPedId())
        TriggerServerEvent('evidence:server:CreateFingerDrop', pos)
        QBCore.Functions.Notify(Lang:t('error.you_broke_the_lock_pick'))
    end
    lockpick(false)
    cb('ok')
end)

RegisterNUICallback('exit', function(_, cb)
    lockpick(false)
    cb('ok')
end)

RegisterNUICallback('TryCombination', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:isCombinationRight', function(combination)
        if tonumber(data.combination) ~= nil then
            if tonumber(data.combination) == combination then
                TriggerServerEvent('qb-storerobbery:server:SafeReward', currentSafe)
                TriggerServerEvent('qb-storerobbery:server:setSafeStatus', currentSafe)
                SetNuiFocus(false, false)
                SendNUIMessage({
                    action = 'closeKeypad',
                    error = false,
                })
                currentSafe = 0
                takeAnim()
            else
                TriggerEvent('police:SetCopAlert')
                SetNuiFocus(false, false)
                SendNUIMessage({
                    action = 'closeKeypad',
                    error = true,
                })
                currentSafe = 0
            end
        end
        cb('ok')
    end, currentSafe)
end)

RegisterNetEvent('qb-storerobbery:client:setRegisterStatus', function(batch, val)
    -- Has to be a better way maybe like adding a unique id to identify the register
    if (type(batch) ~= 'table') then
        Config.Registers[batch] = val
    else
        for k in pairs(batch) do
            Config.Registers[k] = batch[k]
        end
    end
end)

RegisterNetEvent('qb-storerobbery:client:setSafeStatus', function(safe, bool)
    Config.Safes[safe].robbed = bool
end)

RegisterNetEvent('qb-storerobbery:client:robberyCall', function(_, _, _, coords)
    if (PlayerJob.name == 'police' or PlayerJob.type == 'leo') and onDuty then
        PlaySound(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', 0, 0, 1)
        TriggerServerEvent('police:server:policeAlert', Lang:t('email.storerobbery_progress'))

        local transG = 250
        local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
        SetBlipSprite(blip, 458)
        SetBlipColour(blip, 1)
        SetBlipDisplay(blip, 4)
        SetBlipAlpha(blip, transG)
        SetBlipScale(blip, 1.0)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(Lang:t('email.shop_robbery'))
        EndTextCommandSetBlipName(blip)
        while transG ~= 0 do
            Wait(180 * 4)
            transG = transG - 1
            SetBlipAlpha(blip, transG)
            if transG == 0 then
                SetBlipSprite(blip, 2)
                RemoveBlip(blip)
                return
            end
        end
    end
end)

-- qb-target integration to bypass inventory lockpick issue
CreateThread(function()
    local models = { 'prop_till_01', 'prop_till_01a' }
    exports['qb-target']:AddTargetModel(models, {
        options = {
            {
                type = "client",
                event = "qb-storerobbery:client:targetLockpick",
                icon = "fas fa-unlock",
                label = "撬收银机 (抢劫商店)",
            }
        },
        distance = 1.8
    })
end)

RegisterNetEvent('qb-storerobbery:client:targetLockpick', function()
    local hasAdvanced = QBCore.Functions.HasItem('advancedlockpick')
    local hasNormal = QBCore.Functions.HasItem('lockpick')
    
    if hasAdvanced then
        TriggerEvent('lockpicks:UseLockpick', true)
    elseif hasNormal then
        TriggerEvent('lockpicks:UseLockpick', false)
    else
        QBCore.Functions.Notify("你没有任何锁撬工具（需要 锁撬 或 高级锁撬）！", "error")
    end
end)

-- =============================================
-- 警察端: 自首警报 (blip + 通知)
-- =============================================

local surrenderBlips = {}

RegisterNetEvent('qb-storerobbery:client:surrenderAlert', function(data)
    local PlayerJob = QBCore.Functions.GetPlayerData().job
    if not (PlayerJob.name == 'police' or PlayerJob.type == 'leo') then return end

    -- 移除旧 blip (如果有)
    if surrenderBlips[data.id] then
        RemoveBlip(surrenderBlips[data.id])
    end

    -- 创建 blip
    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, 458)  -- 类似商店抢劫的红色标记
    SetBlipColour(blip, 2)    -- 红色
    SetBlipDisplay(blip, 4)
    SetBlipAlpha(blip, 250)
    SetBlipScale(blip, 1.2)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(_L('blip_surrender', data.name))
    EndTextCommandSetBlipName(blip)
    SetBlipRoute(blip, true)  -- 显示导航路径

    surrenderBlips[data.id] = blip

    -- 警察通知
    QBCore.Functions.Notify(("⚖️ 自首请求: %s 在 %s 等待自首\n使用 /acceptsurrender %d 确认"):format(
        data.name, data.street, data.id), "success", 10000)

    PlaySound(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', 0, 0, 1)
end)

RegisterNetEvent('qb-storerobbery:client:clearSurrenderBlip', function(surrenderId)
    if surrenderBlips[surrenderId] then
        RemoveBlip(surrenderBlips[surrenderId])
        surrenderBlips[surrenderId] = nil
    end
end)


