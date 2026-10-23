-- client/main.lua — 司法系统客户端交互

local QBCore = exports['qb-core']:GetCoreObject()

-- _L i18n 安全兜底: 防止 production-freeze 加载时序问题导致 _L 为 nil
if _L == nil then
    _L = function(key, ...)
        if not key then return '' end
        if select('#', ...) > 0 then
            return ('[%s]'):format(tostring(key))
        end
        return '[' .. tostring(key) .. ']'
    end
end

local isInPrison = false
local prisonTimer = nil

-- ==============================================================
-- 律师通知 (当有案件时触发)
-- ==============================================================

RegisterNetEvent('justice:client:lawyerNotify', function(data)
    local Player = QBCore.Functions.GetPlayerData()
    if not Player or Player.job.name ~= 'lawyer' then return end

    -- 弹窗提示
    QBCore.Functions.Notify(
        ('📋 新案件 %s | 嫌疑人: %s | 罪名: %s | 刑期: %d分钟 — /cases 查看详情'):format(
            data.caseId, data.suspectName,
            table.concat(data.crimes, ', '), data.baseMinutes),
        'primary', 15000)

    -- 地图标记法院
    SetNewWaypoint(Config.Justice.Courthouse.coords.x, Config.Justice.Courthouse.coords.y)
end)

-- ==============================================================
-- 入狱 / 出狱
-- ==============================================================

RegisterNetEvent('justice:client:enterPrison', function(data)
    isInPrison = true
    local remaining = data.sentenceMinutes

    -- 传送到监狱
    local prison = Config.Justice.Prison
    DoScreenFadeOut(500)
    Wait(500)
    SetEntityCoords(PlayerPedId(), prison.interior.x, prison.interior.y, prison.interior.z)
    DoScreenFadeIn(1000)

    -- 开始计时UI
    QBCore.Functions.Notify(('你在监狱中，剩余刑期: %d 分钟'):format(remaining), 'error', 10000)

    -- 客户端计时器 (每分钟更新)
    if prisonTimer then
        -- 清除旧计时器
    end
    prisonTimer = CreateThread(function()
        while remaining > 0 and isInPrison do
            Wait(60000)
            remaining = remaining - 1
            if remaining <= 5 and remaining > 0 then
                QBCore.Functions.Notify(('还有 %d 分钟出狱'):format(remaining), 'primary')
            end
            if remaining <= 0 then
                -- 通知服务端
                TriggerServerEvent('justice:server:sentenceComplete')
                isInPrison = false
                break
            end
        end
    end)
end)

RegisterNetEvent('justice:client:released', function()
    isInPrison = false
    DoScreenFadeOut(500)
    Wait(500)
    SetEntityCoords(PlayerPedId(),
        Config.Justice.Prison.releaseCoords.x,
        Config.Justice.Prison.releaseCoords.y,
        Config.Justice.Prison.releaseCoords.z)
    DoScreenFadeIn(1000)
    QBCore.Functions.Notify('你已出狱，重新获得自由！', 'success', 10000)
end)

RegisterNetEvent('justice:client:verdictReceived', function(verdict)
    -- 嫌疑人收到判决 → 入狱
    TriggerEvent('justice:client:enterPrison', {
        sentenceMinutes = verdict.finalMinutes,
        startTime = os.time(),
        crimes = verdict.crimeLabels,
        reductions = {},
    })
    TriggerServerEvent('justice:server:imprison',
        QBCore.Functions.GetPlayerData().citizenid,
        verdict.finalMinutes,
        {}
    )
end)

-- ==============================================================
-- 法院 / 监狱 Blip
-- ==============================================================

CreateThread(function()
    while not LocalPlayer.state.isLoggedIn do Wait(1000) end

    -- 法院
    local ch = Config.Justice.Courthouse
    if ch.blip then
        local blip = AddBlipForCoord(ch.coords.x, ch.coords.y, ch.coords.z)
        SetBlipSprite(blip, ch.blip.sprite)
        SetBlipDisplay(blip, ch.blip.display or 4)
        SetBlipColour(blip, ch.blip.color)
        SetBlipScale(blip, ch.blip.scale or 0.8)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(_L('blip_courthouse'))
        EndTextCommandSetBlipName(blip)
    end

    -- 监狱
    local pr = Config.Justice.Prison
    if pr.blip then
        local blip = AddBlipForCoord(pr.coords.x, pr.coords.y, pr.coords.z)
        SetBlipSprite(blip, pr.blip.sprite)
        SetBlipDisplay(blip, pr.blip.display or 4)
        SetBlipColour(blip, pr.blip.color)
        SetBlipScale(blip, pr.blip.scale or 0.8)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(_L('blip_state_prison'))
        EndTextCommandSetBlipName(blip)
    end
end)

-- ==============================================================
-- 监狱内交互 (减刑/社区服务)
-- ==============================================================

CreateThread(function()
    while true do
        Wait(0)
        if isInPrison and IsControlJustPressed(0, 38) then -- E键
            local menuItems = {
                {
                    header = '申请良好表现减刑',
                    txt = ('减刑 %d%%'):format(math.floor(Config.Justice.Reductions.good_behavior.rate * 100)),
                    params = {
                        event = 'justice:client:doReduction',
                        args = { type = 'good_behavior' }
                    }
                },
                { header = '关闭', params = { event = 'qb-menu:closeMenu' } }
            }
            exports['qb-menu']:openMenu(menuItems)
        end
    end
end)

RegisterNetEvent('justice:client:doReduction', function(data)
    TriggerServerEvent('justice:server:requestReduction', data.type)
end)

-- justice-client startup print removed
