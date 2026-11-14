-- ==============================================================
-- quest_hotdog_client.lua — 热狗摊 S2 客户端（推车 → 摆放预览 → 上报）
-- ==============================================================
-- 职责（只做表现，不做裁决）：
--   1. 进入 booth 步骤时，在玩家身边生成一辆推车（mission entity，先冻结）
--   2. 靠近按 E 抓住 → AttachEntityToEntity 挂到身前；再按 E 放下进入摆放预览
--   3. 预览：每帧从玩家脚下打一条向下的 ray 取地面点，用客户端能拿到的
--      native（路面 / 坡度 / 水面 / 室内）画红/绿圈和具体原因
--   4. 按 E 确认 → 冻住推车 → 把坐标 + netId + hints 走既有的 nodeComplete 上报
--
-- 为什么所有状态都放在本文件的 local 表里：
--   client/main.lua 的 activeNode 是**文件局部**变量。以前有模块把 activeNode
--   当全局用，事件结束时清掉的是另一个变量，节点线程还活着（见 main.lua 第 20 行
--   起的注释）。这里不碰 activeNode、也不新造全局；BoothState 只在本文件可见。
--
-- 为什么没有新的 net event：
--   完成走既有的 quest:server:nodeComplete；
--   进入 booth 步骤由既有的 quest:client:accepted / stepAdvanced / stateRestore 驱动。
--   服务端（server/quest_booth.lua）会自己重算距离/路网/间隔，并用 hints 做更严的否决。
--
-- 契约（服务端已定）：
--   TriggerServerEvent('quest:server:nodeComplete', questId, stepId, 'booth', {
--       booth = { x, y, z, netId, model, hints = { onRoad, slope, water, inside } }
--   })
--   hints 只能让服务端判得更严，绝不能放宽 —— 所以这里绝不把 true 改写成 false。
-- ==============================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 常量
-- ==============================================================

local E_CONTROL = 38                 -- INPUT_CONTEXT（E）

-- 拒绝文案与 UX 规格 §3.3 / 服务端 QuestBooth.REASON 保持一致。
-- 客户端画预览用同一套文案，玩家就不会看到「客户端说能放、服务端换句话拒绝」。
local REASON = {
    TOO_FAR    = '离租赁点太远',
    ON_ROAD    = '挡在车道上，换个位置',
    TOO_CLOSE  = '旁边已经有摊位',
    UNSTABLE   = '这里放不稳',
    FORBIDDEN  = '这里不许摆摊',
}

local DEFAULT_MAX_DISTANCE  = 200.0
local DEFAULT_ROAD_CLEARANCE = 6.0
local DEFAULT_MIN_SEPARATION = 15.0

local GRAB_DISTANCE      = 2.5       -- 玩家与推车中心距离 ≤ 2.5m 才能抓
local PREVIEW_FORWARD    = 0.8       -- 预览点放在玩家身前 0.8m，避免推车落在人身上
local SLOPE_LIMIT        = 0.55      -- 前后 1.5m 采样点高差超过 0.55m 视为「放不稳」
local WATER_MARGIN       = 0.30      -- 地面低于水面 +0.3m 视为水边
local HEAVY_CHECK_MS     = 80        -- 重型 native（路网/间隔/坡度/水/室内）的节流间隔
local HEAVY_MOVE_DIST    = 0.40      -- 玩家移动超过 0.4m 立即重算，避免绿圈滞后
local SPAWN_RETRY_NOTIFY = 6000      -- 「推车没生成」提示的间隔
local PUSH_REMINDER_MS   = 12000     -- 推车中的「按 E 放下」提醒间隔
local REPORT_WAIT_MS     = 15000     -- 上报后等服务端推进的超时；超时允许重试
local VEHICLE_WARN_MS    = 4000      -- 「先下车」提示的节流

-- ==============================================================
-- 本地状态（不要提升成全局！）
-- ==============================================================

local BoothState = {
    active      = false,
    questId     = nil,
    stepId      = nil,
    cfg         = nil,       -- NormalizeBoothConfig 后的配置
    generation  = 0,         -- 每次激活/重置 +1，用来作废还在 yield 的旧线程

    cart        = nil,       -- 推车实体句柄
    spawning    = false,
    spawnFailed = false,

    pushing     = false,     -- 已挂到玩家身前
    previewing  = false,     -- 正在摆放预览
    confirming  = false,     -- 正在等 netId / 发 nodeComplete
    placed      = false,     -- 已上报，等 stepAdvanced（推车必须留着给服务端查）

    preview     = nil,       -- 上一帧算出的预览结果（pos / legal / reason / hints / 缓存）
    reportSeq   = 0,         -- 看门狗序号，Reset 后旧回调失效

    lastKeyAt       = 0,
    lastSpawnNotify = 0,
    lastPushRemind  = 0,
    lastVehWarn     = 0,
    near            = false,
    lastVerdictKey  = nil,
}

-- ==============================================================
-- 小工具
-- ==============================================================

local function Notify(text, kind, duration)
    if not text then return end
    if duration then
        QBCore.Functions.Notify(text, kind or 'primary', duration)
    else
        QBCore.Functions.Notify(text, kind or 'primary')
    end
end

--- FiveM 的 BOOL native 有时返回 1/0 而不是 true/false
local function NativeBool(value)
    return value == true or value == 1
end

--- 句柄可能为 nil（还没生成）或 0（已失效）。直接 DoesEntityExist(nil) 会炸，
--- 所以所有实体操作统一走这个入口。
local function EntityExists(entity)
    return entity ~= nil and entity ~= 0 and NativeBool(DoesEntityExist(entity))
end

--- vector3 / {x,y,z} 统一成 vector3
local function ToVec3(value)
    if type(value) ~= 'table' and type(value) ~= 'vector3' then return nil end
    local x, y, z = value.x, value.y, value.z
    if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
    return vector3(x, y, tonumber(z) or 0.0)
end

--- 把模板里的 booth 配置归一化。
--- 同时兼容三种形状（仓库里的模板用第二种）：
---   1. { booth = { model=..., rental_point=... } }          —— 任务书里的契约形状
---   2. { type='booth', data = { model=..., rental_point=... } } —— quest_hotdog.lua 实际形状
---   3. 直接把 data 表当参数传进来（stepAdvanced 的 next_step_data）
local function NormalizeBoothConfig(stepLike)
    if type(stepLike) ~= 'table' then return nil end

    local raw
    if type(stepLike.booth) == 'table' then
        raw = stepLike.booth
    elseif type(stepLike.data) == 'table' then
        raw = type(stepLike.data.booth) == 'table' and stepLike.data.booth or stepLike.data
    else
        raw = stepLike
    end
    if type(raw) ~= 'table' then return nil end

    local model = raw.model
    local rentalPoint = ToVec3(raw.rental_point)
    if type(model) ~= 'string' or model == '' or not rentalPoint then
        return nil
    end

    local zones = {}
    if type(raw.forbidden_zones) == 'table' then
        for _, zone in ipairs(raw.forbidden_zones) do
            if type(zone) == 'table' and type(zone.x) == 'number' and type(zone.y) == 'number' then
                zones[#zones + 1] = {
                    x = zone.x,
                    y = zone.y,
                    r = tonumber(zone.r) or tonumber(zone.radius) or 10.0,
                }
            end
        end
    end

    return {
        model          = model,
        modelHash      = joaat(model),
        rentalPoint    = rentalPoint,
        maxDistance    = tonumber(raw.max_distance) or DEFAULT_MAX_DISTANCE,
        roadClearance  = tonumber(raw.road_clearance) or DEFAULT_ROAD_CLEARANCE,
        minSeparation  = tonumber(raw.min_separation) or DEFAULT_MIN_SEPARATION,
        forbiddenZones = zones,
        label          = raw.label,
    }
end

-- ==============================================================
-- 实体清理
--
-- 推车必须由客户端删：它是客户端生成的网络实体，服务端只认识 netId。
-- 任何「这一步已经不需要推车」的路径都要走到这里，否则推车会永久留在地图上。
-- ==============================================================

local function DeleteCart(reason)
    local cart = BoothState.cart
    local wasPushing = BoothState.pushing

    BoothState.cart = nil
    BoothState.pushing = false
    BoothState.previewing = false
    BoothState.preview = nil
    BoothState.confirming = false
    BoothState.near = false

    if EntityExists(cart) then
        -- 先脱钩再删：挂接中的实体直接 DeleteEntity 在部分版本会留下幽灵碰撞体
        if wasPushing then
            DetachEntity(cart, true, true)
        end
        SetEntityAsMissionEntity(cart, true, true)
        DeleteEntity(cart)
        print(('[quest-hotdog-client] 🧹 推车已删除：%s'):format(tostring(reason)))
    end
end

-- ==============================================================
-- 停下线程但保留实体（摊位已经摆好，只是这一步不再需要玩家操作）
--
-- 与 ResetBooth 的区别只有一条：**不删推车**。摆下去的车就是摊位本身，
-- 服务端的实体注册表指着它的 netId；后面售卖与还车都要用同一辆。
-- ==============================================================

local function HaltBooth(reason)
    BoothState.generation = BoothState.generation + 1   -- 作废旧 spawn/report 线程
    BoothState.reportSeq = BoothState.reportSeq + 1     -- 作废旧看门狗

    local cart = BoothState.cart
    if BoothState.pushing and EntityExists(cart) then
        -- 必须脱钩：否则玩家走开时会把摊位一起拖走
        DetachEntity(cart, true, true)
        SetEntityCollision(cart, true, true)
        FreezeEntityPosition(cart, true)
    end

    -- 注意：**不清 questId** —— 任务结束的清理要按 questId 匹配这辆车
    BoothState.active = false
    BoothState.stepId = nil
    BoothState.cfg = nil
    BoothState.pushing = false
    BoothState.previewing = false
    BoothState.preview = nil
    BoothState.confirming = false
    BoothState.near = false
    BoothState.spawning = false
    BoothState.placed = false
    BoothState.lastVerdictKey = nil
    print(('[quest-hotdog-client] ⏸️ 摊位线程停止（实体保留）：%s'):format(tostring(reason)))
end

local function ResetBooth(reason)
    BoothState.generation = BoothState.generation + 1   -- 作废旧 spawn/report 线程
    BoothState.reportSeq = BoothState.reportSeq + 1     -- 作废旧看门狗

    DeleteCart(reason)

    BoothState.active = false
    BoothState.questId = nil
    BoothState.stepId = nil
    BoothState.cfg = nil
    BoothState.spawning = false
    BoothState.spawnFailed = false
    BoothState.placed = false
    BoothState.lastVerdictKey = nil
    BoothState.lastPushRemind = 0
    BoothState.lastVehWarn = 0
end

-- ==============================================================
-- 生成推车
--
-- 生成在**玩家身边**而不是租赁点：玩家可能已经走到目标点（前一步是 reach），
-- 再让他跑回租赁点取车没有意义。
-- ==============================================================

local function SpawnCart(generation, force)
    if generation ~= BoothState.generation then return end
    if not force and BoothState.spawning then return end
    if not BoothState.active or not BoothState.cfg then return end
    if BoothState.placed then return end
    if EntityExists(BoothState.cart) then return end

    BoothState.spawning = true
    local cfg = BoothState.cfg
    local modelHash = cfg.modelHash

    RequestModel(modelHash)
    local deadline = GetGameTimer() + 5000
    while not NativeBool(HasModelLoaded(modelHash)) and GetGameTimer() < deadline do
        Wait(50)
        if generation ~= BoothState.generation then
            SetModelAsNoLongerNeeded(modelHash)
            return
        end
    end

    if not NativeBool(HasModelLoaded(modelHash)) then
        SetModelAsNoLongerNeeded(modelHash)
        if generation == BoothState.generation then
            BoothState.spawning = false
            BoothState.spawnFailed = true
            Notify('推车没生成出来（模型加载失败），按 [E] 再试一次', 'error', 6000)
        end
        return
    end

    -- RequestModel 会 yield，回来再确认一次任务还在、还是同一次激活
    if generation ~= BoothState.generation then
        SetModelAsNoLongerNeeded(modelHash)
        return
    end
    if not BoothState.active or BoothState.placed then
        SetModelAsNoLongerNeeded(modelHash)
        BoothState.spawning = false
        return
    end

    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    local veh = GetVehiclePedIsIn(ped, false)
    local x, y, heading

    if veh and veh ~= 0 then
        -- 玩家还在车上（刚开车到摊位点）：放在车左侧，别塞进车头
        local vehCoords = GetEntityCoords(veh)
        heading = GetEntityHeading(veh)
        local rad = math.rad(heading)
        x = vehCoords.x - math.cos(rad) * 2.6
        y = vehCoords.y - math.sin(rad) * 2.6
    else
        -- 站在地上：放在身前 1.8m，不与人重叠、伸手就能抓
        heading = GetEntityHeading(ped)
        local rad = math.rad(heading)
        x = pedCoords.x - math.sin(rad) * 1.8
        y = pedCoords.y + math.cos(rad) * 1.8
    end

    -- 先探一次地面高度；探不到就让 PlaceObjectOnGroundProperly 兜底
    local z = pedCoords.z + 0.3
    local foundGround, groundZ = GetGroundZFor_3dCoord(x, y, pedCoords.z + 2.0, false)
    if NativeBool(foundGround) and groundZ ~= nil then
        z = groundZ + 0.3
    end

    local cart = CreateObject(modelHash, x, y, z, true, true, false)
    SetModelAsNoLongerNeeded(modelHash)

    Wait(0)   -- 给引擎一帧把实体注册进网络

    if generation ~= BoothState.generation then
        if EntityExists(cart) then DeleteEntity(cart) end
        return
    end
    if not EntityExists(cart) then
        BoothState.spawning = false
        BoothState.spawnFailed = true
        Notify('推车没生成出来，按 [E] 再试一次', 'error', 6000)
        return
    end

    SetEntityAsMissionEntity(cart, true, true)
    PlaceObjectOnGroundProperly(cart)
    SetEntityHeading(cart, heading)
    FreezeEntityPosition(cart, true)      -- 抓起前冻结，防止被路过车辆/npc 推走
    SetEntityInvincible(cart, true)
    SetEntityCollision(cart, true, true)

    BoothState.cart = cart
    BoothState.spawning = false
    BoothState.spawnFailed = false
    BoothState.near = false

    Notify('🛒 推车已就位', 'primary')
    print(('[quest-hotdog-client] 🛒 推车已生成：model=%s entity=%d'):format(cfg.model, cart))
end

-- ==============================================================
-- 抓车 / 放下
-- ==============================================================

local function GrabCart()
    local cart = BoothState.cart
    if not EntityExists(cart) then return end

    local ped = PlayerPedId()
    if NativeBool(IsPedInAnyVehicle(ped, false)) then
        Notify('先下车再推车', 'error')
        return
    end

    -- 冻结的实体挂接后不会跟随，先解冻再挂
    FreezeEntityPosition(cart, false)
    SetEntityCollision(cart, false, false)

    -- offset 0.0, 1.1, -0.6（相对 ped 根骨骼）：
    --   x=0    推车在正前方，不偏左右
    --   y=1.1  让车尾把手刚好在玩家手边，手臂不用伸长
    --   z=-0.6 把车体压低到腰部/轮子接地的高度，第三人称看是「扶着推」
    -- collision=false：挂接期间推车不参与碰撞，否则会跟玩家自己互相顶、疯狂抖动。
    -- 注意：这里**不用** SetEntityCoords 每帧硬拽；挂接本身负责跟随。
    -- 也**不**额外 ApplyForceToEntity：挂接已经逐帧对齐，再叠加推力只会和挂接解算
    -- 打架（真机表现就是推车高频抖动），所以“向前小推力”这条可选实现直接省略。
    AttachEntityToEntity(cart, ped, 0,
        0.0, 1.1, -0.6,
        0.0, 0.0, 0.0,
        false, true, false, false, 2, true)

    BoothState.pushing = true
    BoothState.previewing = false
    BoothState.preview = nil
    BoothState.lastPushRemind = GetGameTimer()

    Notify('🛒 已抓住推车 — 走到位置后按 [E] 放下', 'primary')
end

local function DropToPreview()
    local cart = BoothState.cart
    if not EntityExists(cart) then
        BoothState.pushing = false
        return
    end

    DetachEntity(cart, true, true)
    SetEntityCollision(cart, false, false)   -- 预览是幽灵：不挡玩家、不挡路人
    PlaceObjectOnGroundProperly(cart)
    FreezeEntityPosition(cart, true)

    BoothState.pushing = false
    BoothState.previewing = true
    BoothState.preview = nil
    BoothState.lastVerdictKey = nil
    BoothState.near = false

    Notify('📍 摆放预览 — 走到合适位置，按 [E] 放下', 'primary')
end

-- ==============================================================
-- 摆放预览：客户端只负责「画」，服务端仍会重算
-- ==============================================================

--- 从 (x,y) 向下打一条 ray 取地面点；打不到就用 GetGroundZFor_3dCoord 兜底。
local function RaycastGround(x, y, z)
    local handle = StartShapeTestRay(x, y, z + 1.0, x, y, z - 20.0, 1, 0, 0)
    local result, hit, endCoords
    for _ = 1, 3 do
        result, hit, endCoords = GetShapeTestResult(handle)
        if result ~= 1 then break end       -- 1 = pending；其它值 = 已有结果
        Wait(0)
    end

    if result ~= 1 and NativeBool(hit) and endCoords then
        return vector3(endCoords.x, endCoords.y, endCoords.z)
    end

    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 1.0, false)
    -- 高差超过 5m 的结果不可信：桥面/天桥下探到的是远处地面，照它摆会把车
    -- 放到桥底。宁可这一帧判「放不稳」，也不要给玩家一个错误的绿色位置。
    if NativeBool(found) and groundZ ~= nil and math.abs(groundZ - z) <= 5.0 then
        return vector3(x, y, groundZ)
    end
    return nil
end

--- 沿玩家朝向前后 1.5m 取两点高差，判断推车放上去会不会歪。
local function GroundSlopeDelta(x, y, z, heading)
    local rad = math.rad(heading)
    local fx = x - math.sin(rad) * 1.5
    local fy = y + math.cos(rad) * 1.5
    local okA, zA = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    local okB, zB = GetGroundZFor_3dCoord(fx, fy, z + 2.0, false)
    if NativeBool(okA) and NativeBool(okB) and zA ~= nil and zB ~= nil then
        return math.abs(zA - zB)
    end
    return 0.0
end

local function IsWaterAt(x, y, z)
    if type(GetWaterHeight) ~= 'function' then return false end
    local found, waterZ = GetWaterHeight(x, y, z)
    return NativeBool(found) and waterZ ~= nil and z <= (waterZ + WATER_MARGIN)
end

--- 用预览坐标判断，而不是只看玩家：玩家可能站在门口、推车位置在室内。
local function IsInsideAt(x, y, z, ped)
    if type(GetInteriorAtCoords) == 'function' then
        local interior = GetInteriorAtCoords(x, y, z)
        if interior and interior ~= 0 then return true end
        return false
    end
    if type(GetInteriorFromEntity) == 'function' then
        local interior = GetInteriorFromEntity(ped)
        return interior ~= nil and interior ~= 0
    end
    return false
end

--- 返回 (是否压在路上, 是否离路面节点太近)
local function RoadInfo(x, y, z, clearance)
    local onRoad = false
    if type(IsPointOnRoad) == 'function' then
        onRoad = NativeBool(IsPointOnRoad(x, y, z))
    end

    local roadDistance = nil
    if type(GetClosestVehicleNode) == 'function' then
        local found, nodeCoords = GetClosestVehicleNode(x, y, z, 0, 100.0, 0)
        if NativeBool(found) and nodeCoords then
            roadDistance = #(vector3(x, y, z) - vector3(nodeCoords.x, nodeCoords.y, nodeCoords.z))
        end
    end

    return onRoad, (roadDistance ~= nil and roadDistance < clearance)
end

--- 「旁边已经有摊位」只看**玩家摆的**摊位，不看地图上的静态热狗壳。
--- 静态 prop 不是网络实体；如果把它也算进去，旧热狗壳点位（摆位 A）会永远红。
local function HasNearbyBooth(x, y, z, modelHash, minSeparation, ownCart)
    local objects = GetGamePool('CObject') or {}
    local minSq = minSeparation * minSeparation
    for _, object in ipairs(objects) do
        if object ~= ownCart and DoesEntityExist(object) and GetEntityModel(object) == modelHash then
            local coords = GetEntityCoords(object)
            local dx, dy = coords.x - x, coords.y - y
            if (dx * dx + dy * dy) < minSq then
                local networked = type(NetworkGetEntityIsNetworked) == 'function'
                    and NativeBool(NetworkGetEntityIsNetworked(object))
                if networked or NativeBool(IsEntityAMissionEntity(object)) then
                    return true
                end
            end
        end
    end
    return false
end

local function InForbiddenZone(cfg, x, y)
    for _, zone in ipairs(cfg.forbiddenZones or {}) do
        local dx, dy = x - zone.x, y - zone.y
        if (dx * dx + dy * dy) < (zone.r * zone.r) then
            return true
        end
    end
    return false
end

--- 每帧刷新预览：地面点每帧都取（要跟手），重型判据按 HEAVY_CHECK_MS 节流。
local function UpdatePreview(ped, cart)
    local cfg = BoothState.cfg
    if not cfg then return end

    -- RaycastGround 里可能 Wait(0)；如果这期间任务结束/换了步骤，
    -- generation 会变、推车可能已经被删。回来必须先验代次，不能继续动旧句柄。
    local generation = BoothState.generation

    local pedCoords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)

    -- 预览点放在玩家身前 0.8m：从玩家脚下向下打 ray 取的是地面高度，
    -- x/y 前移是为了不让推车直接落在玩家身上（放下时碰撞会重新打开）。
    local px = pedCoords.x - math.sin(rad) * PREVIEW_FORWARD
    local py = pedCoords.y + math.cos(rad) * PREVIEW_FORWARD
    local ground = RaycastGround(px, py, pedCoords.z)

    if generation ~= BoothState.generation or not EntityExists(cart) then return end

    local pv = BoothState.preview
    if not pv then
        pv = { hints = {} }
        BoothState.preview = pv
    end

    if not ground then
        pv.pos = vector3(px, py, pedCoords.z)
        pv.heading = heading
        pv.legal = false
        pv.reason = REASON.UNSTABLE
        pv.hints = { onRoad = false, slope = false, water = false, inside = false }
        -- 清掉重型缓存：下一帧重新探到地面时必须强制重算，
        -- 否则会拿「没地面那一帧」之前的旧数据判绿。
        pv.heavyPos = nil
        return
    end

    local x, y, z = ground.x, ground.y, ground.z

    -- 预览阶段允许 SetEntityCoords 拖动：推车是冻结的「幽灵」，
    -- 不是物理推着走，所以不会出现推车状态下那种硬拽抖动。
    SetEntityCoordsNoOffset(cart, x, y, z, false, false, false)
    SetEntityHeading(cart, heading)

    pv.pos = vector3(x, y, z)
    pv.heading = heading

    -- 重型 native 节流：位置变了 0.4m 或过了 80ms 才重算
    local now = GetGameTimer()
    local needHeavy = (not pv.heavyPos)
        or (now - (pv.heavyAt or 0) >= HEAVY_CHECK_MS)
        or (#(vector3(x, y, z) - pv.heavyPos) > HEAVY_MOVE_DIST)

    if needHeavy then
        local onRoadFlag, nearRoad = RoadInfo(x, y, z, cfg.roadClearance)
        local slopeDelta = GroundSlopeDelta(x, y, z, heading)
        local water = IsWaterAt(x, y, z)
        local inside = IsInsideAt(x, y, z, ped)
        local tooClose = HasNearbyBooth(x, y, z, cfg.modelHash, cfg.minSeparation, cart)
        local forbidden = InForbiddenZone(cfg, x, y)

        -- hints 只上报「检测到的坏消息」。true 只会让服务端更严，
        -- 绝不能在这里把 true 抹成 false（那才是放宽校验）。
        pv.hints = {
            onRoad = onRoadFlag or nearRoad,
            slope  = slopeDelta > SLOPE_LIMIT,
            water  = water,
            inside = inside,
        }
        pv.tooClose = tooClose
        pv.forbidden = forbidden
        pv.heavyAt = now
        pv.heavyPos = vector3(x, y, z)
    end

    -- 距离判据每帧算（很便宜），保证玩家往远处走时绿圈立刻变红
    local dx, dy = x - cfg.rentalPoint.x, y - cfg.rentalPoint.y
    local tooFar = (dx * dx + dy * dy) > (cfg.maxDistance * cfg.maxDistance)

    -- 判定顺序必须和 server/quest_booth.lua 的 Evaluate 一致：
    -- hints（不稳）→ 距离 → 路面 → 间隔 → 禁摆区。否则同一个点两边文案会不同。
    local legal, reason = true, nil
    if pv.hints.slope or pv.hints.water or pv.hints.inside then
        legal, reason = false, REASON.UNSTABLE
    elseif tooFar then
        legal, reason = false, REASON.TOO_FAR
    elseif pv.hints.onRoad then
        legal, reason = false, REASON.ON_ROAD
    elseif pv.tooClose then
        legal, reason = false, REASON.TOO_CLOSE
    elseif pv.forbidden then
        legal, reason = false, REASON.FORBIDDEN
    end

    pv.legal = legal
    pv.reason = reason
end

local function DrawPreviewMarker(pos, legal, reason)
    if not pos then return end

    local r, g, b = 230, 70, 70
    if legal then r, g, b = 60, 220, 90 end

    -- 圆环 + 薄圆盘：框的大小就是摊位占地，红/绿不靠颜色单独表达（还有下面的文字）
    DrawMarker(28, pos.x, pos.y, pos.z + 0.08,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        1.6, 1.6, 1.0,
        r, g, b, 170,
        false, false, 2, false, nil, nil, false)

    DrawMarker(1, pos.x, pos.y, pos.z + 0.01,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        1.4, 1.4, 0.06,
        r, g, b, 55,
        false, false, 2, false, nil, nil, false)

    -- 红框上方给具体原因（UX §3.3：只说「不能摆」等于没说）
    local text = legal and '✅ 这里可以摆摊 · [E] 放下' or ('❌ ' .. (reason or REASON.UNSTABLE))
    SetDrawOrigin(pos.x, pos.y, pos.z + 1.6, 0)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    SetTextScale(0.36, 0.36)
    SetTextColour(r, g, b, 255)
    SetTextCentre(true)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

-- ==============================================================
-- 上报
--
-- 上报后**不能**立刻删推车：server/quest_booth.lua 会拿 netId 反查实体，
-- 校验「实体存在 + 在玩家 50m 内 + 模型一致」。删早了服务端只会看到
-- 「找不到那辆推车」，玩家则卡在「位置明明能放却报错」。
-- ==============================================================

local function ConfirmPlacement()
    local cart = BoothState.cart
    local pv = BoothState.preview
    if not EntityExists(cart) or not pv or not pv.legal then return end
    if BoothState.confirming or BoothState.placed then return end

    BoothState.confirming = true
    BoothState.previewing = false

    -- 确认时立刻冻住并恢复碰撞：推车已经是一个「摊位」，不能再被推走
    FreezeEntityPosition(cart, true)
    SetEntityCollision(cart, true, true)

    local questId = BoothState.questId
    local stepId = BoothState.stepId
    local model = BoothState.cfg.model
    local generation = BoothState.generation

    -- 快照 hints：预览表下一帧还会被写，别让序列化拿到半更新的值
    local hints = {
        onRoad = pv.hints.onRoad == true,
        slope  = pv.hints.slope == true,
        water  = pv.hints.water == true,
        inside = pv.hints.inside == true,
    }

    Notify('📤 正在确认摊位位置...', 'primary')

    CreateThread(function()
        -- 实体刚生成/刚移动时 netId 可能还是 0。服务端只认 netId，
        -- 这里最多等 2 秒，等不到就退回预览让玩家重试，绝不发一个 0 上去。
        local netId = NetworkGetNetworkIdFromEntity(cart)
        local deadline = GetGameTimer() + 2000
        while (not netId or netId == 0) and GetGameTimer() < deadline do
            Wait(50)
            if generation ~= BoothState.generation or not EntityExists(cart) then break end
            netId = NetworkGetNetworkIdFromEntity(cart)
        end

        if generation ~= BoothState.generation then return end
        if not BoothState.active or BoothState.questId ~= questId or BoothState.stepId ~= stepId then
            BoothState.confirming = false
            return
        end

        if not EntityExists(cart) then
            BoothState.confirming = false
            BoothState.previewing = true
            Notify('推车在确认前消失了，按 [E] 重新生成', 'error', 6000)
            return
        end

        if not netId or netId == 0 then
            BoothState.confirming = false
            BoothState.previewing = true
            Notify('推车还没同步好，稍等再按 [E] 试一次', 'error', 6000)
            return
        end

        local coords = GetEntityCoords(cart)

        BoothState.reportSeq = BoothState.reportSeq + 1
        local seq = BoothState.reportSeq
        BoothState.confirming = false
        BoothState.placed = true

        print(('[quest-hotdog-client] 📤 booth 上报：quest=%s step=%s netId=%d pos=(%.1f,%.1f,%.1f) hints(road=%s slope=%s water=%s inside=%s)')
            :format(questId, stepId, netId, coords.x, coords.y, coords.z,
                tostring(hints.onRoad), tostring(hints.slope), tostring(hints.water), tostring(hints.inside)))

        TriggerServerEvent('quest:server:nodeComplete', questId, stepId, 'booth', {
            booth = {
                x = coords.x,
                y = coords.y,
                z = coords.z,
                netId = netId,
                model = model,
                hints = hints,
            },
        })

        -- 服务端拒绝时只发通知、不会推进步骤；客户端不能永远卡在 placed。
        -- 15 秒后还没收到 stepAdvanced / completed / failed，就退回预览允许重试。
        -- （服务端校验是同步的；留 15 秒是给最后一步的 DB 结算留余量。）
        SetTimeout(REPORT_WAIT_MS, function()
            if BoothState.reportSeq ~= seq or not BoothState.active then return end
            if not BoothState.placed then return end
            BoothState.placed = false
            BoothState.previewing = true
            BoothState.lastVerdictKey = nil   -- 重新进入预览，让红/绿提示能再弹一次
            if EntityExists(cart) then
                SetEntityCollision(cart, false, false)
                FreezeEntityPosition(cart, true)
            end
            Notify('⏳ 服务端还没有确认摊位，可以再按 [E] 试一次', 'error', 6000)
        end)
    end)
end

-- ==============================================================
-- 激活 / 清理事件
-- ==============================================================

local function ActivateBooth(questId, stepId, cfg)
    -- 重复进入同一步骤：不要生成第二辆。
    -- （重连、资源重启、服务端重发都可能让 accepted/stateRestore 再来一次。）
    if BoothState.active and BoothState.questId == questId and BoothState.stepId == stepId then
        return
    end

    -- 换任务/换步骤：旧推车先删，保证一个玩家同一时刻只有一辆
    ResetBooth('activate')

    BoothState.generation = BoothState.generation + 1
    local generation = BoothState.generation

    BoothState.active = true
    BoothState.questId = questId
    BoothState.stepId = stepId
    BoothState.cfg = cfg
    BoothState.spawning = true   -- 先占位，避免主线程在 spawn 线程启动前误报「没生成出来」
    BoothState.lastSpawnNotify = GetGameTimer()

    print(('[quest-hotdog-client] 🎯 进入 booth 步骤：quest=%s step=%s model=%s'):format(
        tostring(questId), tostring(stepId), tostring(cfg.model)))

    Notify('🛒 摆摊：靠近推车按 [E] 抓住，推到合适位置按 [E] 放下', 'primary')

    CreateThread(function()
        SpawnCart(generation, true)
    end)
end

--- 从 full step（accepted / stateRestore 会带完整 steps）里找当前步
local function FindStep(steps, stepId)
    for _, step in ipairs(steps or {}) do
        if step.id == stepId then return step end
    end
    return nil
end

local function HandleCurrentStep(questId, stepId, step, sourceTag)
    if not step then
        -- 同一个任务但找不到当前步（payload 不完整）：宁可把推车收掉，也不要留孤儿
        if BoothState.active and BoothState.questId == questId then
            ResetBooth(('missing_step:' .. tostring(sourceTag)))
        end
        return
    end
    local stepType = string.lower(tostring(step.type or ''))
    if stepType == 'booth' then
        local cfg = NormalizeBoothConfig(step)
        if cfg then
            ActivateBooth(questId, stepId, cfg)
        else
            Notify('摊位配置缺失（model / rental_point），请联系管理员', 'error', 8000)
            print(('[quest-hotdog-client] ⚠️ booth 配置无效（%s）：quest=%s step=%s')
                :format(tostring(sourceTag), tostring(questId), tostring(stepId)))
        end
    elseif BoothState.active and BoothState.questId == questId then
        -- 同一个任务进入非 booth 步骤：这一步不再需要推车
        ResetBooth(('step:' .. tostring(sourceTag)))
    end
end

-- 接受任务：第一步可能就是 booth
RegisterNetEvent(Config.Quest.Events.QUEST_ACCEPTED, function(data)
    if type(data) ~= 'table' or not data.quest_id then return end
    local step = FindStep(data.steps, data.current_step)
    HandleCurrentStep(data.quest_id, data.current_step, step, 'accepted')
end)

-- 步骤推进：next_step_type 是模板里的原始小写类型（booth）
RegisterNetEvent(Config.Quest.Events.QUEST_STEP_ADVANCED, function(data)
    if type(data) ~= 'table' or not data.quest_id then return end

    local stepType = string.lower(tostring(data.next_step_type or ''))
    if stepType == 'booth' then
        local cfg = NormalizeBoothConfig(data.next_step_data)
        if cfg then
            ActivateBooth(data.quest_id, data.to_step, cfg)
        else
            Notify('摊位配置缺失（model / rental_point），请联系管理员', 'error', 8000)
            print(('[quest-hotdog-client] ⚠️ stepAdvanced 的 booth 配置无效：quest=%s step=%s')
                :format(tostring(data.quest_id), tostring(data.to_step)))
        end
    elseif BoothState.active and BoothState.questId == data.quest_id then
        -- 推进到下一步（例如「回租赁点」）：**不能删推车**。
        --
        -- 摆下去的那辆车就是摊位本身：服务端的 QuestEntityRegistry 里登记着它的 netId，
        -- 后面的售卖阶段（S4）与还车（S5）都要用同一辆。早先这里直接 ResetBooth 删实体，
        -- 结果是「放置成功的瞬间摊位从地图上消失」，而服务端还以为自己有个摊位。
        -- 正确做法：只停线程（不再响应 E、不再画预览），实体留给任务结束统一回收。
        HaltBooth('stepAdvanced')
    end
end)

-- 重连 / 资源重启后的状态恢复：full steps 里有当前步
RegisterNetEvent(Config.Quest.Events.QUEST_STATE_RESTORE, function(data)
    if type(data) ~= 'table' or not data.quest_id then return end
    local step = FindStep(data.steps, data.current_step)
    HandleCurrentStep(data.quest_id, data.current_step, step, 'restore')
end)

-- 任务结束的三条路径：完成 / 失败 / 放弃。都要删车，否则地图上留一辆孤儿推车。
local function CleanupOnQuestEnd(data, reason)
    local questId = type(data) == 'table' and (data.quest_id or data.questId) or nil
    -- 摊位可能已经 Halt（推进到「回租赁点」后 active=false），实体还在 —— 结束时必须删，
    -- 否则玩家完成任务后地图上会永久留一辆推车。所以判据是「有没有实体」，不是「active」。
    if not BoothState.active and not EntityExists(BoothState.cart) then return end
    if questId and BoothState.questId and questId ~= BoothState.questId then return end
    ResetBooth(reason)
end

RegisterNetEvent(Config.Quest.Events.QUEST_COMPLETED, function(data)
    CleanupOnQuestEnd(data, 'completed')
end)

RegisterNetEvent(Config.Quest.Events.QUEST_FAILED, function(data)
    CleanupOnQuestEnd(data, 'failed')
end)

RegisterNetEvent(Config.Quest.Events.QUEST_ABANDONED, function(data)
    CleanupOnQuestEnd(data, 'abandoned')
end)

-- 节点取消（服务端主动收节点）：只清对应任务/步骤
RegisterNetEvent('quest:client:nodeCancel', function(data)
    if type(data) ~= 'table' then return end
    if not BoothState.active then return end
    if data.questId and data.questId ~= BoothState.questId then return end
    if data.stepId and data.stepId ~= BoothState.stepId then return end
    ResetBooth('nodeCancel')
end)

RegisterNetEvent('quest:client:nodeCancelAll', function(data)
    if not BoothState.active then return end
    if type(data) == 'table' and data.questId and data.questId ~= BoothState.questId then return end
    ResetBooth('nodeCancelAll')
end)

-- clearAllNodes 是任务结束/切换时的兜底清理事件（可能不带 questId）
RegisterNetEvent('quest:client:clearAllNodes', function(data)
    if not BoothState.active then return end
    if type(data) == 'table' and data.questId and data.questId ~= BoothState.questId then return end
    ResetBooth('clearAllNodes')
end)

-- 资源停止：客户端实体不删会一直留在世界里（服务端只认 netId，停服后也查不到）
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    ResetBooth('resourceStop')
end)

-- ==============================================================
-- 主线程：生成重试 + 抓车 / 放下 / 确认 + 预览绘制
--
-- 只在有 booth 步骤时跑 Wait(0)；空闲时 Wait(500)。
-- 不在这里做重活：重型判据在 UpdatePreview 里按 80ms 节流。
-- ==============================================================

Citizen.CreateThread(function()
    while true do
        if not BoothState.active then
            Wait(500)
        else
            Wait(0)

            local ped = PlayerPedId()
            local now = GetGameTimer()
            local cart = BoothState.cart

            -- ─── 推车实体没了（被撞飞/回收/句柄失效）：允许重新生成 ───
            if not EntityExists(cart) then
                if cart ~= nil then
                    -- 句柄以前存在、现在没了：把挂接/预览状态一起退掉
                    BoothState.cart = nil
                    BoothState.pushing = false
                    BoothState.previewing = false
                    BoothState.preview = nil
                    if BoothState.placed then
                        -- 已上报但实体消失：服务端会查不到，撤回上报让玩家重来
                        BoothState.placed = false
                        BoothState.reportSeq = BoothState.reportSeq + 1
                        Notify('推车在确认前不见了，正在等待重新领取...', 'error', 5000)
                    end
                end

                if not BoothState.spawning and not BoothState.placed then
                    if now - BoothState.lastSpawnNotify >= SPAWN_RETRY_NOTIFY then
                        BoothState.lastSpawnNotify = now
                        Notify('推车没生成出来，按 [E] 再试一次', 'error')
                    end
                    if NativeBool(IsControlJustPressed(0, E_CONTROL)) and now - BoothState.lastKeyAt > 300 then
                        BoothState.lastKeyAt = now
                        local generation = BoothState.generation
                        CreateThread(function()
                            SpawnCart(generation, true)
                        end)
                    end
                end

            -- ─── 推车中 ───
            elseif BoothState.pushing then
                local inVehicle = NativeBool(IsPedInAnyVehicle(ped, false))
                local dead = NativeBool(IsEntityDead(ped))

                if inVehicle or dead then
                    -- 上车/死亡时挂接会把推车拖进车里/尸体边，必须主动脱手
                    DetachEntity(cart, true, true)
                    FreezeEntityPosition(cart, true)
                    SetEntityCollision(cart, true, true)
                    BoothState.pushing = false
                    Notify('推车已脱手；回来靠近按 [E] 再抓', 'error')
                else
                    if now - BoothState.lastPushRemind >= PUSH_REMINDER_MS then
                        BoothState.lastPushRemind = now
                        Notify('走到位置后按 [E] 放下', 'primary')
                    end
                    if NativeBool(IsControlJustPressed(0, E_CONTROL)) and now - BoothState.lastKeyAt > 300 then
                        BoothState.lastKeyAt = now
                        DropToPreview()
                    end
                end

            -- ─── 摆放预览 ───
            elseif BoothState.previewing then
                local inVehicle = NativeBool(IsPedInAnyVehicle(ped, false))
                local dead = NativeBool(IsEntityDead(ped))

                if inVehicle or dead then
                    -- 预览中上车/死亡：收起预览，推车留在原地；下车后再靠近重新抓
                    BoothState.previewing = false
                    BoothState.preview = nil
                    SetEntityCollision(cart, true, true)
                    FreezeEntityPosition(cart, true)
                    if now - BoothState.lastVehWarn >= VEHICLE_WARN_MS then
                        BoothState.lastVehWarn = now
                        Notify('已收起摆放预览；下车后靠近推车按 [E] 重新开始', 'primary')
                    end
                else
                    UpdatePreview(ped, cart)
                    local pv = BoothState.preview
                    if pv then
                        DrawPreviewMarker(pv.pos, pv.legal, pv.reason)

                        -- 只在红/绿或原因变化时提示，避免每帧刷屏
                        local verdictKey = pv.legal and 'ok' or (pv.reason or '?')
                        if verdictKey ~= BoothState.lastVerdictKey then
                            BoothState.lastVerdictKey = verdictKey
                            if pv.legal then
                                Notify('✅ 这里可以摆摊，按 [E] 放下', 'success')
                            else
                                Notify('❌ ' .. (pv.reason or REASON.UNSTABLE), 'error')
                            end
                        end

                        if NativeBool(IsControlJustPressed(0, E_CONTROL)) and now - BoothState.lastKeyAt > 300 then
                            BoothState.lastKeyAt = now
                            if pv.legal then
                                ConfirmPlacement()
                            else
                                Notify('❌ ' .. (pv.reason or REASON.UNSTABLE), 'error', 3000)
                            end
                        end
                    end
                end

            -- ─── 已上报：等 stepAdvanced / completed / failed 来清理，什么都不做 ───
            elseif BoothState.placed or BoothState.confirming then
                -- 保持推车冻结；E 在这里无效，避免重复上报
                if EntityExists(cart) then
                    FreezeEntityPosition(cart, true)
                end

            -- ─── 空闲：靠近推车按 E 抓住 ───
            else
                local cartCoords = GetEntityCoords(cart)
                local pedCoords = GetEntityCoords(ped)
                local dist = #(pedCoords - cartCoords)

                if dist <= GRAB_DISTANCE then
                    if not BoothState.near then
                        BoothState.near = true
                        Notify('按 [E] 抓住推车', 'primary')
                    end
                    if NativeBool(IsControlJustPressed(0, E_CONTROL)) and now - BoothState.lastKeyAt > 300 then
                        BoothState.lastKeyAt = now
                        GrabCart()
                    end
                elseif BoothState.near and dist > GRAB_DISTANCE + 2.0 then
                    BoothState.near = false
                end
            end
        end
    end
end)

print('[quest-hotdog-client] 🌭 S2 客户端已就绪：生成 / 抓取 / 摆放预览 / netId 上报')
