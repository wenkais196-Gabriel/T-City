-- client/incident_guidance.lua — 警情路线 + 自动到场
--
-- 两个按钮时代留下的问题：「到场」是让玩家汇报引擎已经知道的事。这里把到场改成
-- 观测：每秒算一次与现场的距离，命中（连续 2 次、垂直容差内）就向服务端申请 nonce，
-- 由服务端用 ped 坐标复算后结算。玩家什么都不用点。
--
-- 常量全部来自 shared/policy.lua 的 PoliceIncidentRules（客户端与服务端同一份）。

local QBCore = exports['qb-core']:GetCoreObject()
local RULES = PoliceIncidentRules

local activeRoute = nil          -- { id, blip }
local watcher = nil              -- 当前检测线程
local lastClaimAt = 0
local CLAIM_COOLDOWN_MS = 2000

local function notify(text, kind)
    QBCore.Functions.Notify(text, kind or 'police', 4000)
end

local function clearRoute()
    if activeRoute and activeRoute.blip and DoesBlipExist(activeRoute.blip) then
        RemoveBlip(activeRoute.blip)
    end
    activeRoute = nil
    if watcher then watcher = nil end
end

--- 画一条带距离的路线（与手机 MDT 的手动导航同一套画法）
local function drawRoute(payload)
    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    if not (x and y and z) then return false end
    clearRoute()

    local label = type(payload.label) == 'string' and payload.label:gsub('[%c]', ' '):sub(1, 64) or '警情现场'
    local blip = AddBlipForCoord(x, y, z)
    SetBlipSprite(blip, 60)
    SetBlipColour(blip, 1)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, 1)
    SetBlipDisplay(blip, 2)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)

    activeRoute = { id = tonumber(payload.id), blip = blip }
    return true
end

--- 到场检测：只在有活跃单时跑，命中一次就退出（服务端会回 arriveResult）
local function startWatcher(payload)
    local target = vector3(tonumber(payload.x), tonumber(payload.y), tonumber(payload.z))
    local incidentId = tonumber(payload.id)
    local hits = 0
    local mine = {}

    mine[#mine + 1] = CreateThread(function()
        while activeRoute and activeRoute.id == incidentId do
            Wait(RULES.POLL_INTERVAL)
            if not activeRoute or activeRoute.id ~= incidentId then break end

            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            local flat = #(vector2(coords.x, coords.y) - vector2(target.x, target.y))
            local vertical = math.abs(coords.z - target.z)
            local inside = flat <= RULES.ARRIVE_RADIUS and vertical <= RULES.ARRIVE_VERTICAL

            if inside then
                hits = hits + 1
                if hits >= RULES.DWELL_TICKS then
                    -- 命中：申请 nonce，由服务端裁定（客户端说的不算）
                    QBCore.Functions.TriggerCallback('police:server:requestArriveNonce',
                        function(nonce)
                            if nonce then
                                TriggerServerEvent('police:server:arriveIncident', incidentId, nonce, false)
                            else
                                hits = 0
                            end
                        end, incidentId)
                    hits = 0
                    Wait(3000)   -- 给服务端一次往返，避免刷请求
                end
            else
                -- 滞回：真的离开了才清零，边界抖动不会反复触发
                if flat > RULES.ARRIVE_RADIUS * RULES.RESET_MULTIPLIER or vertical > RULES.ARRIVE_VERTICAL * 2 then
                    hits = 0
                end
            end
        end
    end)
end

RegisterNetEvent('police:client:routeToIncident', function(payload)
    if type(payload) ~= 'table' then return end
    if not drawRoute(payload) then return end
    notify(('🧭 已规划路线：#%s'):format(tostring(payload.id)), 'success')
    startWatcher(payload)
end)

RegisterNetEvent('police:client:claimResult', function(res)
    if type(res) ~= 'table' or not res.ok then
        notify(('申领失败：%s'):format(tostring(res and res.error or 'unknown')), 'error')
        return
    end
    local r = res.result or {}
    notify(('✅ 已接手 #%s（%s）'):format(tostring(r.id), tostring(r.role or 'primary')), 'success')
end)

RegisterNetEvent('police:client:arriveResult', function(res)
    if type(res) ~= 'table' then return end
    clearRoute()
    notify(('📍 已到场 #%s（自动记录）'):format(tostring(res.id)), 'success')
end)

--- 别的单位到场：不需要我做什么，只是让路线收起来（同一现场已经有人在了）
RegisterNetEvent('police:client:incidentArrived', function(payload)
    if type(payload) ~= 'table' then return end
    if activeRoute and activeRoute.id == tonumber(payload.id) then
        -- 本人到场由 arriveResult 处理；这里只处理同单其它单位到场
        local myCid = QBCore.Functions.GetPlayerData().citizenid
        if payload.by ~= myCid then
            notify(('👮 已有单位到达 #%s'):format(tostring(payload.id)), 'primary')
        end
    end
end)

RegisterNetEvent('police:client:clearIncidentRoute', function(incidentId)
    if not activeRoute then return end
    if not incidentId or activeRoute.id == tonumber(incidentId) then clearRoute() end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearRoute() end
end)
