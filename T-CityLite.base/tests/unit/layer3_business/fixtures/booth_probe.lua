-- booth_probe.lua — 真跑 quest_booth.lua（不复制实现），只桩外部符号
--
-- 覆盖 S2 计划里的六条：五种拒绝 + 一种合法，外加三条实体登记不变量：
--   1 离租赁点 > max_distance        → 离租赁点太远
--   2 压在路面上（离线点）           → 挡在车道上，换个位置
--   3 客户端 onRoad 否决             → 挡在车道上，换个位置（客户端只能更严）
--   4 离别的摊位 < min_separation    → 旁边已经有摊位
--   5 客户端 slope/water/inside 否决 → 这里放不稳
--   6 禁摆区                         → 这里不许摆摊
--   7 合法位置一次通过
--   8 netId 不存在                   → 找不到那辆推车
--   9 模型对不上                     → 找不到那辆推车
--  10 Release 之后记录为空（同任务不会堆实体）
--  11 申报坐标复验（红线①）：=实体点 / 偏2m 通过，偏5m / 远40m 拒（bad_coords），
--     以及挪位后 Booths 里是**实体真坐标**而不是申报值。
--     距离桩用真元表（`__sub`/`__len`）：`#` 必须真的算欧氏距离，否则这些判据全是空转。

local SOURCE = arg[1]
if not SOURCE then error('用法: lua5.4 booth_probe.lua <quest_booth.lua>') end

-- 路网数据：故意给一个极简表（(215,-810) 附近一条路），距离计算走真实实现
local ROAD_FILE = '{"center":{"x":215.0,"y":-810.0},"radius":350.0,' ..
    '"points":[215.0,-800.0,215.0,-804.0,215.0,-808.0,215.0,-812.0]}'

-- lua5.4 没有 FiveM 的 json；这里只认 center/radius/points，够探针用
json = { decode = function(text)
    local pts = {}
    for a, b in (text or ''):gmatch('(%-?%d+%.?%d*),(%-?%d+%.?%d*)') do
        pts[#pts + 1] = tonumber(a); pts[#pts + 1] = tonumber(b)
    end
    return { points = pts, radius = 350 }
end }
GetCurrentResourceName = function() return 'custom-quest' end
LoadResourceFile = function(_, path)
    if path == 'config/quests/hotdog_roads.json' then return ROAD_FILE end
    return nil
end

-- vector3 桩：`#(a - b)` 必须真的算欧氏距离。
-- 反例（本次修复前）：`__sub` 返回普通表并把 `__len` 当成普通字段 —— Lua 的 `#`
-- 只认元方法、不认同名字段，于是 `#` 恒为 0，所有距离判据都被静默绕过。
local function Vec(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, {
        __sub = function(a, b)
            local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            return Vec(dx, dy, dz)
        end,
        __len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end,
    })
end
vector3 = Vec

-- 玩家 ped 站在实体 11 旁 2 m：距离桩修好后，50 m 判据要能通过（而不是被 838 m 误拒）。
local PLAYER_COORDS = { x = 217.0, y = -810.0, z = 30.7 }

-- 实体世界：netId → { coords, model }
local Ents = {
    [11] = { coords = { x = 215.0, y = -810.0, z = 30.7 }, model = 'prop_hotdogstand_01' },
    [12] = { coords = { x = 900.0, y = 900.0, z = 30.0 }, model = 'prop_hotdogstand_01' },  -- 太远
    [13] = { coords = { x = 216.0, y = -809.0, z = 30.7 }, model = 'prop_wrong' },
}
GetPlayerPed = function() return 1 end
GetEntityCoords = function(ent)
    local c
    if ent == 1 then
        c = PLAYER_COORDS
    else
        local record = Ents[ent]
        c = record and record.coords or { x = 0, y = 0, z = 0 }
    end
    return Vec(c.x, c.y, c.z)
end
DoesEntityExist = function(ent) return Ents[ent] ~= nil end
GetEntityModel = function(ent)
    local record = Ents[ent]
    return record and record.model or 'unknown'
end
GetHashKey = function(name) return name end
joaat = function(name) return name end

QuestEntityRegistry = {
    registered = {}, recycled = {},
    Register = function(cid, qid, kind, netId, opts)
        QuestEntityRegistry.registered[#QuestEntityRegistry.registered + 1] =
            { cid = cid, qid = qid, kind = kind, netId = netId, opts = opts or {} }
    end,
    ForceRecycleAll = function(cid, qid)
        QuestEntityRegistry.recycled[#QuestEntityRegistry.recycled + 1] = { cid = cid, qid = qid }
    end,
}

QuestValidators = { registered = {},
    Register = function(id, fn) QuestValidators.registered[id] = fn return true end }

exports = setmetatable({}, { __index = function() return setmetatable({}, {
    __index = function() return function() return nil end end }) end })

local chunk = assert(loadfile(SOURCE))
chunk()

-- 让「找实体」走我们的假世界（真实实现是 NetworkGetEntityFromNetworkId）
QuestBooth.ResolveEntity = function(netId) return Ents[netId] and netId or nil end

local results = {}
local function check(name, condition, detail)
    results[#results + 1] = { name = name, ok = condition and true or false, detail = detail }
    print(('%s %s%s'):format(condition and 'OK  ' or 'FAIL', name,
        detail and (' — ' .. tostring(detail)) or ''))
end

local CFG = {
    rental_point = { x = 215.0, y = -772.0, z = 30.5 },
    max_distance = 200.0,
    road_clearance = 6.0,
    min_separation = 15.0,
    forbidden_zones = { { x = 190.0, y = -790.0, r = 12.0 } },
}

local function evalAt(x, y, z, hints, others, roadDistance)
    return QuestBooth.Evaluate(CFG, { x = x, y = y, z = z }, hints, others, roadDistance)
end

-- 1 离租赁点太远
local ok, reason = evalAt(500.0, -900.0, 30.0, nil, nil, 100.0)
check('RV_FAR', ok == false and reason == QuestBooth.REASON.TOO_FAR, reason)

-- 2 压在路面上（离线点判据）
ok, reason = evalAt(215.0, -805.0, 30.5, nil, nil, 2.5)
check('RV_ON_ROAD_OFFLINE', ok == false and reason == QuestBooth.REASON.ON_ROAD, reason)

-- 3 客户端 onRoad 否决（客户端只能更严）
ok, reason = evalAt(230.0, -830.0, 30.4, { onRoad = true }, nil, 40.0)
check('RV_ON_ROAD_CLIENT_VETO', ok == false and reason == QuestBooth.REASON.ON_ROAD, reason)

-- 4 离别的摊位太近
ok, reason = evalAt(240.0, -838.0, 30.4, nil, { { x = 235.0, y = -835.0, z = 30.4 } }, 40.0)
check('RV_TOO_CLOSE', ok == false and reason == QuestBooth.REASON.TOO_CLOSE, reason)

-- 5 客户端说「放不稳」
for _, hint in ipairs({ { slope = true }, { water = true }, { inside = true } }) do
    local hk = next(hint)
    ok, reason = evalAt(240.0, -838.0, 30.4, hint, nil, 40.0)
    check('RV_UNSTABLE_' .. tostring(hk), ok == false and reason == QuestBooth.REASON.UNSTABLE, reason)
end

-- 6 禁摆区
ok, reason = evalAt(190.0, -790.0, 30.5, nil, nil, 40.0)
check('RV_FORBIDDEN', ok == false and reason == QuestBooth.REASON.FORBIDDEN, reason)

-- 7 合法位置一次通过
ok, reason = evalAt(240.0, -838.0, 30.4, { onRoad = false }, { { x = 300.0, y = -900.0, z = 30.0 } }, 40.0)
check('RV_OK', ok == true and reason == nil, tostring(reason))

-- 8 netId 不存在
local registered, regReason = QuestBooth.Register(1, 'cid-1', 'hotdog_dev', { x = 240, y = -838, z = 30.4 }, 99, 'prop_hotdogstand_01')
check('RV_BAD_ENTITY', registered == false and regReason == QuestBooth.REASON.BAD_ENTITY, regReason)

-- 9 模型对不上
registered, regReason = QuestBooth.Register(1, 'cid-1', 'hotdog_dev', { x = 240, y = -838, z = 30.4 }, 13, 'prop_hotdogstand_01')
check('RV_MODEL_MISMATCH', registered == false and regReason == QuestBooth.REASON.BAD_ENTITY, regReason)

-- 10 合法登记 → Release 清干净
registered = QuestBooth.Register(1, 'cid-1', 'hotdog_dev', { x = 215, y = -810, z = 30.7 }, 11, 'prop_hotdogstand_01')
check('REGISTER_OK', registered == true, tostring(QuestBooth.Count()))
check('REGISTERED_IN_REGISTRY', #QuestEntityRegistry.registered == 1
    and QuestEntityRegistry.registered[1].kind == 'booth',
    #QuestEntityRegistry.registered > 0 and QuestEntityRegistry.registered[1].kind or 'none')

local released = QuestBooth.RemoveBooth('cid-1', 'hotdog_dev', 'returned')
check('RELEASE_CLEARS', released == true and QuestBooth.Get('cid-1') == nil and QuestBooth.Count() == 0,
    tostring(QuestBooth.Count()))
check('RELEASE_RECYCLES_ENTITY', #QuestEntityRegistry.recycled == 1,
    #QuestEntityRegistry.recycled > 0 and QuestEntityRegistry.recycled[1].qid or 'none')
check('RELEASE_IS_IDEMPOTENT', QuestBooth.RemoveBooth('cid-1', 'hotdog_dev', 'again') == false)

-- ==============================================================
-- 红线①：申报坐标必须用实体真坐标复验（F 片）
-- ==============================================================
-- 实体 11 在 (215, -810, 30.7)；玩家 ped 在 (217, -810, 30.7)，即实体旁 2 m。

-- 11 申报点 = 实体点 → 通过（正控：3 m 容差没有把正常摆放卡死）
local atEntity, atEntityReason = QuestBooth.Register(1, 'cid-claim-ok', 'hotdog_dev',
    { x = 215.0, y = -810.0, z = 30.7 }, 11, 'prop_hotdogstand_01')
check('REGISTER_CLAIM_AT_ENTITY_OK', atEntity == true, atEntityReason)

-- 12 申报点偏 2 m → 通过（容差内）
local off2, off2Reason = QuestBooth.Register(1, 'cid-claim-2m', 'hotdog_dev',
    { x = 217.0, y = -810.0, z = 30.7 }, 11, 'prop_hotdogstand_01')
check('REGISTER_CLAIM_OFF_BY_2M_OK', off2 == true, off2Reason)

-- 12b 入库的是实体真坐标，不是申报值。反向语义：把 Register 的
-- `x = trueCoords.x` 改回 `x = pos.x`（Hermes 的注入）时，这条必须红。
local claim2mBooth = QuestBooth.Get('cid-claim-2m')
check('REGISTER_STORES_ENTITY_COORDS_NOT_CLAIM',
    claim2mBooth ~= nil
        and claim2mBooth.x == 215.0 and claim2mBooth.y == -810.0 and claim2mBooth.z == 30.7,
    claim2mBooth and ('%.1f, %.1f, %.1f'):format(claim2mBooth.x, claim2mBooth.y, claim2mBooth.z)
        or 'no booth')

-- 13 申报点偏 5 m → 拒，bad_coords（旧版会把 5 m 外的值原样入库）
local off5, off5Reason = QuestBooth.Register(1, 'cid-claim-5m', 'hotdog_dev',
    { x = 220.0, y = -810.0, z = 30.7 }, 11, 'prop_hotdogstand_01')
check('REGISTER_CLAIM_OFF_BY_5M_REJECTED',
    off5 == false and off5Reason == QuestBooth.REASON.COORDS_MISMATCH, off5Reason)

-- 14 申报点在玩家 50 m 内、但离实体 40 m → 拒（旧的 50 m 判据会放行）
local nearPlayerFarEntity, farReason = QuestBooth.Register(1, 'cid-claim-40m', 'hotdog_dev',
    { x = 255.0, y = -810.0, z = 30.7 }, 11, 'prop_hotdogstand_01')
check('REGISTER_CLAIM_NEAR_PLAYER_BUT_FAR_FROM_ENTITY_REJECTED',
    nearPlayerFarEntity == false and farReason == QuestBooth.REASON.COORDS_MISMATCH, farReason)

-- 15 挪位：落库的是实体真坐标，不是传进来的申报值
local moved = QuestBooth.MoveTo('cid-claim-ok', { x = 999.0, y = 999.0, z = 999.0 })
local movedBooth = QuestBooth.Get('cid-claim-ok')
check('MOVE_STORES_ENTITY_COORDS_NOT_CLAIM',
    moved == true and movedBooth ~= nil
        and movedBooth.x == 215.0 and movedBooth.y == -810.0 and movedBooth.z == 30.7,
    movedBooth and ('%.1f, %.1f, %.1f'):format(movedBooth.x, movedBooth.y, movedBooth.z)
        or 'no booth')

-- 路网点是真的被读进来了（不是走降级路径）
check('ROAD_INDEX_LOADED', type(QuestBooth.NearestRoadDistance(215.0, -805.0)) == 'number',
    tostring(QuestBooth.NearestRoadDistance(215.0, -805.0)))

local passed = 0
for _, r in ipairs(results) do if r.ok then passed = passed + 1 end end
print(('SUMMARY %d/%d'):format(passed, #results))
os.exit(passed == #results and 0 or 1)
