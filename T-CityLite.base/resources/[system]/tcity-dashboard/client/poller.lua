-- client/poller.lua — 分类异步轮询引擎 (v2.0)
--
-- 设计原则:
--   1. 每种 vehicle class 独立 interval，下车时全部 ClearInterval
--   2. 轮询字段由 config/vehicles.lua FeatureFlags 驱动
--   3. 仅采集数据，不执行业务逻辑 (数据→NUI 单向推送)
--   4. pcall 包裹所有 native 调用，单次失败不中断轮询
--
-- 公开接口:
--   Poller.Start(veh, template, intervalMs)  → 启动轮询
--   Poller.Stop()                             → 停止全部轮询
--   Poller.GetCurrentData()                   → 获取最新缓存数据 (同步)

local QBCore = exports['qb-core']:GetCoreObject()

Poller = Poller or {}
local _vehicle = nil
local _template = nil
local _running = false     -- 轮询线程控制标志
local _errorCount = 0
local _cache = {}         -- 最新数据缓存

-- ==============================================================
-- 数据采集函数 — 按需调用
-- ==============================================================

local function _safe(fn, default)
    local ok, result = pcall(fn)
    if not ok then
        _errorCount = _errorCount + 1
        return default
    end
    _errorCount = 0
    return result
end

-- ── 通用字段 ──
local function _pollSpeed(veh)
    return _safe(function()
        local ms = GetEntitySpeed(veh)
        return {
            mph = math.floor(ms * 2.23694),
            kmh = math.floor(ms * 3.6),
        }
    end, { mph = 0, kmh = 0 })
end

local function _pollRPM(veh)
    return _safe(function()
        local rpm = GetVehicleCurrentRpm(veh) or 0
        return {
            ratio = rpm,                          -- 0.0 ~ 1.0
            display = math.floor(rpm * 100),      -- 0 ~ 100
        }
    end, { ratio = 0, display = 0 })
end

local function _pollGear(veh)
    return _safe(function()
        return GetVehicleCurrentGear(veh) or 0
    end, 0)
end

local function _pollFuel(veh)
    return _safe(function()
        return math.floor(GetVehicleFuelLevel(veh) or 0)
    end, 0)
end

local function _pollEngineHealth(veh)
    return _safe(function()
        return GetVehicleEngineHealth(veh) or 1000
    end, 1000)
end

local function _pollBodyHealth(veh)
    return _safe(function()
        return GetVehicleBodyHealth(veh) or 1000
    end, 1000)
end

local function _pollDoors(veh)
    return _safe(function()
        local nd = GetNumberOfVehicleDoors(veh)
        -- 摩托/自行车 → 0 门
        if not nd or nd < 1 then
            return { doors = {}, numDoors = 0, hood = false, trunk = false }
        end
        -- GTA 原生返回含引擎盖(4)+后备箱(5)的总数, 减去2得乘客门数
        local passengerDoors = math.max(0, nd - 2)
        if passengerDoors > 6 then passengerDoors = 4 end
        local states = {}
        for i = 0, passengerDoors - 1 do
            states[#states + 1] = (GetVehicleDoorAngleRatio(veh, i) > 0.05) and 'open' or 'closed'
        end
        local hood = GetVehicleDoorAngleRatio(veh, 4) > 0.05
        local trunk = GetVehicleDoorAngleRatio(veh, 5) > 0.05
        return { doors = states, numDoors = passengerDoors, hood = hood, trunk = trunk }
    end, { doors = {}, numDoors = 2, hood = false, trunk = false })
end

-- ── 乘员 ──
local function _pollSeats(veh)
    local maxPassengers = GetVehicleMaxNumberOfPassengers(veh)
    if not maxPassengers or maxPassengers < 1 then maxPassengers = 3 end
    local localPed = PlayerPedId()
    local seats = {}
    -- maxPassengers = 乘客数(不含驾驶), 有效乘客索引 0..maxPassengers-1
    for i = -1, maxPassengers - 1 do
        local ped = GetPedInVehicleSeat(veh, i)
        seats[#seats + 1] = {
            index = i,
            occupied = (ped ~= 0),
            isPlayer = (ped == localPed),
        }
    end
    return seats
end

-- ── 跑车特有 ──
local function _pollTurbo(veh)
    return _safe(function()
        local installed = GetVehicleMod(veh, 18) ~= -1
        local psi = 0.0
        if installed then
            psi = ((GetVehicleCurrentRpm(veh) or 0) * 2.5)
        end
        return { installed = installed, psi = psi }
    end, { installed = false, psi = 0 })
end

local function _pollSpoiler(veh)
    return _safe(function()
        -- 尾翼 mod index 0 (Spoiler)
        return GetVehicleMod(veh, 0) ~= -1
    end, false)
end

-- ── 商用特有 ──
local function _pollTrailer(veh)
    return _safe(function()
        local _, trailer = GetVehicleTrailerVehicle(veh)
        return trailer ~= nil and trailer ~= 0
    end, false)
end

local function _pollAirBrake(veh)
    -- 模拟气刹压力 (基于速度变化)
    local speed = (_cache.speed and _cache.speed.mph) or 0
    local pressure = 120 - (speed * 0.3)
    return math.max(20, math.min(120, math.floor(pressure)))
end

-- ── 紧急服务特有 ──
local function _pollSiren(veh)
    return _safe(function()
        return IsVehicleSirenOn(veh) or false
    end, false)
end

-- ── 航空特有 ──
local function _pollAltitude(veh)
    return _safe(function()
        local coords = GetEntityCoords(veh)
        local groundZ = 0.0
        local found, waterZ = GetWaterHeight(coords.x, coords.y, coords.z)
        if found and waterZ > groundZ then groundZ = waterZ end
        local _, ground = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z, 0)
        if ground and ground > groundZ then groundZ = ground end
        return {
            absolute = math.floor(coords.z),
            aboveGround = math.floor(coords.z - groundZ),
        }
    end, { absolute = 0, aboveGround = 0 })
end

local function _pollAirspeed(veh)
    return _safe(function()
        return math.floor(GetEntitySpeed(veh) * 3.6)
    end, 0)
end

local function _pollHeading(veh)
    return _safe(function()
        return math.floor(GetEntityHeading(veh))
    end, 0)
end

local function _pollLandingGear(veh)
    return _safe(function()
        -- GetLandingGearState: 0=deployed, 1=closing, 2=opening, 3=retracted
        return GetLandingGearState(veh) or 0
    end, 3)
end

-- ── 船只特有 ──
local function _pollDepth(veh)
    return _safe(function()
        local coords = GetEntityCoords(veh)
        local _, waterZ = GetWaterHeight(coords.x, coords.y, coords.z)
        if waterZ then
            return math.floor(math.abs(waterZ - coords.z))
        end
        return 0
    end, 0)
end

-- ==============================================================
-- 核心: 按模板采集
-- ==============================================================

local POLL_FUNCTIONS = {
    -- 通用
    speed          = _pollSpeed,
    rpm            = _pollRPM,
    gear           = _pollGear,
    fuel           = _pollFuel,
    engine_health  = _pollEngineHealth,
    body_health    = _pollBodyHealth,
    doors          = _pollDoors,
    seats          = _pollSeats,
    -- 跑车
    turbo          = _pollTurbo,
    spoiler        = _pollSpoiler,
    -- 商用
    trailer        = _pollTrailer,
    air_brake      = _pollAirBrake,
    -- 紧急
    siren          = _pollSiren,
    -- 航空
    altitude       = _pollAltitude,
    airspeed       = _pollAirspeed,
    heading        = _pollHeading,
    landing_gear   = _pollLandingGear,
    -- 船只
    depth          = _pollDepth,
}

--- 按模板采集需要的数据字段
local function _collect(veh, template)
    if not veh or not DoesEntityExist(veh) then return nil end

    local data = {
        ts = GetGameTimer(),
        template = template,
    }

    -- 始终采集的通用字段
    data.speed = POLL_FUNCTIONS.speed(veh)
    data.fuel = POLL_FUNCTIONS.fuel(veh)
    data.doors = POLL_FUNCTIONS.doors(veh)
    data.seats = POLL_FUNCTIONS.seats(veh)

    local flags = DashboardConfig.FeatureFlags[template] or {}
    local base = DashboardConfig.GlobalFeatures

    -- 按功能开关采集
    local function _c(key, fnName)
        if flags[key] and POLL_FUNCTIONS[fnName] then
            data[fnName] = POLL_FUNCTIONS[fnName](veh)
        end
    end

    _c('diag_rpm', 'rpm')
    _c('diag_gear', 'gear')
    _c('diag_engine_health', 'engine_health')
    _c('diag_body_health', 'body_health')
    _c('diag_turbo', 'turbo')
    _c('ctrl_spoiler', 'spoiler')
    _c('diag_trailer', 'trailer')
    _c('diag_air_brake', 'air_brake')
    _c('diag_siren', 'siren')
    _c('diag_altitude', 'altitude')
    _c('diag_airspeed', 'airspeed')
    _c('diag_heading', 'heading')
    _c('ctrl_landing_gear', 'landing_gear')
    _c('diag_depth', 'depth')

    -- 衍生字段
    if data.engine_health then
        data.oil_life = math.floor((data.engine_health / 1000) * 100)
    end
    if data.speed then
        data.speedKnots = math.floor(data.speed.mph * 0.868976)
    end

    -- 模拟字段 (不依赖native) — 稳定值无随机跳动
    if flags['diag_coolant'] then
        local eng = data.engine_health or 1000
        local rpmFactor = (data.rpm and data.rpm.ratio or 0) * 12
        data.coolant = math.floor((eng / 1000 * 85) + rpmFactor) + 0.5
    end
    if flags['diag_battery'] then
        data.battery = 13.8
    end
    if flags['diag_trans_temp'] then
        local ct = data.coolant or 85
        data.trans_temp = math.floor(60 + ct * 0.3) + 0.5
    end
    if flags['diag_gross_weight'] then
        -- 稳定值: 基于载具实体句柄取模, 不会每帧跳动
        data.gross_weight = 3500 + (veh % 10000)
    end
    if flags['diag_vsi'] then
        data.vsi = math.floor((data.altitude and data.altitude.absolute or 0) * 0.01)
    end

    return data
end

-- ==============================================================
-- 公开 API
-- ==============================================================

--- 启动轮询
--- @param veh number 载具实体
--- @param template string 模板名 (sports/commercial/emergency/plane/helicopter/boat)
--- @param intervalMs number 轮询间隔
function Poller.Start(veh, template, intervalMs)
    -- 先停止已有轮询
    Poller.Stop()

    if not veh or veh == 0 then return end
    _vehicle = veh
    _template = template
    intervalMs = intervalMs or 200
    _errorCount = 0
    _cache = {}
    _running = true

    -- FiveM 原生轮询: CreateThread + Wait loop + _running 标志
    Citizen.CreateThread(function()
        local degraded = false
        local degradedInterval = intervalMs * 3
        while _running do
            local data = _collect(_vehicle, _template)
            if data then
                _cache = data
                SendNUIMessage({ type = 'diag', data = data })
            end

            -- 错误过多 → 降频
            if _errorCount > (DashboardConfig.Performance.maxPollErrors or 5) then
                degraded = true
            end

            Wait(degraded and degradedInterval or intervalMs)
        end
    end)
end

--- 停止全部轮询 (下车时调用)
function Poller.Stop()
    _running = false
    _vehicle = nil
    _template = nil
    _cache = {}
    _errorCount = 0
end

--- 同步获取最新缓存数据
function Poller.GetCurrentData()
    return _cache
end

--- 获取当前载具实体
function Poller.GetVehicle()
    return _vehicle
end

--- 一次性采集 (开门时立即发送，不等interval)
function Poller.Snapshot(veh, template)
    if not veh or veh == 0 then return nil end
    return _collect(veh, template)
end

--- 检查轮询是否活跃
function Poller.IsActive()
    return _running
end

print('[tcity-dashboard] 🔄 轮询引擎已就绪')
