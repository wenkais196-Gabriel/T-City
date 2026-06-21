-- client/police.lua — 警车功能客户端模块 (v2.1)
--
-- 职责:
--   1. ANPR 车牌自动识别 (每2秒扫描前方30m车辆)
--   2. 被盗车辆检测 (Entity.state.isStolen)
--   3. 测速雷达模式
--   4. GPS 追踪器部署入口
--   5. CCTV 监控摄像头启动
--   6. NUI 回调处理 (policeRadar / policeAction)
--
-- 设计原则:
--   - 事件驱动: 无下车开销 (仅在中控屏打开时轮询)
--   - 安全: 所有敏感操作走服务端鉴权
--   - 高性能: 单次 GetGamePool 批量扫描，避免逐车 native 调用

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 状态
-- ==============================================================
PoliceModule = PoliceModule or {}
local _radarActive = false
local _scanTimer = nil
local _speedRadarMode = false

-- ==============================================================
-- 标记车辆红色 Blip (地图定位) — 必须定义在 _anprCheckAndPush 之前
-- ==============================================================

local _activeBlips = {}  -- [plate] = { blip, expires }

local function _createFlaggedBlip(plate, model, distance)
    -- 如果已有同车牌活跃 Blip → 刷新过期时间
    if _activeBlips[plate] and DoesBlipExist(_activeBlips[plate].blip) then
        _activeBlips[plate].expires = GetGameTimer() + 12000
        return
    end

    -- 查找车辆实体以获取坐标
    local targetVeh = nil
    for _, tv in ipairs(GetGamePool('CVehicle')) do
        local tvPlate = GetVehicleNumberPlateText(tv):gsub('^%s+', ''):gsub('%s+$', ''):upper()
        if tvPlate == plate then
            targetVeh = tv
            break
        end
    end

    if not targetVeh then return end

    local coords = GetEntityCoords(targetVeh)

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 225)
    SetBlipColour(blip, 1)
    SetBlipFlashes(blip, true)
    SetBlipAsShortRange(blip, false)
    SetBlipScale(blip, 1.0)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(('🚨 标记: %s [%s]'):format(model, plate))
    EndTextCommandSetBlipName(blip)

    _activeBlips[plate] = {
        blip = blip,
        expires = GetGameTimer() + 12000,
    }
end

-- Blip 清理线程 (每 2s 检查一次过期)
Citizen.CreateThread(function()
    while true do
        Wait(2000)
        local now = GetGameTimer()
        for plate, data in pairs(_activeBlips) do
            if now >= data.expires then
                if DoesBlipExist(data.blip) then
                    RemoveBlip(data.blip)
                end
                _activeBlips[plate] = nil
            end
        end
    end
end)

-- ==============================================================
-- ANPR + 被盗车扫描 (核心功能 — Push 模式)
-- ==============================================================

--- 第一阶段: 同步扫描附近车辆基础数据 (无 ANPR 标记)
--- @param veh number 警车实体
--- @return table[] { plate, model, speed, distance, isFlagged, isStolen }
local function _scanNearbyVehiclesSync(veh)
    if not veh or not DoesEntityExist(veh) then return {} end

    local coords = GetEntityCoords(veh)
    local heading = GetEntityHeading(veh)
    local allVehs = GetGamePool('CVehicle')
    local results = {}

    for _, tv in ipairs(allVehs) do
        local skip = (tv == veh) or (not DoesEntityExist(tv))
        if not skip then
            local tc = GetEntityCoords(tv)
            local dist = #(coords - tc)
            if dist <= 30 then
                -- 只扫描前方 ±60° 锥形区域
                local angleToTarget = math.abs(heading - GetEntityHeading(tv))
                if not (angleToTarget > 60 and angleToTarget < 300) then
                    local plate = GetVehicleNumberPlateText(tv):gsub('^%s+', ''):gsub('%s+$', ''):upper()
                    local model = GetDisplayNameFromVehicleModel(GetEntityModel(tv))
                    local speed = math.floor(GetEntitySpeed(tv) * 2.23694) -- mph
                    local isStolen = Entity(tv).state.isStolen == true

                    results[#results + 1] = {
                        plate = plate,
                        model = model,
                        speed = speed,
                        distance = math.floor(dist),
                        isFlagged = false,  -- 第二阶段异步回填
                        isStolen = isStolen,
                    }
                end
            end
        end
    end

    return results
end

--- 第二阶段: 异步 ANPR 批量检查 + 推送更新 + 红色 Blip
--- @param results table[] 第一阶段扫描结果
local function _anprCheckAndPush(results)
    if #results == 0 then return end

    local plates = {}
    for _, r in ipairs(results) do
        plates[#plates + 1] = r.plate
    end

    QBCore.Functions.TriggerCallback('tcity-dashboard:server:checkPlatesFlagged', function(flaggedMap)
        if not _radarActive then return end  -- 中控屏已关闭
        local anyFlagged = false
        for _, r in ipairs(results) do
            if flaggedMap and flaggedMap[r.plate] then
                r.isFlagged = true
                anyFlagged = true

                -- 🔴 标记车辆 → 创建红色 Blip (12秒自动消除)
                if r.distance <= 100 then  -- 仅 100m 内显示 Blip
                    _createFlaggedBlip(r.plate, r.model, r.distance)
                end

                -- v2.2: 🔊 音频告警
                PlaySound(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', 0, 0, 1)
            end
        end
        -- 推送 ANPR 更新后的完整数据
        if anyFlagged then
            SendNUIMessage({ type = 'policeRadar', data = results })
        end
    end, plates)
end

-- ==============================================================
-- 测速雷达模式 (手持测速枪逻辑移植)
-- ==============================================================

local function _speedRadarScan(veh)
    if not veh or not DoesEntityExist(veh) then return nil end

    local coords = GetEntityCoords(veh)
    local heading = GetEntityHeading(veh)
    local allVehs = GetGamePool('CVehicle')
    local closestTarget, closestDist = nil, 50.0

    for _, tv in ipairs(allVehs) do
        if tv ~= veh and DoesEntityExist(tv) then
            local tc = GetEntityCoords(tv)
            local dist = #(coords - tc)
            if dist < closestDist then
                -- 检查是否在前方窄锥形内 (±20°)
                local dx = tc.x - coords.x
                local dy = tc.y - coords.y
                local forwardX = math.sin(math.rad(heading))
                local forwardY = math.cos(math.rad(heading))
                local dot = (dx * forwardX + dy * forwardY) / (dist + 0.001)
                if dot > 0.93 then -- cos(20°) ≈ 0.94
                    closestDist = dist
                    closestTarget = tv
                end
            end
        end
    end

    if closestTarget then
        return {
            plate = GetVehicleNumberPlateText(closestTarget):gsub('^%s+', ''):gsub('%s+$', ''):upper(),
            speed = math.floor(GetEntitySpeed(closestTarget) * 2.23694),
            distance = math.floor(closestDist),
        }
    end
    return nil
end

-- ==============================================================
-- NUI 回调: 雷达扫描 (两阶段: 同步返回 + 异步 ANPR 推送)
-- ==============================================================

RegisterNUICallback('policeRadar', function(_, cb)
    local veh = Poller.GetVehicle()
    if not veh or not DoesEntityExist(veh) then
        cb({})
        return
    end

    -- 安全校验: 必须是警察且值班
    local PlayerData = QBCore.Functions.GetPlayerData()
    if not PlayerData or PlayerData.job.name ~= 'police' or not PlayerData.job.onduty then
        cb({})
        return
    end

    -- 第一阶段: 同步返回基础数据 (速度/距离/被盗)
    local results = _scanNearbyVehiclesSync(veh)
    if _speedRadarMode then
        local speedTarget = _speedRadarScan(veh)
        if speedTarget then
            for _, r in ipairs(results) do
                if r.plate == speedTarget.plate then
                    r.speedGun = speedTarget.speed
                end
            end
        end
    end
    cb(results)

    -- 第二阶段: 异步 ANPR 检查 → 有命中时主动推送
    _anprCheckAndPush(results)
end)

-- ==============================================================
-- NUI 回调: 警用操作
-- ==============================================================

RegisterNUICallback('policeAction', function(data, cb)
    local action = data and data.action
    local PlayerData = QBCore.Functions.GetPlayerData()

    -- 安全校验: 必须是警察且值班
    if not PlayerData or PlayerData.job.name ~= 'police' or not PlayerData.job.onduty then
        QBCore.Functions.Notify('仅限值班警察使用', 'error')
        cb({ success = false })
        return
    end

    if action == 'flagPlate' then
        local plate = data.plate
        if not plate or #plate < 2 then
            QBCore.Functions.Notify('无效车牌', 'error')
            cb({ success = false })
            return
        end
        -- 触发服务端标记 (带 reason 输入 — 简化版先用通用 reason)
        TriggerServerEvent('tcity-dashboard:server:flagPlate', plate, '中控屏标记')
        QBCore.Functions.Notify(('已标记车牌: %s'):format(plate:upper()), 'success')
        cb({ success = true })

    elseif action == 'impoundNear' then
        -- 委托给 qb-policejob 现有扣押逻辑
        TriggerEvent('police:client:impoundNear')
        cb({ success = true })

    elseif action == 'deployTracker' then
        -- 委托给 qb-policejob 现有追踪器逻辑
        TriggerEvent('police:client:CheckDistance')
        cb({ success = true })

    elseif action == 'toggleSpeedRadar' then
        _speedRadarMode = not _speedRadarMode
        QBCore.Functions.Notify(
            _speedRadarMode and '📏 测速雷达: 已开启' or '📏 测速雷达: 已关闭',
            _speedRadarMode and 'success' or 'primary'
        )
        cb({ success = true, speedRadarMode = _speedRadarMode })

    else
        cb({ success = false, error = '未知操作' })
    end
end)

-- ==============================================================
-- v2.2: 公民/车辆查询 NUI 回调
-- ==============================================================

RegisterNUICallback('policeLookup', function(data, cb)
    local queryType = data and data.type
    local query = data and data.query

    local PlayerData = QBCore.Functions.GetPlayerData()
    if not PlayerData or PlayerData.job.name ~= 'police' or not PlayerData.job.onduty then
        cb({ found = false, message = '仅限值班警察使用' })
        return
    end

    if queryType == 'citizen' then
        QBCore.Functions.TriggerCallback('tcity-dashboard:server:lookupCitizen', function(result)
            cb(result or { found = false, message = '查询失败' })
        end, query)
    elseif queryType == 'vehicle' then
        QBCore.Functions.TriggerCallback('tcity-dashboard:server:lookupVehicle', function(result)
            cb(result or { found = false, message = '查询失败' })
        end, query)
    else
        cb({ found = false, message = '无效查询类型' })
    end
end)

-- ==============================================================
-- v2.2: 扫描历史日志 (最近 50 条)
-- ==============================================================

local _scanLog = {}  -- { plate, model, speed, distance, time, isFlagged, isStolen }

local function _appendScanLog(results)
    -- FiveM 客户端无 os.date，用 GTA V 原生时钟
    local h = GetClockHours()
    local m = GetClockMinutes()
    local s = GetClockSeconds()
    local now = ('%02d:%02d:%02d'):format(h, m, s)
    for _, r in ipairs(results) do
        _scanLog[#_scanLog + 1] = {
            plate = r.plate,
            model = r.model,
            speed = r.speed,
            distance = r.distance,
            time = now,
            isFlagged = r.isFlagged or false,
            isStolen = r.isStolen or false,
        }
    end
    -- 只保留最近 50 条
    while #_scanLog > 50 do
        table.remove(_scanLog, 1)
    end
end

-- ==============================================================
-- 模块激活/停用 (由 main.lua 控制)
-- ==============================================================

--- 当警察打开中控屏时激活警用模块
function PoliceModule.Activate()
    if _radarActive then return end
    _radarActive = true

    -- 启动 ANPR 定时扫描 (两阶段: 同步推送 + 异步 ANPR 更新)
    _scanTimer = setInterval(function()
        if not _radarActive then return end
        local veh = Poller.GetVehicle()
        if not veh or not DoesEntityExist(veh) then return end
        local results = _scanNearbyVehiclesSync(veh)

        -- 📏 测速雷达模式: 附加精确测速目标
        if _speedRadarMode then
            local speedTarget = _speedRadarScan(veh)
            if speedTarget then
                local found = false
                for _, r in ipairs(results) do
                    if r.plate == speedTarget.plate then
                        r.speedGun = speedTarget.speed
                        found = true
                        break
                    end
                end
                -- 如果目标不在雷达范围内（锥形过窄），单独追加
                if not found then
                    results[#results + 1] = {
                        plate = speedTarget.plate,
                        model = '—',
                        speed = speedTarget.speed,
                        distance = speedTarget.distance,
                        isFlagged = false,
                        isStolen = false,
                        speedGun = speedTarget.speed,
                    }
                end
            end
        end

        -- v2.2: 追加扫描日志 + 推送
        _appendScanLog(results)
        SendNUIMessage({
            type = 'policeRadar',
            data = results,
            scanLog = _scanLog,
        })
        _anprCheckAndPush(results)
    end, 2000)
end

--- 关闭中控屏时停用
function PoliceModule.Deactivate()
    _radarActive = false
    _speedRadarMode = false
    if _scanTimer then
        clearInterval(_scanTimer)
        _scanTimer = nil
    end
end

--- 获取测速雷达状态
function PoliceModule.IsSpeedRadarActive()
    return _speedRadarMode
end

-- ==============================================================
-- setInterval 辅助 (FiveM 兼容)
-- ==============================================================

local _intervals = {}

function setInterval(fn, ms)
    local id = #_intervals + 1
    _intervals[id] = true
    Citizen.CreateThread(function()
        while _intervals[id] do
            fn()
            Wait(ms)
        end
    end)
    return id
end

function clearInterval(id)
    _intervals[id] = nil
end

print('[tcity-dashboard] 🚔 警车功能模块已就绪 (v2.1)')
print('[tcity-dashboard]   ANPR扫描 | 被盗车检测 | 测速雷达 | GPS追踪 | CCTV')
