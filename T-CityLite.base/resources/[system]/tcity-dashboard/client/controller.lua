-- client/controller.lua — 载具动作执行器 (v2.0)
--
-- 职责: 接收 NUI 回调 → 分类执行 (本地直接/服务端鉴权)
-- 核心原则:
--   - 无副作用的查询 → 直接本地执行 (如获取高度)
--   - 改变状态的操作 → 走服务端鉴权 (如警笛/扩音器/抛锚)
--   - 纯物理操作 → 本地执行 + 驾驶席校验 (如开窗/开门)

local QBCore = exports['qb-core']:GetCoreObject()

Controller = Controller or {}
local _actionCooldowns = {}
local _cooldownMs = 1000

-- ==============================================================
-- Rate Limit
-- ==============================================================

local function _checkCooldown(action)
    -- 敞篷操作不限制频率 (动画时间长，多次点击无意义但不应被拦截)
    if action == 'roof' then return true end
    local now = GetGameTimer()
    local last = _actionCooldowns[action] or 0
    if now - last < _cooldownMs then return false end
    _actionCooldowns[action] = now
    return true
end

-- ==============================================================
-- 本地安全校验
-- ==============================================================

local function _getVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil, nil end
    return veh, ped
end

local function _isDriver(veh, ped)
    return GetPedInVehicleSeat(veh, -1) == ped
end

local function _isDriverOrPassenger(veh, ped)
    return _isDriver(veh, ped) or GetPedInVehicleSeat(veh, 0) == ped
end

-- ==============================================================
-- 本地动作 (纯物理操作)
-- ==============================================================

local LOCAL_ACTIONS = {}

function LOCAL_ACTIONS.engine(veh, ped)
    if not _isDriver(veh, ped) then return false, '只有驾驶员可以操作引擎' end
    local state = GetIsVehicleEngineRunning(veh)
    SetVehicleEngineOn(veh, not state, true, true)
    return true, state and '引擎: 已关闭' or '引擎: 已启动'
end

function LOCAL_ACTIONS.lock(veh, ped)
    local lockState = GetVehicleDoorLockStatus(veh)
    SetVehicleDoorsLocked(veh, lockState < 2 and 2 or 0)
    TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, lockState < 2 and 'lock' or 'unlock', 0.3)
    return true, lockState < 2 and '全车锁: 已锁定' or '全车锁: 已解锁'
end

-- 车窗单键切换 (状态记忆)
local _windowsOpen = false
function LOCAL_ACTIONS.windows(veh, ped)
    if _windowsOpen then
        for i = 0, 7 do RollUpWindow(veh, i) end
        _windowsOpen = false
        return true, '车窗: 已升起'
    else
        for i = 0, 7 do RollDownWindow(veh, i) end
        _windowsOpen = true
        return true, '车窗: 已降下'
    end
end

function LOCAL_ACTIONS.hood(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 4) > 0.05
    if open then SetVehicleDoorShut(veh, 4, false) else SetVehicleDoorOpen(veh, 4, false, false) end
    return true, open and '引擎盖: 已关闭' or '引擎盖: 已打开'
end

function LOCAL_ACTIONS.trunk(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 5) > 0.05
    if open then SetVehicleDoorShut(veh, 5, false) else SetVehicleDoorOpen(veh, 5, false, false) end
    return true, open and '后备箱: 已关闭' or '后备箱: 已打开'
end

function LOCAL_ACTIONS.cargo_door(veh, ped)
    -- 与 trunk 相同，但用于商用/货车
    local open = GetVehicleDoorAngleRatio(veh, 5) > 0.05
    if open then SetVehicleDoorShut(veh, 5, false) else SetVehicleDoorOpen(veh, 5, false, false) end
    return true, open and '货舱门: 已关闭' or '货舱门: 已打开'
end

function LOCAL_ACTIONS.door_d(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 0) > 0.05
    if open then SetVehicleDoorShut(veh, 0, false) else SetVehicleDoorOpen(veh, 0, false, false) end
    return true, open and '驾驶门: 已关闭' or '驾驶门: 已打开'
end

function LOCAL_ACTIONS.door_p(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 1) > 0.05
    if open then SetVehicleDoorShut(veh, 1, false) else SetVehicleDoorOpen(veh, 1, false, false) end
    return true, open and '副驾门: 已关闭' or '副驾门: 已打开'
end

function LOCAL_ACTIONS.door_rl(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 2) > 0.05
    if open then SetVehicleDoorShut(veh, 2, false) else SetVehicleDoorOpen(veh, 2, false, false) end
    return true, open and '左后门: 已关闭' or '左后门: 已打开'
end

function LOCAL_ACTIONS.door_rr(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 3) > 0.05
    if open then SetVehicleDoorShut(veh, 3, false) else SetVehicleDoorOpen(veh, 3, false, false) end
    return true, open and '右后门: 已关闭' or '右后门: 已打开'
end

function LOCAL_ACTIONS.door_e1(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 4) > 0.05
    if open then SetVehicleDoorShut(veh, 4, false) else SetVehicleDoorOpen(veh, 4, false, false) end
    return true, open and '额外门1: 已关闭' or '额外门1: 已打开'
end

function LOCAL_ACTIONS.door_e2(veh, ped)
    local open = GetVehicleDoorAngleRatio(veh, 5) > 0.05
    if open then SetVehicleDoorShut(veh, 5, false) else SetVehicleDoorOpen(veh, 5, false, false) end
    return true, open and '额外门2: 已关闭' or '额外门2: 已打开'
end

function LOCAL_ACTIONS.roof(veh, ped)
    if not IsVehicleAConvertible(veh, 0) then
        return false, '该载具不是敞篷车'
    end
    -- FiveM 原生: GetConvertibleRoofState (非 GetVehicleRoofState)
    -- 返回值: 0=关闭, 1=打开中, 2=打开, 3=关闭中
    local ok, roofState = pcall(GetConvertibleRoofState, veh)
    if not ok then
        -- 回退: 直接尝试切换 (不使用状态检测)
        pcall(LowerConvertibleRoof, veh, true)
        return true, '敞篷: 已切换'
    end
    if roofState == 2 then
        -- 当前打开 → 关闭
        RaiseConvertibleRoof(veh, true)
        return true, '敞篷: 正在关闭'
    else
        -- 当前关闭或运动中 → 打开
        LowerConvertibleRoof(veh, true)
        return true, '敞篷: 正在打开'
    end
end

function LOCAL_ACTIONS.alarm(veh, ped)
    if not _isDriver(veh, ped) then return false, '只有驾驶员可以操作警报' end
    if IsVehicleAlarmActivated(veh) then
        SetVehicleAlarm(veh, false)
        SetVehicleAlarmTimeLeft(veh, 0)
        return true, '紧急警报: 已关闭'
    else
        SetVehicleAlarm(veh, true)
        StartVehicleAlarm(veh)
        return true, '紧急警报: 已激活'
    end
end

-- 警笛控制 (本地直接操作 — 服务端只做鉴权日志)
function LOCAL_ACTIONS.siren(veh, ped, params)
    if not _isDriver(veh, ped) then return false, '只有驾驶员可以操作警笛' end
    local mode = params and params.mode or 'wail'

    -- FiveM 警笛: SetVehicleSiren 控制开关, 音调由游戏引擎自动轮换
    if mode == 'silent' then
        -- 无声闪烁: 关闭警笛声, 保留警灯
        SetVehicleSiren(veh, false)
        -- 保持警灯 extras 开启 (通常 extras 1-4 是 lightbar)
        return true, '警笛: 无声闪烁'
    else
        -- wail / yelp / priority → 全部开启警笛 (GTA V 自动处理音调)
        SetVehicleSiren(veh, true)
        return true, ('警笛: %s'):format(mode)
    end
end

-- 换座 (点座位图)
function LOCAL_ACTIONS.seat(veh, ped, params)
    local seatIndex = params and params.index
    if seatIndex == nil then return false, '无效座位' end
    -- 驾驶座只能驾驶员操作
    if seatIndex == -1 and GetPedInVehicleSeat(veh, -1) ~= ped then
        return false, '只有驾驶员可以换到驾驶座'
    end
    local targetPed = GetPedInVehicleSeat(veh, seatIndex)
    if targetPed ~= 0 then return false, '该座位已被占用' end
    -- 检查是否已在目标座位
    if GetPedInVehicleSeat(veh, seatIndex) == ped then
        return false, '你已经在这个座位上了'
    end
    SetPedIntoVehicle(ped, veh, seatIndex)
    return true, '已换座'
end

-- 尾翼三态循环 (自动 → 升起 → 放下)
local _spoilerState = 0  -- 0=auto, 1=up, 2=down
function LOCAL_ACTIONS.spoiler(veh, ped)
    _spoilerState = (_spoilerState + 1) % 3
    if _spoilerState == 0 then
        SetVehicleExtra(veh, 1, 1)  -- 收起 → 让 GTA 自动管理
        return true, '尾翼: 自动'
    elseif _spoilerState == 1 then
        SetVehicleExtra(veh, 1, 0)  -- 展开 (升起)
        return true, '尾翼: 升起'
    else
        SetVehicleExtra(veh, 1, 1)  -- 收起 (放下)
        return true, '尾翼: 放下'
    end
end

-- 霓虹灯开关
function LOCAL_ACTIONS.neon(veh, ped)
    local anyOn = false
    for i = 0, 3 do
        if IsVehicleNeonLightEnabled(veh, i) then anyOn = true; break end
    end
    for i = 0, 3 do
        SetVehicleNeonLightEnabled(veh, i, not anyOn)
    end
    return true, anyOn and '霓虹灯: 已关闭' or '霓虹灯: 已开启'
end

-- 飞机特有
function LOCAL_ACTIONS.landing_gear(veh, ped)
    local state = GetLandingGearState(veh)
    if state == 3 or state == 0 then
        -- retracted (3) → deploy, deployed (0) → retract
        if state == 3 then
            SetVehicleLandingGear(veh, 0) -- deploy
            return true, '起落架: 放下中'
        else
            SetVehicleLandingGear(veh, 3) -- retract
            return true, '起落架: 收起中'
        end
    end
    return true, '起落架: 运动中...'
end

-- ==============================================================
-- 服务端鉴权动作 (TriggerServerEvent → 服务端校验 → 广播)
-- ==============================================================

local SERVER_ACTIONS = {
    siren          = 'custom-vehicles:server:sirenControl',
    megaphone      = 'custom-vehicles:server:megaphone',
    anchor         = 'custom-vehicles:server:anchorControl',
    hoist          = 'custom-vehicles:server:hoistControl',
    water_cannon   = 'custom-vehicles:server:waterCannon',
    spotlight      = 'custom-vehicles:server:spotlight',
    night_vision   = 'custom-vehicles:server:nightVision',
    wanted_db      = 'custom-vehicles:server:wantedDb',
    -- v2.1 警车新增 (camera 由本地直接处理)
    transponder_cycle = 'custom-vehicles:server:transponderCycle',
    flares         = 'custom-vehicles:server:flares',
    bilge_pump     = 'custom-vehicles:server:bilgePump',
}

--- 走服务端鉴权的操作
function Controller.ExecuteServerAction(action, params)
    local eventName = SERVER_ACTIONS[action]
    if not eventName then return false, '未知服务端操作' end

    local veh = _getVehicle()
    if not veh or not DoesEntityExist(veh) then return false, '无载具' end

    params = params or {}
    params.vehNetId = NetworkGetNetworkIdFromEntity(veh) or 0

    TriggerServerEvent(eventName, params)
    return true, nil
end

-- ==============================================================
-- 公开 API
-- ==============================================================

--- 执行 NUI 发来的动作
--- @param action string 动作名
--- @param params table 额外参数
--- @return ok boolean
--- @return message string 反馈消息
function Controller.Execute(action, params)
    if not _checkCooldown(action) then
        return false, '操作太快，请稍后'
    end

    -- 先尝试本地动作
    local fn = LOCAL_ACTIONS[action]
    if fn then
        local veh, ped = _getVehicle()
        if not veh then return false, '你不在载具中' end
        return fn(veh, ped, params)
    end

    -- 再尝试服务端动作
    if SERVER_ACTIONS[action] then
        return Controller.ExecuteServerAction(action, params)
    end

    -- v2.1: CCTV 监控摄像头 → 委托给 qb-policejob
    if action == 'camera' then
        -- 启动第一个可用摄像头作为入口
        local cameras = DashboardConfig.SecurityCameras.cameras or {}
        if #cameras > 0 then
            TriggerEvent('police:client:ActiveCamera', 1)
            return true, '监控摄像头: 已启动 (按 Backspace 关闭)'
        else
            return false, '无可用摄像头配置'
        end
    end

    -- 特殊处理: 驾驶模式切换 (本地应用 + 服务端广播)
    if action == 'drive_mode' then
        local veh, ped = _getVehicle()
        if not veh or not DoesEntityExist(veh) then return false, '无载具' end
        local mode = params and params.mode or 'comfort'
        -- 本地立即应用
        _applyDriveMode(veh, mode)
        -- 服务端广播给车内所有人
        local netId = NetworkGetNetworkIdFromEntity(veh) or 0
        if netId ~= 0 then
            TriggerServerEvent('custom-vehicles:server:setDriveMode', netId, mode)
        end
        return true, '驾驶模式: ' .. mode
    end

    return false, '未知操作: ' .. (action or 'nil')
end

-- ==============================================================
-- 驾驶模式应用
-- ==============================================================

local DRIVE_MODES = {
    comfort    = { 0.85, 1.0,  0.85, 1.0  },
    sport      = { 1.15, 0.85, 1.2,  1.05 },
    eco        = { 0.70, 1.0,  0.9,  1.0  },
    freight    = { 1.1,  1.05, 1.0,  1.15 },
    offroad    = { 1.0,  1.0,  1.3,  1.0  },
}

function _applyDriveMode(veh, mode)
    if not veh or veh == 0 then return end
    local params = DRIVE_MODES[mode]
    if not params then return end
    if params[1] then SetVehicleHandlingFloat(veh, 'fInitialDriveForce', params[1]) end
    if params[2] then SetVehicleHandlingFloat(veh, 'fSteeringLock', params[2]) end
    if params[3] then SetVehicleHandlingFloat(veh, 'fSuspensionForce', params[3]) end
    if params[4] then SetVehicleHandlingFloat(veh, 'fBrakeForce', params[4]) end
end

-- 服务端广播接收
RegisterNetEvent('custom-vehicles:client:applyDriveMode', function(vehNetId, mode)
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if not veh or veh == 0 then return end
    local myVeh = GetVehiclePedIsIn(PlayerPedId(), false)
    if myVeh ~= veh then return end
    _applyDriveMode(veh, mode)
    SendNUIMessage({ type = 'driveMode', mode = mode })
end)

print('[tcity-dashboard] 🎮 控制器已就绪')
