local deadAnimDict = 'dead'
local deadAnim = 'dead_a'
local hold = 5
deathTime = 0

-- Functions

local function loadAnimDict(dict)
    while (not HasAnimDictLoaded(dict)) do
        RequestAnimDict(dict)
        Wait(5)
    end
end

function OnDeath()
    if not isDead then
        isDead = true
        LocalPlayer.state:set('isDead', true, true)
        TriggerServerEvent('hospital:server:SetDeathStatus', true)
        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'demo', 0.1)
        local player = PlayerPedId()

        while GetEntitySpeed(player) > 0.5 or IsPedRagdoll(player) do
            Wait(10)
        end

        if isDead then
            local pos = GetEntityCoords(player)
            local heading = GetEntityHeading(player)

            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped) then
                local veh = GetVehiclePedIsIn(ped)
                local vehseats = GetVehicleModelNumberOfSeats(GetHashKey(GetEntityModel(veh)))
                for i = -1, vehseats do
                    local occupant = GetPedInVehicleSeat(veh, i)
                    if occupant == ped then
                        NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
                        SetPedIntoVehicle(ped, veh, i)
                    end
                end
            else
                NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
            end

            SetEntityInvincible(player, true)
            SetEntityHealth(player, GetEntityMaxHealth(player))
            if IsPedInAnyVehicle(player, false) then
                loadAnimDict('veh@low@front_ps@idle_duck')
                TaskPlayAnim(player, 'veh@low@front_ps@idle_duck', 'sit', 1.0, 1.0, -1, 1, 0, 0, 0, 0)
            else
                loadAnimDict(deadAnimDict)
                TaskPlayAnim(player, deadAnimDict, deadAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
            end
            TriggerServerEvent('hospital:server:ambulanceAlert', Lang:t('info.civ_died'))
        end
    end
end

function DeathTimer()
    hold = 5
    while isDead do
        Wait(1000)
        deathTime = deathTime - 1
        if deathTime <= 0 then
            if IsControlPressed(0, 38) and hold <= 0 and not isInHospitalBed then
                TriggerEvent('hospital:client:RespawnAtHospital')
                hold = 5
            end
            if IsControlPressed(0, 38) then
                if hold - 1 >= 0 then
                    hold = hold - 1
                else
                    hold = 0
                end
            end
            if IsControlReleased(0, 38) then
                hold = 5
            end
        end
    end
end

local function DrawTxt(x, y, width, height, scale, text, r, g, b, a, _)
    if GetConvar('qb_locale', 'en') == 'en' then
        SetTextFont(4)
    else
        SetTextFont(1)
    end
    SetTextProportional(0)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextDropShadow(0, 0, 0, 0, 255)
    SetTextEdge(2, 0, 0, 0, 255)
    SetTextDropShadow()
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y - height / 2 + 0.005)
end

-- Damage Handler

AddEventHandler('gameEventTriggered', function(event, data)
    if event == 'CEventNetworkEntityDamage' then
        local victim, attacker, victimDied, weapon = data[1], data[2], data[4], data[7]
        if not IsEntityAPed(victim) then return end
        if victimDied and NetworkGetPlayerIndexFromPed(victim) == PlayerId() and IsEntityDead(PlayerPedId()) then
            if not InLaststand then
                SetLaststand(true)
            elseif InLaststand and not isDead then
                SetLaststand(false)
                local playerid = NetworkGetPlayerIndexFromPed(victim)
                local playerName = GetPlayerName(playerid) .. ' ' .. '(' .. GetPlayerServerId(playerid) .. ')' or Lang:t('info.self_death')
                local killerId = NetworkGetPlayerIndexFromPed(attacker)
                local killerName = GetPlayerName(killerId) .. ' ' .. '(' .. GetPlayerServerId(killerId) .. ')' or Lang:t('info.self_death')
                local weaponLabel = (QBCore.Shared.Weapons and QBCore.Shared.Weapons[weapon] and QBCore.Shared.Weapons[weapon].label) or 'Unknown'
                local weaponName = (QBCore.Shared.Weapons and QBCore.Shared.Weapons[weapon] and QBCore.Shared.Weapons[weapon].name) or 'Unknown'
                TriggerServerEvent('qb-log:server:CreateLog', 'death', Lang:t('logs.death_log_title', { playername = playerName, playerid = GetPlayerServerId(playerid) }), 'red', Lang:t('logs.death_log_message', { killername = killerName, playername = playerName, weaponlabel = weaponLabel, weaponname = weaponName }))
                deathTime = Config.DeathTime
                OnDeath()
                DeathTimer()
            end
        end
    end
end)

-- Threads

emsNotified = false

CreateThread(function()
    while true do
        local sleep = 1000
        if isDead or InLaststand then
            sleep = 5
            local ped = PlayerPedId()
            if IsPauseMenuActive() then
                SetFrontendActive(false)
            end
            DisableAllControlActions(0)
            EnableControlAction(0, 1, true)
            EnableControlAction(0, 2, true)
            EnableControlAction(0, 245, true)
            EnableControlAction(0, 38, true)
            EnableControlAction(0, 0, true)
            EnableControlAction(0, 322, true)
            EnableControlAction(0, 288, true)
            EnableControlAction(0, 213, true)
            EnableControlAction(0, 249, true)
            EnableControlAction(0, 46, true)
            EnableControlAction(0, 47, true)

            if isDead then
                if not isInHospitalBed then
                    if deathTime > 0 then
                        DrawTxt(0.5, 1.30, 1.0, 1.0, 0.6, Lang:t('info.respawn_txt', { deathtime = math.ceil(deathTime) }), 255, 255, 255, 255)
                    else
                        DrawTxt(0.5, 1.30, 1.0, 1.0, 0.6, Lang:t('info.respawn_revive', { holdtime = hold, cost = Config.BillCost }), 255, 255, 255, 255)
                    end
                end

                if IsPedInAnyVehicle(ped, false) then
                    loadAnimDict('veh@low@front_ps@idle_duck')
                    if not IsEntityPlayingAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 3) then
                        TaskPlayAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                    end
                else
                    if isInHospitalBed then
                        if not IsEntityPlayingAnim(ped, inBedDict, inBedAnim, 3) then
                            loadAnimDict(inBedDict)
                            TaskPlayAnim(ped, inBedDict, inBedAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                        end
                    else
                        if not IsEntityPlayingAnim(ped, deadAnimDict, deadAnim, 3) then
                            loadAnimDict(deadAnimDict)
                            TaskPlayAnim(ped, deadAnimDict, deadAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                        end
                    end
                end

                SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
            elseif InLaststand then
                sleep = 5

                -- M-2：秒数本来就有（math.ceil(LaststandTime)），问题是**文案是英文**。
                -- 而且 setr qb_locale 对这套 locale 不生效（见提交说明），所以直接写中文。
                local seconds = math.ceil(LaststandTime)
                if LaststandTime > Config.MinimumRevive then
                    DrawTxt(0.5, 1.30, 1.0, 1.0, 0.6,
                        ('你将在一 ~r~%d~s~ 秒后失去意识'):format(seconds), 255, 255, 255, 255)
                else
                    DrawTxt(0.5, 1.30, 1.0, 1.0, 0.6,
                        ('你将在一 ~r~%d~s~ 秒后失去意识 · 旁边有人能救你'):format(seconds), 255, 255, 255, 255)
                    if not emsNotified then
                        DrawTxt(0.5, 1.26, 1.0, 1.0, 0.6, '按 ~r~E~s~ 呼救（医护会收到）', 255, 255, 255, 255)
                    else
                        DrawTxt(0.5, 1.26, 1.0, 1.0, 0.6, '已呼救，等医护到场', 255, 255, 255, 255)
                    end

                    -- 2026-11-12 PO 真机：「按 E 呼救」按下去毫无反馈。
                    -- 根因：文案写的是 E，代码轮询的却是 **47（INPUT_DETONATE = 键盘 G）** ——
                    -- 按 E 永远进不来，连 cooldown 都不会触发，玩家只能怀疑自己按空了。
                    if IsControlJustPressed(0, 38) and not emsNotified then
                        TriggerServerEvent('hospital:server:ambulanceAlert', Lang:t('info.civ_down'))
                        emsNotified = true
                        -- 按下之后必须有回执：这里是"生死关头"，不能靠玩家自己猜。
                        local okNotice = pcall(function()
                            exports['custom-notify']:PushLocal('feed', '已呼救 · 医护收到了你的位置')
                        end)
                        if not okNotice then
                            QBCore.Functions.Notify('已呼救 · 医护收到了你的位置', 'success')
                        end
                    end
                end

                if not isEscorted then
                    if IsPedInAnyVehicle(ped, false) then
                        loadAnimDict('veh@low@front_ps@idle_duck')
                        if not IsEntityPlayingAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 3) then
                            TaskPlayAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                        end
                    else
                        loadAnimDict(lastStandDict)
                        if not IsEntityPlayingAnim(ped, lastStandDict, lastStandAnim, 3) then
                            TaskPlayAnim(ped, lastStandDict, lastStandAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                        end
                    end
                else
                    if IsPedInAnyVehicle(ped, false) then
                        loadAnimDict('veh@low@front_ps@idle_duck')
                        if IsEntityPlayingAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 3) then
                            StopAnimTask(ped, 'veh@low@front_ps@idle_duck', 'sit', 3)
                        end
                    else
                        loadAnimDict(lastStandDict)
                        if IsEntityPlayingAnim(ped, lastStandDict, lastStandAnim, 3) then
                            StopAnimTask(ped, lastStandDict, lastStandAnim, 3)
                        end
                    end
                end
            end
        end
        Wait(sleep)
    end
end)
