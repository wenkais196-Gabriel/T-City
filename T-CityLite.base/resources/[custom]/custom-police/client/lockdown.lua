-- client/lockdown.lua — L1 布景层：/lockdown 拉一圈封锁锥桶（/lockdown clear 收）。
--
-- 纯表现层：物件只在本地世界里（和现有 /pobject 一致，不是服务端实体）。
-- 三条限制：一次只能有一组；5 分钟自动收；收的时候全删。

local MAX_CONE = 6
local BARRIER_MODEL = 'prop_barrier_work05'
local CONE_MODEL = 'prop_roadcone02a'
local LIFETIME_MS = 5 * 60 * 1000

local active = { props = {}, armed = false }

-- 模型加载复用 client/entity_util.lua（REUSE-01：不要再抄一份）
local loadModel = EntityUtil.LoadModel

local function removeProps()
    for _, prop in ipairs(active.props) do
        if prop and prop ~= 0 and DoesEntityExist(prop) then DeleteEntity(prop) end
    end
    active.props = {}
    active.armed = false
end

local function place(model, coords, heading)
    local hash = GetHashKey(model)
    if not loadModel(hash) then return false end
    local prop = CreateObject(hash, coords.x, coords.y, coords.z, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    if not prop or prop == 0 then return false end
    SetEntityHeading(prop, heading)
    PlaceObjectOnGroundProperly(prop)
    SetEntityAsMissionEntity(prop, true, true)
    FreezeEntityPosition(prop, true)
    active.props[#active.props + 1] = prop
    return true
end

RegisterCommand('lockdown', function(_, args)
    local mode = tostring((args and args[1]) or ''):lower()
    if mode == 'clear' then
        removeProps()
        print('[custom-police] lockdown cleared')
        return
    end
    -- 服务端复验在岗后再放（客户端命令不是权限边界）。
    TriggerServerEvent('police:server:lockdownRequest')
end, false)

--- 服务端授权后的真正摆放。
RegisterNetEvent('police:client:LockdownPlace', function()
    removeProps()
    local playerPed = PlayerPedId()
    local origin = GetEntityCoords(playerPed)
    local radius = 6.0
    local placed = 0
    for index = 1, MAX_CONE do
        local angle = math.rad((index - 1) * (360 / MAX_CONE))
        local at = vector3(origin.x + math.cos(angle) * radius, origin.y + math.sin(angle) * radius, origin.z)
        if place(CONE_MODEL, at, (index - 1) * (360 / MAX_CONE)) then placed = placed + 1 end
    end
    local forward = GetEntityForwardVector(playerPed)
    for _, sign in ipairs({ 1.0, -1.0 }) do
        local at = origin + forward * (radius * 1.4 * sign)
        if place(BARRIER_MODEL, at, GetEntityHeading(playerPed)) then placed = placed + 1 end
    end
    print(('[custom-police] lockdown placed=%d'):format(placed))
    active.armed = true
    SetTimeout(LIFETIME_MS, function()
        if active.armed then
            removeProps()
            print('[custom-police] lockdown auto-cleared (5 min)')
        end
    end)
end)
