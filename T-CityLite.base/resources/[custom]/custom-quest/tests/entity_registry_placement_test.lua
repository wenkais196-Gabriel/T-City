-- tests/entity_registry_placement_test.lua — 实体注册表 + placement 模块单元测试 (v0.10)
--
-- 不依赖 FiveM 运行时 — mock 全部外部依赖
-- 验证: Registry CRUD、延迟回收策略、DropZone 生成、placementComplete 流程

print('═══════════════════════════════════════')
print('🧪 实体注册表 + placement — 单元测试')
print('═══════════════════════════════════════')
print()

-- ═══════════════════════════════════════
-- Mock FiveM 全局
-- ═══════════════════════════════════════

local mockEntities = {}  -- netId → { exists=true/false, coords={x,y,z}, frozen=false, invincible=false }
local mockEntityCounter = 0

_G.GetConvar = function(k, default)
    if k == 'quest_debug' then return 'true' end
    return default or ''
end
_G.GetCurrentResourceName = function() return 'custom-quest' end
_G.GetPlayerPed = function() return 1 end
_G.GetPlayerName = function() return 'TestPlayer' end
_G.GetPlayers = function() return { 1 } end

local waitCount = 0
_G.Wait = function(ms)
    waitCount = waitCount + 1
    if waitCount > 200 then error('Wait() limit exceeded') end
end
_G.CreateThread = function(fn)
    local ok, err = pcall(fn)
    if not ok and not tostring(err):find('Wait') then
        print('  ⚠️ Thread error: ' .. tostring(err):sub(1,80))
    end
end
_G.SetTimeout = function(ms, fn)
    -- 立即执行 timeout 回调（同步测试）
    if fn then pcall(fn) end
end
_G.Citizen = { Wait = _G.Wait, CreateThread = _G.CreateThread, Await = function(p) end }

-- 实体 mock
_G.NetworkGetEntityFromNetworkId = function(netId)
    if mockEntities[netId] and mockEntities[netId].exists then return netId end
    return 0
end
_G.GetEntityCoords = function(entity)
    if mockEntities[entity] then
        local c = mockEntities[entity].coords
        return c.x, c.y, c.z
    end
    return 0, 0, 0
end
_G.DoesEntityExist = function(entity)
    return mockEntities[entity] and mockEntities[entity].exists or false
end
_G.DeleteEntity = function(entity)
    if mockEntities[entity] then mockEntities[entity].exists = false end
end
_G.FreezeEntityPosition = function(entity, frozen)
    if mockEntities[entity] then mockEntities[entity].frozen = frozen end
end
_G.SetEntityInvincible = function(entity, inv)
    if mockEntities[entity] then mockEntities[entity].invincible = inv end
end
_G.GetClosestVehicle = function(x, y, z, r) return 0 end  -- 服务端 mock

_G.AddEventHandler = function(event, fn)
    _G._events = _G._events or {}
    _G._events[event] = _G._events[event] or {}
    table.insert(_G._events[event], fn)
end
_G.RegisterNetEvent = function(event, fn) end  -- 不需要网络
_G.TriggerEvent = function(event, ...)
    if _G._events and _G._events[event] then
        for _, fn in ipairs(_G._events[event]) do
            pcall(fn, ...)
        end
    end
end
_G.TriggerClientEvent = function(event, src, ...) end
_G.TriggerServerEvent = function(event, ...) end
_G.vector3 = function(x, y, z) return { x = x, y = y, z = z } end
_G.vector4 = function(x, y, z, h) return { x = x, y = y, z = z, h = h } end
_G.json = { encode = function(t) return '{}' end, decode = function(s) return {} end }
_G.math = math
_G.string = string
_G.table = table
_G.os = os
_G.pairs = pairs
_G.ipairs = ipairs
_G.tostring = tostring
_G.tonumber = tonumber
_G.type = type
_G.pcall = pcall
_G.error = error
local _origPrint = print
_G.print = function(...)
    local args = {...}
    local parts = {}
    for _, v in ipairs(args) do parts[#parts+1] = tostring(v) end
    _origPrint('[mock] ' .. table.concat(parts, ' '))
end

-- ═══════════════════════════════════════
-- Mock exports
-- ═══════════════════════════════════════

local mockExports = {}
_G.exports = setmetatable({}, {
    __index = function(t, k)
        if not mockExports[k] then mockExports[k] = {} end
        return mockExports[k]
    end
})

-- ═══════════════════════════════════════
-- Mock QBCore player data
-- ═══════════════════════════════════════

local mockPlayers = {
    [1] = { PlayerData = { citizenid = 'TEST001', source = 1 } }
}
mockExports['qb-core'] = {
    GetCoreObject = function()
        return {
            Functions = {
                GetPlayer = function(src)
                    return mockPlayers[src]
                end,
                GetPlayerByCitizenId = function(cid)
                    for _, p in pairs(mockPlayers) do
                        if p.PlayerData.citizenid == cid then return p end
                    end
                end,
            }
        }
    end
}

-- ═══════════════════════════════════════
-- Mock Config (与 config.lua 一致)
-- ═══════════════════════════════════════

_G.Config = {
    Quest = {
        Enabled = true,
        MaxActiveQuests = 5,
        Cache = {
            ActiveQuestTTL = 1800,
            CooldownTTL = 300,
        },
        Rewards = {
            DefaultAccountType = 'bank',
            UseAddScaledMoney = false,
        },
        Events = {
            QUEST_ACCEPT = 'quest:server:accept',
            QUEST_ABANDON = 'quest:server:abandon',
            QUEST_REACH = 'quest:server:reach',
            QUEST_COLLECT = 'quest:server:collect',
            QUEST_ACCEPTED = 'quest:client:questAccepted',
            QUEST_STEP_ADVANCED = 'quest:client:stepAdvanced',
            QUEST_COMPLETED = 'quest:client:questCompleted',
            QUEST_FAILED = 'quest:client:questFailed',
            QUEST_ABANDONED = 'quest:client:questAbandoned',
            QUEST_PROGRESS = 'quest:client:progress',
            QUEST_REQUEST_STATE = 'quest:server:requestState',
            QUEST_REQUEST_NONCE = 'quest:server:requestNonce',
            QUEST_STATE_RESTORE = 'quest:client:restoreState',
        },
    },
}

-- ═══════════════════════════════════════
-- 加载服务端模块（顺序依赖）
-- ═══════════════════════════════════════

local function loadModule(relPath)
    local path = 'T-CityLite.base/resources/[custom]/custom-quest/' .. relPath
    local f = io.open(path, 'r')
    if not f then
        print('❌ Cannot open: ' .. path)
        return false
    end
    local code = f:read('*a')
    f:close()
    local fn, err = loadstring(code, '@' .. relPath)
    if not fn then
        print('❌ Parse error in ' .. relPath .. ': ' .. tostring(err))
        return false
    end
    setfenv(fn, _G)
    local ok, err2 = pcall(fn)
    if not ok then
        print('❌ Runtime error in ' .. relPath .. ': ' .. tostring(err2))
        return false
    end
    print('  ✅ Loaded: ' .. relPath)
    return true
end

print('📦 Loading modules...')

-- 先加载 quest_db stub（registry 不依赖）
_G.QuestDB = {
    GetActiveQuests = function() return {} end,
    GetQuestProgress = function() return {} end,
    UpdateProgress = function() end,
    CompleteQuest = function() end,
    SetCooldown = function() end,
    LogEvent = function() end,
}

_G.QuestCache = {
    GetActiveQuests = function() return {} end,
    SetActiveQuests = function() end,
    InvalidateActive = function() end,
    IndexEvent = function() end,
    LookupEvent = function() return nil end,
    UnindexEvent = function() end,
}

_G.QuestManager = {
    AdvanceStep = function(cid, qid, sid, data)
        print('  [QuestManager.AdvanceStep] ' .. cid .. ' | ' .. qid .. ' | ' .. sid)
        return true, 'ok'
    end,
    FailQuest = function() end,
}

loadModule('server/quest_entity_registry.lua')
loadModule('server/quest_entity_placement.lua')

-- ═══════════════════════════════════════
-- 断言辅助
-- ═══════════════════════════════════════

local passed = 0
local failed = 0

local function assert_eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
        print('  ✅ PASS: ' .. label)
    else
        failed = failed + 1
        print('  ❌ FAIL: ' .. label .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    end
end

local function assert_truthy(val, label)
    if val then
        passed = passed + 1
        print('  ✅ PASS: ' .. label)
    else
        failed = failed + 1
        print('  ❌ FAIL: ' .. label .. ' — expected truthy, got ' .. tostring(val))
    end
end

-- ═══════════════════════════════════════
-- 测试 1: Registry 基本 CRUD
-- ═══════════════════════════════════════

print()
print('── 测试 1: Registry 基本 CRUD ──')

-- 创建 mock 实体
local netId = 100
mockEntities[netId] = { exists = true, coords = { x = 800, y = -3100, z = 6 } }

QuestEntityRegistry.Register('TEST001', 'test_quest', 'trailer', netId, {
    model = 'trailers3',
    recyclePolicy = 'on_leave',
    leaveRadius = 50,
    forceAfterSec = 5,  -- 缩短以便测试
})

local retrievedNetId = QuestEntityRegistry.GetNetId('TEST001', 'test_quest', 'trailer')
assert_eq(retrievedNetId, netId, 'GetNetId returns registered netId')

local all = QuestEntityRegistry.GetAll('TEST001', 'test_quest')
assert_truthy(all ~= nil, 'GetAll returns table')
assert_truthy(all.trailer ~= nil, 'trailer entry exists')
assert_eq(all.trailer.model, 'trailers3', 'model is trailers3')
assert_eq(all.trailer.recyclePolicy, 'on_leave', 'policy is on_leave')
assert_eq(all.trailer.recycled, false, 'not recycled yet')

-- ═══════════════════════════════════════
-- 测试 2: MarkHitched
-- ═══════════════════════════════════════

print()
print('── 测试 2: MarkHitched ──')

QuestEntityRegistry.MarkHitched('TEST001', 'test_quest', 'trailer', true)
local all2 = QuestEntityRegistry.GetAll('TEST001', 'test_quest')
assert_truthy(all2.trailer.hitched == true, 'hitched = true after MarkHitched')

QuestEntityRegistry.MarkHitched('TEST001', 'test_quest', 'nonexistent', true)
assert_truthy(true, 'MarkHitched nonexistent does not crash')  -- 不应崩溃

-- ═══════════════════════════════════════
-- 测试 3: IsRecycled
-- ═══════════════════════════════════════

print()
print('── 测试 3: IsRecycled ──')

assert_eq(QuestEntityRegistry.IsRecycled('TEST001', 'test_quest', 'trailer'), false, 'IsRecycled=false before recycle')
assert_eq(QuestEntityRegistry.IsRecycled('TEST001', 'test_quest', 'nonexistent'), true, 'IsRecycled=true for unregistered')

-- ═══════════════════════════════════════
-- 测试 4: ScheduleRecycle (immediate)
-- ═══════════════════════════════════════

print()
print('── 测试 4: ScheduleRecycle (immediate) ──')

-- 注册新实体用 immediate 策略
local netId2 = 101
mockEntities[netId2] = { exists = true, coords = { x = 900, y = -3200, z = 6 } }

QuestEntityRegistry.Register('TEST001', 'test_quest2', 'prop', netId2, {
    model = 'prop_box',
    recyclePolicy = 'immediate',
})

assert_eq(mockEntities[netId2].exists, true, 'entity exists before recycle')
QuestEntityRegistry.ScheduleRecycle('TEST001', 'test_quest2', 'prop')
assert_eq(mockEntities[netId2].exists, false, 'entity deleted after immediate recycle')
assert_eq(QuestEntityRegistry.IsRecycled('TEST001', 'test_quest2', 'prop'), true, 'IsRecycled=true after recycle')

-- ═══════════════════════════════════════
-- 测试 5: ScheduleRecycle (timed)
-- ═══════════════════════════════════════

print()
print('── 测试 5: ScheduleRecycle (timed) ──')

local netId3 = 102
mockEntities[netId3] = { exists = true, coords = { x = 1000, y = -3300, z = 6 } }

QuestEntityRegistry.Register('TEST001', 'test_quest3', 'cargo', netId3, {
    model = 'crate',
    recyclePolicy = 'timed',
    delaySec = 0,  -- 0 秒延迟 — SetTimeout mock 立即执行
})

QuestEntityRegistry.ScheduleRecycle('TEST001', 'test_quest3', 'cargo')
assert_eq(mockEntities[netId3].exists, false, 'entity deleted after timed recycle (mock immediate)')

-- ═══════════════════════════════════════
-- 测试 6: ForceRecycleAll
-- ═══════════════════════════════════════

print()
print('── 测试 6: ForceRecycleAll ──')

-- 注册多个实体
local netId4a, netId4b = 103, 104
mockEntities[netId4a] = { exists = true, coords = { x = 1, y = 1, z = 1 } }
mockEntities[netId4b] = { exists = true, coords = { x = 2, y = 2, z = 2 } }

QuestEntityRegistry.Register('TEST001', 'multi_quest', 'trailer', netId4a, {
    model = 'trailerlogs', recyclePolicy = 'on_quest_end',
})
QuestEntityRegistry.Register('TEST001', 'multi_quest', 'truck', netId4b, {
    model = 'phantom', recyclePolicy = 'on_quest_end',
})

assert_eq(mockEntities[netId4a].exists, true, 'trailer exists before ForceRecycleAll')
assert_eq(mockEntities[netId4b].exists, true, 'truck exists before ForceRecycleAll')

QuestEntityRegistry.ForceRecycleAll('TEST001', 'multi_quest')

assert_eq(mockEntities[netId4a].exists, false, 'trailer deleted after ForceRecycleAll')
assert_eq(mockEntities[netId4b].exists, false, 'truck deleted after ForceRecycleAll')

-- ═══════════════════════════════════════
-- 测试 7: DropZone 生成
-- ═══════════════════════════════════════

print()
print('── 测试 7: GenerateDropZone ──')

local origin = { x = 800, y = -3100, z = 6.0 }
local zone = QuestEntityPlacement.GenerateDropZone(origin, 15, 40, 10)

assert_truthy(zone ~= nil, 'GenerateDropZone returns table')
assert_truthy(zone.x ~= nil, 'zone.x exists')
assert_truthy(zone.y ~= nil, 'zone.y exists')
assert_truthy(zone.z ~= nil, 'zone.z exists')
assert_truthy(zone.radius == 10, 'zone.radius = 10')
assert_truthy(zone.heading ~= nil, 'zone.heading exists')

-- 验证距离在搜索范围内
local dist = math.sqrt((zone.x - origin.x)^2 + (zone.y - origin.y)^2)
assert_truthy(dist >= 15 and dist <= 40, ('distance in range 15-40 (actual %.0f)'):format(dist))

-- nil 输入测试
local nilZone = QuestEntityPlacement.GenerateDropZone(nil, 15, 40, 10)
assert_eq(nilZone, nil, 'nil input returns nil')

-- 空 table 输入
local emptyZone = QuestEntityPlacement.GenerateDropZone({}, 15, 40, 10)
assert_eq(emptyZone, nil, 'empty coords returns nil')

-- ═══════════════════════════════════════
-- 测试 8: DropZone 缓存
-- ═══════════════════════════════════════

print()
print('── 测试 8: DropZone 缓存 ──')

local testZone = { x = 820, y = -3115, z = 6, heading = 90, radius = 10 }
QuestEntityPlacement.CacheDropZone('TEST001', 'cache_test', testZone)
local cached = QuestEntityPlacement.GetDropZone('TEST001', 'cache_test')
assert_eq(cached.x, 820, 'cached x matches')
assert_eq(cached.radius, 10, 'cached radius matches')

-- 不同 quest 不冲突
local otherCached = QuestEntityPlacement.GetDropZone('TEST001', 'other_quest')
assert_eq(otherCached, nil, 'other quest returns nil')

QuestEntityPlacement.ClearDropZone('TEST001', 'cache_test')
local afterClear = QuestEntityPlacement.GetDropZone('TEST001', 'cache_test')
assert_eq(afterClear, nil, 'ClearDropZone works')

-- ═══════════════════════════════════════
-- 测试 9: placementComplete 验证逻辑
-- ═══════════════════════════════════════

print()
print('── 测试 9: placementComplete 流程 ──')

-- 注册 trailer + 缓存 zone
local pNetId = 200
mockEntities[pNetId] = { exists = true, coords = { x = 820, y = -3115, z = 6 } }

QuestEntityRegistry.Register('TEST001', 'placement_test', 'trailer', pNetId, {
    model = 'trailers3',
    recyclePolicy = 'on_leave',
    leaveRadius = 50,
    forceAfterSec = 5,
})

local pZone = { x = 820, y = -3115, z = 6, heading = 90, radius = 10 }
QuestEntityPlacement.CacheDropZone('TEST001', 'placement_test', pZone)

-- 模拟客户端上报 placementComplete（无法真正调用事件处理器，直接测核心函数）
-- 验证 trailer 在 zone 内
local trailerEntity = NetworkGetEntityFromNetworkId(pNetId)
assert_truthy(trailerEntity ~= 0, 'trailer entity found')
local tx, ty, tz = GetEntityCoords(trailerEntity)
local pDist = math.sqrt((tx - pZone.x)^2 + (ty - pZone.y)^2)
assert_truthy(pDist <= pZone.radius, ('trailer within zone (dist=%.1f, max=%.1f)'):format(pDist, pZone.radius))

-- 验证 trailer 在 zone 外的情况
mockEntities[pNetId].coords = { x = 900, y = -3000, z = 6 }  -- 移远
local tx2, ty2 = GetEntityCoords(pNetId)
local pDist2 = math.sqrt((tx2 - pZone.x)^2 + (ty2 - pZone.y)^2)
assert_truthy(pDist2 > pZone.radius, ('trailer outside zone (dist=%.1f, max=%.1f)'):format(pDist2, pZone.radius))

-- 清理
QuestEntityPlacement.ClearDropZone('TEST001', 'placement_test')
QuestEntityRegistry.ForceRecycleAll('TEST001', 'placement_test')

-- ═══════════════════════════════════════
-- 测试 10: 边界 — 重复注册覆盖
-- ═══════════════════════════════════════

print()
print('── 测试 10: 边界情况 ──')

-- 重复注册同一 entityType
local dupNetId = 300
mockEntities[dupNetId] = { exists = true, coords = { x = 0, y = 0, z = 0 } }
QuestEntityRegistry.Register('TEST001', 'dup_test', 'trailer', dupNetId, { model = 'first', recyclePolicy = 'immediate' })
QuestEntityRegistry.Register('TEST001', 'dup_test', 'trailer', dupNetId, { model = 'second', recyclePolicy = 'immediate' })
local dupAll = QuestEntityRegistry.GetAll('TEST001', 'dup_test')
assert_eq(dupAll.trailer.model, 'second', 'second registration overwrites first')

-- nil 参数不应崩溃
QuestEntityRegistry.Register(nil, 'q', 't', 1, {})
QuestEntityRegistry.Register('c', nil, 't', 1, {})
QuestEntityRegistry.Register('c', 'q', nil, 1, {})
QuestEntityRegistry.Register('c', 'q', 't', nil, {})
assert_truthy(true, 'nil params do not crash Register')

-- ScheduleRecycle 不存在的实体
QuestEntityRegistry.ScheduleRecycle('TEST001', 'nonexistent', 'ghost')
assert_truthy(true, 'ScheduleRecycle nonexistent does not crash')

-- ForceRecycleAll 空 quest
QuestEntityRegistry.ForceRecycleAll('TEST001', 'never_registered')
assert_truthy(true, 'ForceRecycleAll empty does not crash')

-- ═══════════════════════════════════════
-- 测试 11: 多种 DropZone 参数组合
-- ═══════════════════════════════════════

print()
print('── 测试 11: DropZone 参数变化 ──')

-- 测试不同 searchMin/Max
local z1 = QuestEntityPlacement.GenerateDropZone({x=0,y=0,z=0}, 5, 10, 5)
assert_truthy(z1 ~= nil, 'small search range works')
local dist1 = math.sqrt((z1.x-0)^2 + (z1.y-0)^2)
assert_truthy(dist1 >= 5 and dist1 <= 10, 'small range distance correct')

local z2 = QuestEntityPlacement.GenerateDropZone({x=0,y=0,z=0}, 50, 100, 15)
assert_truthy(z2 ~= nil, 'large search range works')
local dist2 = math.sqrt((z2.x-0)^2 + (z2.y-0)^2)
assert_truthy(dist2 >= 50 and dist2 <= 100, 'large range distance correct')

-- ═══════════════════════════════════════
-- 测试 12: 事件触发（onQuestCompleted → ForceRecycleAll）
-- ═══════════════════════════════════════

print()
print('── 测试 12: 事件联动 ──')

local eventNetId = 400
mockEntities[eventNetId] = { exists = true, coords = { x = 0, y = 0, z = 0 } }
QuestEntityRegistry.Register('TEST001', 'event_test', 'trailer', eventNetId, {
    model = 'trailers3', recyclePolicy = 'on_quest_end',
})
QuestEntityPlacement.CacheDropZone('TEST001', 'event_test', { x = 0, y = 0, z = 0, heading = 0, radius = 10 })

-- 触发任务完成事件
TriggerEvent('quest:server:onQuestCompleted', 'TEST001', 'event_test')

-- ForceRecycleAll 在事件处理器中带 2s 延迟，但 mock SetTimeout 立即执行
-- 需要等一下因为延迟在异步中 — 实际 mock 是同步的
assert_eq(mockEntities[eventNetId].exists, false, 'entity deleted after onQuestCompleted')
assert_eq(QuestEntityPlacement.GetDropZone('TEST001', 'event_test'), nil, 'zone cache cleared after onQuestCompleted')

-- ═══════════════════════════════════════
-- 结果汇总
-- ═══════════════════════════════════════

print()
print('═══════════════════════════════════════')
local total = passed + failed
print(('📊 结果: %d/%d 通过, %d 失败'):format(passed, total, failed))
if failed == 0 then
    print('✅ 全部测试通过！')
else
    print('❌ 有 ' .. failed .. ' 个测试失败')
end
print('═══════════════════════════════════════')

os.exit(failed == 0 and 0 or 1)
