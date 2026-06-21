-- server/security.lua — 鉴权框架 (v2.0)
--
-- 所有涉及载具状态变更的操作必须通过此模块校验
-- 校验链: RateLimit → 驾驶席 → 载具所有权 → 职业鉴权
--
-- 公开接口:
--   Security.Authorize(src, action, veh, opts) → ok, errMsg

local QBCore = exports['qb-core']:GetCoreObject()

Security = Security or {}

-- ==============================================================
-- Rate Limit 追踪
-- ==============================================================

local _rateLimits = {}  -- [src] = { [action] = timestamp }

local function _checkRateLimit(src, action)
    local now = os.clock() * 1000
    if not _rateLimits[src] then _rateLimits[src] = {} end
    local last = _rateLimits[src][action] or 0

    local limitMs = (DashboardConfig.Security.rateLimitMs or 1000)
    if now - last < limitMs then return false end
    _rateLimits[src][action] = now
    return true
end

-- ==============================================================
-- 驾驶席校验
-- ==============================================================

local function _isDriverSeat(src, veh)
    local ped = GetPlayerPed(src)
    local playerVeh = GetVehiclePedIsIn(ped, false)
    if playerVeh ~= veh then return false end
    return GetPedInVehicleSeat(veh, -1) == ped
end

-- ==============================================================
-- 物理距离校验
-- ==============================================================

local function _isNearVehicle(src, veh, maxDist)
    maxDist = maxDist or (DashboardConfig.Security.maxInteractionDistance or 5.0)
    local ped = GetPlayerPed(src)
    local pCoords = GetEntityCoords(ped)
    local vCoords = GetEntityCoords(veh)
    return #(pCoords - vCoords) <= maxDist
end

-- ==============================================================
-- 职业鉴权
-- ==============================================================

local function _checkJob(src, action)
    local restricted = DashboardConfig.Security.jobRestricted[action]
    if not restricted then return true end  -- 无限制

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    local job = Player.PlayerData.job
    if not job then return false end

    for _, allowedJob in ipairs(restricted) do
        if job.name == allowedJob then
            -- 可选: 检查 onduty
            if job.onduty ~= nil and not job.onduty then
                return false
            end
            return true
        end
    end
    return false
end

-- ==============================================================
-- 载具所有权校验
-- ==============================================================

local function _checkOwnership(src, veh)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    local citizenid = Player.PlayerData.citizenid

    -- 尝试调用 custom-vehicles 的 HasKeys export
    local hasKey = false
    pcall(function()
        hasKey = exports['custom-vehicles']:HasKeys(plate, citizenid)
    end)

    return hasKey
end

-- ==============================================================
-- 公开 API: 统一鉴权入口
-- ==============================================================

--- 鉴权操作
--- @param src number 玩家 source
--- @param action string 操作名
--- @param veh number 载具实体
--- @param opts table { requireDriver, requireOwnership, requireJob }
--- @return ok boolean
--- @return errMsg string|nil
function Security.Authorize(src, action, veh, opts)
    opts = opts or {}

    -- 1. Rate Limit
    if not _checkRateLimit(src, action) then
        return false, '操作太快，请稍后'
    end

    -- 2. 载具存在
    if not veh or not DoesEntityExist(veh) then
        return false, '载具不存在'
    end

    -- 3. 驾驶席 (默认要求)
    if opts.requireDriver ~= false then
        if not _isDriverSeat(src, veh) then
            return false, '你必须坐在驾驶席'
        end
    end

    -- 4. 物理距离
    if opts.requireNearby ~= false then
        if not _isNearVehicle(src, veh, opts.maxDist) then
            return false, '距离载具太远'
        end
    end

    -- 5. 职业鉴权
    if opts.requireJob then
        if not _checkJob(src, action) then
            return false, '你的职业无法使用此功能'
        end
    end

    -- 6. 所有权
    if opts.requireOwnership then
        if not _checkOwnership(src, veh) then
            return false, '你没有这辆载具的钥匙'
        end
    end

    return true, nil
end

--- 仅职业鉴权 (不涉及具体载具)
function Security.CheckJob(src, action)
    return _checkJob(src, action)
end

--- 清理玩家缓存 (playerDropped)
function Security.Cleanup(src)
    _rateLimits[src] = nil
end

print('[tcity-dashboard] 🛡️ 鉴权框架已就绪')
