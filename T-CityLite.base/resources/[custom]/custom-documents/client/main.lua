-- ============================================================
-- Client Presenter Layer
-- 屏幕前方浮动文字 · Notify 反馈 · 头顶 3D 文字(附近玩家) · NUI 扩展钩子
-- ============================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- 活跃出示数据: key = serverId
-- { text, fieldsText, ped, expireAt, isLocal }  -- isLocal: 自己出示的（屏幕前方渲染）
local activePresentations = {}

-- ──────────────────────────────────────────────
-- 事件: 自己出示文档 — 服务端推送
-- ──────────────────────────────────────────────
RegisterNetEvent('custom-documents:client:showDocument', function(data)
    if not data then return end

    local ped = PlayerPedId()

    -- 自身确认 Notify（明确可见）
    QBCore.Functions.Notify(('📋 你出示了 %s'):format(data.label), 'success', 5000)

    -- 屏幕前方浮动文字（自己可见）
    local serverId = GetPlayerServerId(PlayerId())
    activePresentations[serverId] = {
        text = data.displayText or data.label,
        fieldsText = data.fieldsText or '',
        ped = ped,
        expireAt = GetGameTimer() + (data.duration or 8000),
        isLocal = true,
    }
end)

-- ──────────────────────────────────────────────
-- 事件: 附近玩家看到出示 — 显示头顶 3D 文字
-- ──────────────────────────────────────────────
RegisterNetEvent('custom-documents:client:showNearbyDocument', function(data)
    if not data then return end

    -- data.presenterId: 出示者的 server ID
    -- 通过 server ID 找到对应的 ped
    local targetPed = nil
    local allPeds = GetGamePool('CPed')
    for _, p in ipairs(allPeds) do
        if NetworkGetPlayerIndexFromPed(p) >= 0 then
            local sid = GetPlayerServerId(NetworkGetPlayerIndexFromPed(p))
            if sid == data.presenterId then
                targetPed = p
                break
            end
        end
    end
    if not targetPed then return end

    activePresentations[data.presenterId] = {
        text = data.displayText or data.label,
        fieldsText = '',
        ped = targetPed,
        expireAt = GetGameTimer() + (data.duration or 8000),
        isLocal = false,
    }
end)

-- ──────────────────────────────────────────────
-- 渲染线程: 每帧绘制活跃的出示文字
--   isLocal=true  → 屏幕前方浮动文字
--   isLocal=false → 目标玩家头顶 3D 文字
-- ──────────────────────────────────────────────
CreateThread(function()
    while true do
        local now = GetGameTimer()
        local cleanup = {}

        for sid, pres in pairs(activePresentations) do
            if now > pres.expireAt then
                cleanup[#cleanup + 1] = sid
            elseif DoesEntityExist(pres.ped) then
                local coords = GetEntityCoords(pres.ped)
                if pres.isLocal then
                    -- 自己：屏幕前方 0.5 米处显示
                    local camCoords = GetGameplayCamCoord()
                    local camRot = GetGameplayCamRot(2)
                    local forward = vector3(
                        -math.sin(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)),
                        math.cos(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)),
                        math.sin(math.rad(camRot.x))
                    )
                    local pos = camCoords + forward * 1.5
                    QBCore.Functions.DrawText3D(pos.x, pos.y, pos.z + 0.1, pres.text)
                    if pres.fieldsText and #pres.fieldsText > 0 then
                        QBCore.Functions.DrawText3D(pos.x, pos.y, pos.z - 0.06, pres.fieldsText)
                    end
                else
                    -- 其他玩家：头顶上方
                    QBCore.Functions.DrawText3D(coords.x, coords.y, coords.z + 1.15, pres.text)
                end
            end
        end

        for _, sid in ipairs(cleanup) do
            activePresentations[sid] = nil
        end

        Wait(0)
    end
end)

-- ──────────────────────────────────────────────
-- 警察查验证照 — 收到服务端结果后格式化展示
-- ──────────────────────────────────────────────
RegisterNetEvent('custom-documents:client:verifyResult', function(result)
    if not result then return end
    if result.error then
        QBCore.Functions.Notify(result.error, 'error', 5000)
        return
    end

    local lines = {}
    lines[#lines + 1] = ('📋 %s (CID: %s)'):format(result.targetName, result.targetCitizenId)
    lines[#lines + 1] = '───────────────'
    for _, lic in ipairs(result.licenses or {}) do
        lines[#lines + 1] = ('%s: %s'):format(lic.label, lic.statusLabel)
    end

    local msg = table.concat(lines, '\n')
    QBCore.Functions.Notify(msg, 'primary', 8000)
end)

-- ──────────────────────────────────────────────
-- NUI 扩展钩子 (预留)
-- 第三方可监听此事件弹出全屏证件面板
-- TriggerEvent('custom-documents:client:nuiPresent', data)
-- data = { docType, label, fields = { key=val, ... }, targetName }
-- ──────────────────────────────────────────────
