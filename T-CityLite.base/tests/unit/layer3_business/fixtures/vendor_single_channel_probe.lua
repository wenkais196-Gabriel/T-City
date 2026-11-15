-- vendor_single_channel_probe.lua — 收摊「同一动作只推进一次」的离线运行时证明。
--
-- 三个真实源码，全部现场加载（不复制逻辑）：
--   1. config/quests/quest_hotdog.lua        → 拿真实的 step_sell（type='vendor'）
--   2. client/main.lua 的 [node-interact] 块 → 用真实 ExecuteNode 形状的 payload 调一次
--   3. server/quest_vendor_bridge.lua        → 桩好依赖后调真实的 vendorAction('close')
--
-- 断言：
--   * vendor 步骤的 payload 没有 coords → 通用交互不建线程、不发 nodeComplete；
--   * 同样的 handler 收到带 coords 的 interact 步骤仍会建线程（正向对照，防止规则把
--     “通用交互彻底坏了”误当成“修好了”）；
--   * 一次 close 动作只调用一次 QuestManager.AdvanceStep，且 stepId 是 step_sell。
--
-- 用法:
--   lua5.4 vendor_single_channel_probe.lua <client/main.lua> <server/quest_vendor_bridge.lua> <config/quests/quest_hotdog.lua>

local MAIN = assert(arg[1], '缺少 client/main.lua')
local BRIDGE = assert(arg[2], '缺少 server/quest_vendor_bridge.lua')
local TEMPLATE = assert(arg[3], '缺少 config/quests/quest_hotdog.lua')

-- 反向校验：把事故形状（vendor 步骤带 coords/radius/duration）塞回模板，
-- 探针必须红。pytest 用 `--mutate` 跑这一遍。
local mutate = arg[4] == '--mutate'

local function read(path)
    local file = assert(io.open(path, 'r'))
    local text = file:read('a')
    file:close()
    return text
end

local function extract_block(path, marker)
    local text = '\n' .. read(path)
    local body = text:match(
        '\r?\n%-%- %[' .. marker .. '%] begin\r?\n(.-)\r?\n%-%- %[' .. marker .. '%] end')
    if not body then error('找不到标记块: ' .. marker) end
    return body
end

local checks, passed = 0, 0
local function check(name, ok, detail)
    checks = checks + 1
    if ok then
        passed = passed + 1
    else
        print(('FAIL %s: %s'):format(name, tostring(detail or '')))
    end
end

-- ---------------------------------------------------------------------------
-- 1. 真实模板：quest_hotdog_dev 默认不加载，桩成 1
-- ---------------------------------------------------------------------------
GetConvar = function(name, default)
    if name == 'quest_hotdog_dev' then return '1' end
    return default
end

local templates = assert(loadfile(TEMPLATE))()
local template
for _, candidate in ipairs(templates) do
    if candidate.id == 'hotdog_dev_rental' then template = candidate end
end
assert(template, '模板里没有 hotdog_dev_rental')

local vendorStep
for _, step in ipairs(template.steps or {}) do
    if step.type == 'vendor' then vendorStep = step end
end
assert(vendorStep and vendorStep.id == 'step_sell', '找不到 step_sell')

if mutate then
    vendorStep.data = {
        coords = { x = 215.8, y = -810.3, z = 30.7 },
        radius = 3.0,
        duration = 800,
    }
end

-- ---------------------------------------------------------------------------
-- 2. 真实 client/main.lua 的 nodeInteract 处理器
-- ---------------------------------------------------------------------------
local nodeInteract
local threadsStarted = 0
local sentEvents = {}

local clientEnv = {
    RegisterNetEvent = function(name, fn)
        if name == 'quest:client:nodeInteract' then nodeInteract = fn end
    end,
    ClearZone = function() end,
    SetNewBlip = function() end,
    vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
    Citizen = {
        CreateThread = function(fn)
            threadsStarted = threadsStarted + 1
            assert(type(fn) == 'function', 'CreateThread 收到的不是函数')
        end,
    },
    TriggerServerEvent = function(name, ...)
        sentEvents[#sentEvents + 1] = { name = name, args = { ... } }
    end,
    PlayerPedId = function() return 1 end,
    GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
    activeNode = nil,
}

local chunk = assert(load(extract_block(MAIN, 'node%-interact'),
    '@node-interact-block', 't', clientEnv))
chunk()
assert(type(nodeInteract) == 'function', '没注册 quest:client:nodeInteract')

-- 模拟 QuestNodes.ExecuteNode：payload = { questId, stepId } + (step.data or step.payload or {})
local payload = { questId = template.id, stepId = vendorStep.id }
for key, value in pairs(vendorStep.data or vendorStep.payload or {}) do
    payload[key] = value
end
nodeInteract(payload)

check('vendor_has_no_coords', payload.coords == nil and payload.targetCoords == nil,
    tostring(payload.coords) .. '/' .. tostring(payload.targetCoords))
check('vendor_does_not_start_interact_thread', threadsStarted == 0,
    '通用交互线程被启动了 ' .. tostring(threadsStarted) .. ' 次')
check('vendor_does_not_report_node_complete', #sentEvents == 0,
    '发出了 ' .. tostring(#sentEvents) .. ' 条服务端事件')

-- 正向对照：带坐标的普通 interact 步骤仍然会启动交互线程。
nodeInteract({
    questId = 'probe_quest',
    stepId = 'step_interact',
    coords = { x = 1.0, y = 2.0, z = 3.0 },
    radius = 2.0,
    duration = 100,
})
check('interact_with_coords_still_works', threadsStarted == 1,
    '带坐标的 interact 步骤没有启动线程：' .. tostring(threadsStarted))

-- ---------------------------------------------------------------------------
-- 3. 真实 quest_vendor_bridge.lua：一次 close 只能推进一次
-- ---------------------------------------------------------------------------
local booth = {
    netId = 777, x = 1.0, y = 2.0, z = 30.0,
    questId = template.id, ownerCitizenid = 'cid-test',
}
local player = {
    PlayerData = { citizenid = 'cid-test', source = 1, money = { cash = 100 } },
    Functions = { RemoveMoney = function() return true end, AddMoney = function() return true end },
}
local advances = {}
local bridgeHandlers = {}

exports = {
    ['qb-core'] = {
        GetPlayer = function(_, src)
            if tonumber(src) == 1 then return player end
            return nil
        end,
    },
}
GetPlayers = function() return { '1' } end
GetGameTimer = function() return 1000 end
GetPlayerPed = function() return 1 end
GetEntityCoords = function() return { x = 1.0, y = 2.0, z = 30.0 } end
CreateThread = function() end
Wait = function() end
AddEventHandler = function() end
RegisterNetEvent = function(name, fn) bridgeHandlers[name] = fn end
TriggerClientEvent = function() end
QuestMoney = function(value) return tostring(value) end
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
Broadcast = { Scope = function() return 0 end }
QuestBooth = { Get = function(cid) if cid == 'cid-test' then return booth end return nil end }
QuestVendor = {
    Get = function() return nil end,
    Close = function(_, questId) return { questId = questId, sold = 2, revenue = 12 } end,
    Open = function() return nil, 'unused' end,
    Tick = function() return {} end,
    AddStock = function() return true end,
}
QuestRegistry = {
    GetTemplate = function(questId)
        if questId == template.id then return template end
        return nil
    end,
}
QuestManager = {
    AdvanceStep = function(citizenid, questId, stepId)
        advances[#advances + 1] = {
            citizenid = citizenid, questId = questId, stepId = stepId,
        }
        return true
    end,
}
QuestMinigame = {}
source = 1

-- 桥文件加载时会 print 一行 ready；探针输出只留 KEY|VALUE，先静音。
local realPrint = print
print = function() end
QuestVendorBridge = nil
assert(loadfile(BRIDGE))()
print = realPrint

local closeHandler = bridgeHandlers['quest:server:vendorAction']
assert(type(closeHandler) == 'function', 'bridge 没注册 vendorAction')
closeHandler('close', {})

check('close_advances_exactly_once', #advances == 1,
    '推进了 ' .. tostring(#advances) .. ' 次')
check('close_advances_the_vendor_step',
    advances[1] and advances[1].stepId == 'step_sell',
    advances[1] and tostring(advances[1].stepId))

print(('SUMMARY %d/%d'):format(passed, checks))
if passed ~= checks then
    os.exit(1)
end
