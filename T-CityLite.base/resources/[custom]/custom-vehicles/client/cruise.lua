-- cruise.lua — 双模智能巡航控制 v2.0
--
-- Y 键 = 动态道路巡航 (Road-Aware Auto Cruise)
--   → 读取道路 speed flag → 载具极速缩放 → 渐进加速 → 混合维持
--   → 仅限陆地载具 (汽车/摩托/卡车，不含飞机/船/直升机)
--   → 每 3 秒重检道路，自动调速
--
-- U 键 = 定速巡航 (Current Speed Lock)
--   → 锁定当前速度 → 混合维持 → ↑↓ 微调 ±5 km/h
--   → 所有载具可用 (含飞机/船/直升机)
--
-- 退出条件: 刹车 / 手刹 / 离地 / 碰撞 / 猛踩油门 / 非驾驶席
--
-- 安全: 纯客户端物理操作，不涉及 DB/经济/道具
--       每帧 Wait(0) 避免死锁，pcall 包裹所有原生调用
-- 兼容: 事件签名向后扩展 → (active, speed, mode, roadLimit)

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 常量
-- ==============================================================

local MODE_NONE = 0
local MODE_AUTO = 1  -- Y: 道路感知自动巡航
local MODE_LOCK = 2  -- U: 当前速度锁定巡航

local CRUISE_MIN_MS  = 5.6     -- 最低巡航 20 km/h (m/s)
local FLAG_CHECK_MS  = 3000    -- 道路检测间隔 (ms)
local ACCEL_BOOST    = 0.8     -- 渐进加速步长 (m/s per tick)
local MAINTAIN_GAP   = 2.0     -- 低于目标此值 → 进入补速区 (m/s)
local OVERSPEED_OK   = 1.5     -- 高于目标此值以内 → 不干预 (m/s)
local EXIT_THROTTLE  = 5.0     -- 猛踩油门退出阈值 (m/s above target)

-- ==============================================================
-- GTA5 道路 speed flag → 限速 (km/h)
-- 数据来源: Cfx.re GetVehicleNodeProperties flags 社区逆向
-- ==============================================================

local ROAD_SPEED = {
    -- 🏙️ 城市道路
    [2]  = 50,   -- 城市主干道
    [3]  = 50,   -- 近郊连接路
    [6]  = 40,   -- 住宅区 / 山路
    [18] = 40,   -- 城市隧道

    -- 🛣️ 高速公路
    [66] = 110,  -- 高速公路
    [82] = 110,  -- 高速隧道
    [64] = 90,   -- 高速匝道 / 连接段

    -- 🅿️ 低速区
    [10] = 15,   -- 停车场 / 加油站 / 沙滩
    [14] = 15,   -- 停车库
    [15] = 15,   -- 机场跑道 / 停机坪
    [13] = 20,   -- 军事基地区域

    -- 🏔️ 山路 / 越野
    [11] = 25,   -- 沙地
    [34] = 35,   -- 山路 (Catfish View 等)
    [35] = 35,   -- 山路 (Tataviam 等)
    [38] = 40,   -- 山路 (Vinewood 电台)
    [40] = 40,   -- 山路 (Mount Gordo)
    [42] = 30,   -- 运河路 / 小径
    [43] = 25,   -- 河滩 / 沙地
    [46] = 25,   -- 次要停车场
    [47] = 30,   -- 越野自行车道
}

local DEFAULT_ROAD_LIMIT = 50

-- ==============================================================
-- 陆地载具 class 白名单 (Auto 模式)
-- 排除: 14=船 15=直升机 16=飞机 21=火车
-- ==============================================================

local LAND_CLASS = {
    [0]=true, [1]=true, [2]=true, [3]=true, [4]=true, [5]=true,
    [6]=true, [7]=true, [8]=true, [9]=true, [10]=true, [11]=true,
    [12]=true, [13]=true, [17]=true, [18]=true, [19]=true, [20]=true,
    [22]=true,
}

-- ==============================================================
-- 运行时状态
-- ==============================================================

local cruiseMode   = MODE_NONE
local cruiseTarget = 0.0     -- 目标速度 (m/s)
local cruiseRoad   = 0       -- 当前道路限速 km/h (Auto 模式显示用)
local _flagLastMs  = 0       -- 上次道路检测时间戳

-- ==============================================================
-- 工具函数
-- ==============================================================

--- 安全读取道路 speed flag → 限速 km/h
--- 失败 / 无数据 / 未映射 → 返回 nil
local function _readRoadLimit(veh)
    if not veh or veh == 0 then return nil end
    local coords = GetEntityCoords(veh)
    local ok, found, density, flags = pcall(GetVehicleNodeProperties, coords.x, coords.y, coords.z)
    if ok and found and flags then
        return ROAD_SPEED[flags]
    end
    return nil
end

--- 读取载具 85% 极速上限 (km/h)
--- 失败回退 50 km/h
local function _readVehicleCap(veh)
    local ok, vMax = pcall(GetVehicleHandlingFloat, veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
    if not ok or not vMax or vMax <= 0 then
        return 50
    end
    return math.floor(vMax * 0.85 * 3.6)
end

--- Auto 模式: 计算实际目标速度 (m/s) + 道路限速 (km/h)
local function _calcAutoTarget(veh)
    local roadLimit = _readRoadLimit(veh) or DEFAULT_ROAD_LIMIT
    local vCap = _readVehicleCap(veh)
    local targetKmh = math.min(roadLimit, vCap)
    return targetKmh / 3.6, roadLimit
end

--- 陆地载具?
local function _isLand(veh)
    return LAND_CLASS[GetVehicleClass(veh)] or false
end

--- 驾驶员检测
local function _isDriver(veh)
    return GetPedInVehicleSeat(veh, -1) == PlayerPedId()
end

-- ==============================================================
-- 状态广播 (向后兼容: 老监听只读前2参)
-- ==============================================================

local function _broadcast(active, speed, mode, roadLimit)
    local modeStr = 'none'
    if mode == MODE_AUTO then modeStr = 'auto'
    elseif mode == MODE_LOCK then modeStr = 'lock' end
    TriggerEvent('custom-vehicles:client:cruiseState', active, speed, modeStr, roadLimit or 0)
end

-- ==============================================================
-- 退出巡航
-- ==============================================================

local function _exit(reason)
    if cruiseMode == MODE_NONE then return end

    cruiseMode   = MODE_NONE
    cruiseTarget = 0.0
    cruiseRoad   = 0
    _broadcast(false, 0.0, MODE_NONE, 0)

    if reason == 'brake' then
        QBCore.Functions.Notify('🛑 巡航已退出', 'error')
    elseif reason == 'throttle' then
        QBCore.Functions.Notify('⚡ 手动加速 · 巡航退出', 'error')
    elseif reason == 'manual' then
        QBCore.Functions.Notify('巡航已关闭', 'primary')
    end
    -- 其他退出原因 (airborne / collision / not_driver / vehicle_gone) 不弹通知
end

-- ==============================================================
-- 混合维持状态机 (通用 — Auto / Lock 共用)
-- ==============================================================

local function _runMaintenanceLoop(veh, mode)
    Citizen.CreateThread(function()
        local inAccelPhase = true  -- 渐进加速阶段

        while cruiseMode == mode do
            Wait(0)

            -- ── 存活检测 ──
            if not DoesEntityExist(veh) then
                _exit('vehicle_gone'); return
            end

            -- ── 退出条件 ──
            -- 刹车 (INPUT_VEH_BRAKE = 72) / 手刹 (INPUT_VEH_HANDBRAKE = 76)
            if IsControlPressed(2, 72) or IsControlPressed(2, 76) then
                _exit('brake'); return
            end

            -- 空档/倒档停车
            if GetVehicleCurrentGear(veh) <= 0 and GetEntitySpeed(veh) < 1.0 then
                _exit('neutral'); return
            end

            -- 腾空
            if not IsVehicleOnAllWheels(veh) then
                _exit('airborne'); return
            end

            -- 碰撞 (50ms 防抖: 两次命中才退出)
            if HasEntityCollidedWithAnything(veh) then
                Wait(50)
                if cruiseMode == MODE_NONE then return end
                if HasEntityCollidedWithAnything(veh) then
                    _exit('collision'); return
                end
            end

            -- 非驾驶席
            if not _isDriver(veh) then
                _exit('not_driver'); return
            end

            -- ── 油门超驰: 玩家猛踩油门 → 退出 ──
            if IsControlPressed(2, 71) then  -- INPUT_VEH_ACCELERATE
                local spd = GetEntitySpeed(veh)
                if spd > cruiseTarget + EXIT_THROTTLE then
                    _exit('throttle'); return
                end
            end

            -- ── Auto 模式: 定期检测道路速度 ──
            if mode == MODE_AUTO then
                local now = GetGameTimer()
                if now - _flagLastMs >= FLAG_CHECK_MS then
                    _flagLastMs = now
                    local newTargetMs, roadLimit = _calcAutoTarget(veh)
                    if math.abs(newTargetMs - cruiseTarget) > 0.5 then  -- 变化 > 1.8 km/h 才更新
                        cruiseTarget = newTargetMs
                        cruiseRoad   = roadLimit
                        inAccelPhase  = true  -- 目标变了，重新渐进
                        _broadcast(true, cruiseTarget, MODE_AUTO, cruiseRoad)
                    end
                end
            end

            -- ── 速度维持 ──
            local spd = GetEntitySpeed(veh)

            -- 渐进加速阶段: spd 接近目标时切换为维持阶段
            if inAccelPhase and spd >= cruiseTarget - MAINTAIN_GAP then
                inAccelPhase = false
            end

            if spd < cruiseTarget - MAINTAIN_GAP then
                -- 低于目标: 渐进补速
                local boost = spd + ACCEL_BOOST
                SetVehicleForwardSpeed(veh, math.min(boost, cruiseTarget))
            elseif spd > cruiseTarget + OVERSPEED_OK then
                -- 高于目标: 不干预，靠物理自然降速
            else
                -- 维持区: 轻微补速防止掉速
                if spd < cruiseTarget - 0.5 then
                    SetVehicleForwardSpeed(veh, cruiseTarget)
                end
                -- 否则: 保持惯性，不干预
            end

            -- ── Lock 模式: ↑↓ 微调 (±5 km/h ≈ 1.39 m/s) ──
            if mode == MODE_LOCK then
                if IsControlJustPressed(2, 172) then  -- ↑
                    cruiseTarget = cruiseTarget + 1.39
                    _broadcast(true, cruiseTarget, MODE_LOCK, 0)
                end
                if IsControlJustPressed(2, 173) then  -- ↓
                    cruiseTarget = math.max(CRUISE_MIN_MS, cruiseTarget - 1.39)
                    _broadcast(true, cruiseTarget, MODE_LOCK, 0)
                end
            end
        end
    end)
end

-- ==============================================================
-- 启动 Auto 巡航 (Y 键)
-- ==============================================================

local function _startAuto(veh)
    if cruiseMode == MODE_AUTO then
        _exit('manual')
        return
    end

    if cruiseMode == MODE_LOCK then
        QBCore.Functions.Notify('请先退出定速巡航 (U)', 'error')
        return
    end

    if not _isLand(veh) then
        QBCore.Functions.Notify('🚫 飞行/航海载具不支持动态巡航，请用 U 键定速', 'error')
        return
    end

    if not _isDriver(veh) then
        QBCore.Functions.Notify('只有驾驶员可以启动巡航', 'error')
        return
    end

    local currentSpeed = GetEntitySpeed(veh)
    if currentSpeed < CRUISE_MIN_MS then
        QBCore.Functions.Notify('速度过低 (需 ≥ 20 km/h)', 'error')
        return
    end
    if GetVehicleCurrentGear(veh) <= 0 then
        QBCore.Functions.Notify('请挂入行驶档再启动', 'error')
        return
    end

    -- 计算目标
    local targetMs, roadLimit = _calcAutoTarget(veh)
    cruiseTarget = targetMs
    cruiseRoad   = roadLimit
    cruiseMode   = MODE_AUTO
    _flagLastMs  = GetGameTimer()

    _broadcast(true, cruiseTarget, MODE_AUTO, cruiseRoad)
    TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 3.0, 'cruise_on', 0.3)

    local targetKmh = math.floor(targetMs * 3.6)
    QBCore.Functions.Notify(('🚗 动态巡航启动 · 当前路段限速 %d km/h'):format(targetKmh), 'success')

    _runMaintenanceLoop(veh, MODE_AUTO)
end

-- ==============================================================
-- 启动 Lock 巡航 (U 键)
-- ==============================================================

local function _startLock(veh)
    if cruiseMode == MODE_LOCK then
        _exit('manual')
        return
    end

    if cruiseMode == MODE_AUTO then
        QBCore.Functions.Notify('请先退出动态巡航 (Y)', 'error')
        return
    end

    if not _isLand(veh) then
        QBCore.Functions.Notify('🚫 飞行/航海载具暂不支持巡航', 'error')
        return
    end

    if not _isDriver(veh) then
        QBCore.Functions.Notify('只有驾驶员可以启动定速巡航', 'error')
        return
    end

    local currentSpeed = GetEntitySpeed(veh)
    if currentSpeed < CRUISE_MIN_MS then
        QBCore.Functions.Notify('速度过低 (需 ≥ 20 km/h)', 'error')
        return
    end

    cruiseTarget = currentSpeed
    cruiseRoad   = 0
    cruiseMode   = MODE_LOCK

    _broadcast(true, cruiseTarget, MODE_LOCK, 0)
    TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 3.0, 'cruise_on', 0.3)

    local currentKmh = math.floor(currentSpeed * 3.6)
    QBCore.Functions.Notify(('📌 定速巡航启动 · %d km/h · ↑↓ 微调'):format(currentKmh), 'success')

    _runMaintenanceLoop(veh, MODE_LOCK)
end

-- ==============================================================
-- 按键 + 命令注册
-- ==============================================================

-- Y 键 → Auto 巡航
RegisterCommand('togglecruise', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end
    _startAuto(veh)
end, false)
RegisterKeyMapping('togglecruise', '动态道路巡航 (Y)', 'keyboard', 'Y')

-- U 键 → Lock 巡航
RegisterCommand('quickcruise', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end
    _startLock(veh)
end, false)
RegisterKeyMapping('quickcruise', '定速巡航 (U)', 'keyboard', 'U')

-- ==============================================================
-- Exports (供 Dashboard / 外部查询)
-- ==============================================================

exports('IsCruiseActive', function()
    return cruiseMode ~= MODE_NONE
end)

exports('GetCruiseSpeed', function()
    return cruiseTarget
end)

exports('GetCruiseMode', function()
    if cruiseMode == MODE_AUTO then return 'auto'
    elseif cruiseMode == MODE_LOCK then return 'lock'
    else return 'none' end
end)

exports('GetCruiseRoadLimit', function()
    return cruiseRoad
end)

exports('ToggleCruise', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end
    if cruiseMode == MODE_AUTO or cruiseMode == MODE_LOCK then
        _exit('manual')
    elseif _isLand(veh) then
        _startAuto(veh)
    else
        _startLock(veh)
    end
end)

-- ==============================================================
-- 自动退出监听
-- ==============================================================

-- 离车 → 退出
AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerLeftVehicle' then
        if args[1] == PlayerId() and cruiseMode ~= MODE_NONE then
            _exit('exit_vehicle')
        end
    end
end)

-- 引擎熄火 → 退出 (每秒检查)
Citizen.CreateThread(function()
    while true do
        Wait(1000)
        if cruiseMode ~= MODE_NONE then
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if not veh or veh == 0 or not GetIsVehicleEngineRunning(veh) then
                _exit('engine_off')
            end
        end
    end
end)

print('[custom-vehicles] 🎯 双模智能巡航就绪 — Y=动态道路巡航 | U=定速巡航 (仅限陆地载具)')
