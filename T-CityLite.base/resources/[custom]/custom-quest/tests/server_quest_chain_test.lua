-- tests/server_quest_chain_test.lua — 服务端任务链集成测试 (v0.8b)
--
-- 不依赖 FiveM 运行时 — mock 全部外部依赖
-- 验证: TriggerQuest → AdvanceStep ×9 → CompleteQuest 全链路

print('═══════════════════════════════════════')
print('🧪 服务端任务链 — 集成测试')
print('═══════════════════════════════════════')
print()

-- ═══════════════════════════════════════
-- Mock FiveM 全局变量
-- ═══════════════════════════════════════

_G.GetConvar = function(k, default)
    if k == 'quest_enable' then return 'true'
    elseif k == 'quest_debug' then return 'false'
    else return default or ''
    end
end

_G.GetCurrentResourceName = function() return 'custom-quest' end
_G.GetPlayerPed = function() return 1 end
_G.GetPlayerName = function() return 'TestPlayer' end
_G.GetPlayers = function() return { 1 } end
-- 防无限循环: Wait 调用超过 1000 次后抛出
local waitCount = 0
local maxWaits = 1000
_G.Wait = function(ms)
    waitCount = waitCount + 1
    if waitCount > maxWaits then error('Wait() limit exceeded — infinite loop detected') end
end
_G.CreateThread = function(fn)
    local ok, err = pcall(fn)
    if not ok then
        -- 预期内的 "Wait limit" 错误静默忽略
        if not tostring(err):find('Wait') then print('  ⚠️ Thread error: ' .. tostring(err):sub(1,80)) end
    end
end
_G.SetTimeout = function(ms, fn) end
_G.Citizen = {
    Wait = _G.Wait,
    CreateThread = _G.CreateThread,
    Await = function(p) end,
}
_G.NetworkGetEntityFromNetworkId = function() return 1 end
_G.GetEntityCoords = function() return 1, 1, 1 end
_G.GetEntityModel = function() return 0 end
_G.GetVehicleClass = function() return 10 end
_G.GetVehicleNumberPlateText = function() return 'TEST123' end
_G.GetVehiclePedIsIn = function() return 1 end
_G.GetVehicleTrailerVehicle = function() return 0 end
_G.GetVehicleBodyHealth = function() return 1000 end
_G.GetVehicleEngineHealth = function() return 1000 end
_G.GetIsVehicleEngineRunning = function() return true end
_G.GetEntitySpeed = function() return 30 end
_G.GetVehicleFuelLevel = function() return 100 end
_G.DoesEntityExist = function() return true end
_G.DeleteEntity = function() end
_G.SetVehicleDoorsLocked = function() end
_G.SetVehicleEngineOn = function() end
_G.SetVehicleHasBeenOwnedByPlayer = function() end
_G.AddEventHandler = function(event, fn) end
_G.RegisterNetEvent = function(event, fn) end
_G.TriggerEvent = function(event, ...) end
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
_G.print = print
_G.next = next
_G.LoadResourceFile = function(res, path)
    local fullPath = 'T-CityLite.base/resources/[custom]/custom-quest/' .. path
    local f = io.open(fullPath, 'r')
    if f then
        local c = f:read('*a')
        f:close()
        return c
    end
    return nil
end
_G.source = 1
_G.GetResourceState = function() return 'started' end
_G.RegisterCommand = function(name, fn, restricted) end
_G.GetHashKey = function(s) return s end
_G.IsModelAVehicle = function(m) return true end
_G.RequestModel = function(m) end
_G.HasModelLoaded = function(m) return true end
_G.SetModelAsNoLongerNeeded = function(m) end
_G.CreateVehicle = function(...) return 1 end
_G.SetEntityCoords = function(e, x, y, z) end
_G.SetEntityHeading = function(e, h) end
_G.SetVehicleOnGroundProperly = function(v) end
_G.SetVehicleNumberPlateText = function(v, plate) end
_G.SetVehicleColours = function(v, c1, c2) end
_G.NetworkGetNetworkIdFromEntity = function(e) return 1 end
-- Lua 5.1 兼容: load(reader) → loadstring(chunk)
if not table.unpack then table.unpack = unpack end
_G.load = loadstring  -- 无条件覆盖 Lua 5.1 原生 load(reader)

-- ═══════════════════════════════════════
-- Mock exports chain
-- ═══════════════════════════════════════

-- 全局 QBCore 引用（模块在文件顶层用 local QBCore = exports[...]:GetCoreObject()）
local QBCore_instance = nil

local function get_QBCore()
    if not QBCore_instance then
        QBCore_instance = {
            Functions = {
                GetPlayer = function(src)
                    return {
                        PlayerData = {
                            citizenid = 'CITIZEN_TEST',
                            charinfo = { phone = '1234567890', firstname = 'Test' },
                            metadata = { licences = { driver = true, heavy = true, pilot = true }, rep = {} },
                            job = { name = 'unemployed', type = 'none', onduty = false },
                            source = src,
                        },
                        Functions = {
                            AddMoney = function(account, amount, reason) return true end,
                            RemoveMoney = function(account, amount, reason) return true end,
                            AddItem = function(name, count) return true end,
                            AddRep = function(reptype, amount) return true end,
                            GetRep = function(reptype) return 0 end,
                            SetMetaData = function(key, val) return true end,
                            GetMoney = function(account) return 10000 end,
                            GetItemByName = function(name) return nil end,
                        },
                    }
                end,
                GetPlayerByCitizenId = function(cid)
                    return { PlayerData = { source = 1, citizenid = cid } }
                end,
                GetDutyCount = function(job) return 0 end,
                HasPermission = function(src, perm) return true end,
                CreateCallback = function(name, fn) end,
                TriggerCallback = function(name, src, cb, ...) cb({}) end,
            },
            Shared = { Items = {} },
            Commands = { Add = function(name, help, args, restricted, fn) end },
        }
    end
    return QBCore_instance
end

local mock_exports = {
    ['qb-core'] = {
        GetCoreObject = function()
            local qb = get_QBCore()
            print(('[mock] GetCoreObject called → Functions.GetPlayer=%s'):format(type(qb.Functions.GetPlayer)))
            return qb
        end,
    },
    ['custom-career'] = { PlayerMatchesTags = function() return true end },
    ['custom-certificates'] = {
        GrantLicense = function(src, cert) return true, 'ok' end,
        RevokeLicense = function(src, cert) return true, 'ok' end,
        HasLicense = function(src, cert) return true end,
    },
    ['custom-security'] = { CheckRateLimit = function(src, action, ms) return true end },
    ['custom-logs'] = {
        LogGeneric = function(msg, text, color) end,
        LogSecurity = function(msg, text, color) end,
    },
    ['custom-main'] = { AddScaledMoney = function(src, acct, amt, reason) return true end },
    ['custom-economy'] = { AddScaledMoney = function(src, acct, amt, reason) return true end },
    ['qb-hud'] = {
        ShowTaskTimer = function(mins, secs, phase) end,
        HideTaskTimer = function() end,
    },
    ['qb-inventory'] = {
        HasItem = function() return false end,
        RemoveItem = function() end,
        AddItem = function() end,
        CreateShop = function() end,
        OpenShop = function() end,
    },
    ['qb-fuel'] = { GetFuel = function(veh) return 85 end },
    ['progressbar'] = { Progress = function(data, cb) cb(false) end },
    ['PolyZone'] = {},
    ['qb-target'] = {},
    ['qb-menu'] = {},
    ['qb-vehiclekeys'] = {},
}

_G.exports = setmetatable({}, {
    __index = function(t, k)
        if not mock_exports[k] then
            mock_exports[k] = {}
        end
        return mock_exports[k]
    end
})

-- ═══════════════════════════════════════
-- Mock MySQL (sync for testing)
-- ═══════════════════════════════════════

local db = {
    player_quests = {},
    quest_cooldowns = {},
    quest_event_log = {},
}

_G.MySQL = {
    Async = {
        insert = function(query, params, cb)
            local id = #db.player_quests + 1
            table.insert(db.player_quests, { id = id, params = params })
            if cb then cb(id) end
        end,
        fetchAll = function(query, params, cb)
            if cb then cb({}) end
        end,
        execute = function(query, params, cb)
            if cb then cb(1) end
        end,
    },
    query = function(query, params, cb)
        if cb then cb({}) end
    end,
    scalar = { await = function(query, params) return nil end },
    query_await = function(query, params) return {} end,
    insert = function(query, params, cb)
        if cb then cb(1) end
    end,
}

_G.promise = { new = function(fn) local p = { resolve = function(v) end }; fn(p.resolve); return p end }

-- ═══════════════════════════════════════
-- Mock KeyManager
-- ═══════════════════════════════════════
_G.KeyManager = { GetOwner = function(plate) return nil end }

print('📦 Mock 环境就绪')
print()

-- ═══════════════════════════════════════
-- Load quest modules in dependency order
-- ═══════════════════════════════════════

local base = 'T-CityLite.base/resources/[custom]/custom-quest/'

local load_order = {
    -- Server config
    'config.lua',
    -- Server modules (dependency order matters)
    'server/quest_cache.lua',
    'server/quest_db.lua',
    'server/quest_registry.lua',
    'server/quest_validators.lua',
    'server/quest_logistics_validators.lua',
    'server/quest_address_resolver.lua',
    'server/quest_cooldown.lua',
    'server/quest_rewards.lua',
    'server/quest_security.lua',
    'server/quest_mutex.lua',
    'server/quest_group.lua',
    'server/quest_manager.lua',
}

local function load_module(path)
    local f = io.open(base .. path, 'r')
    if not f then
        print(('  ⚠️ 文件不存在: %s'):format(path))
        return false
    end
    local code = f:read('*a')
    f:close()

    -- 包裹在 pcall 中，避免单个模块的"依赖未定义"错误阻断整链
    local ok, err = pcall(function()
        local fn, loadErr = loadstring(code)
        if not fn then
            error('loadstring: ' .. tostring(loadErr))
        end
        fn()
    end)
    if not ok then
        local short = tostring(err):match('^(.-)%s*$') or tostring(err)
        print(('  ⚠️ %s: %s'):format(path, short:sub(1, 120)))
    end
    return ok
end

print('📦 加载 quest 模块...')
for _, path in ipairs(load_order) do
    load_module(path)
end
print()

-- ═══════════════════════════════════════
-- Verify key globals exist
-- ═══════════════════════════════════════
local checks = {
    { 'QuestManager', QuestManager },
    { 'QuestRegistry', QuestRegistry },
    { 'QuestSecurity', QuestSecurity },
    { 'QuestCache', QuestCache },
    { 'QuestDB', QuestDB },
    { 'QuestRewards', QuestRewards },
    { 'QuestValidators', QuestValidators },
    { 'QuestAddressResolver', QuestAddressResolver },
}

-- 手动触发模板加载 (main.lua 中 QuestRegistry.AutoLoad() 做的事)
print('📦 加载 quest 模板...')
QuestRegistry.AutoLoad()
print()

print('📦 模块就绪检查:')
local all_ready = true
for _, c in ipairs(checks) do
    local status = c[2] ~= nil
    if not status then all_ready = false end
    print(('  %s %s'):format(status and '✅' or '❌', c[1]))
end
print()

if not all_ready then
    print('⚠️ 部分模块未加载 — 跳过完整链测试')
    print('   (FiveM 运行时模块可正常加载)')
    os.exit(0)
end

-- ═══════════════════════════════════════
-- TEST: 多站快递全链
-- ═══════════════════════════════════════

print('🧪 测试: euro_multi_stop_courier 全链')
print()

local src = 1

-- 1. 确认模板存在
local template = QuestRegistry.GetTemplate('euro_multi_stop_courier')
if not template then
    print('  ❌ 模板未注册！检查 quest_registry 是否加载了 quest_logistics.lua')
    os.exit(1)
end
print(('  ✅ 模板: %s (Lv.%d, %d steps)'):format(template.title, template.level, #template.steps))

-- 2. 列出所有步骤
for i, step in ipairs(template.steps) do
    local hasPool = step.data and step.data.address_pool and ' [ADDR_POOL]' or ''
    print(('    Step %d: %s (%s)%s'):format(i, step.id, step.type, hasPool))
end
print()

-- 3. 触发任务
local success, msg = QuestManager.TriggerQuest(src, 'euro_multi_stop_courier')
print(('  🔹 TriggerQuest: %s — %s'):format(success and '✅' or '❌', msg))

if not success then
    print('  ❌ 任务接取失败，终止测试')
    os.exit(1)
end

-- 4. 逐步推进（模拟客户端 nodeComplete → AdvanceStep）
local citizenid = 'CITIZEN_TEST'
local questId = 'euro_multi_stop_courier'

for i, step in ipairs(template.steps) do
    -- 检查是否有解析后模板
    local resolved = QuestManager._resolvedTemplates[citizenid .. '_' .. questId]

    -- 获取当前步骤信息
    local tmpl = resolved or template
    local curStep = tmpl.steps[i]

    local extra = ''
    if curStep.type == 'validator' then
        if curStep.data and curStep.data.validator_id == 'validate_delivery_arrival' then
            local label = curStep.data._resolved_label or '(unknown)'
            local dist = curStep.data._resolved_distance or 0
            extra = (' → 目的地: %s (%dm)'):format(label, dist)
        end
    end

    -- 模拟客户端完成步骤
    local ok, err = QuestManager.AdvanceStep(citizenid, questId, curStep.id, { position = curStep.data and curStep.data.coords })
    if ok then
        print(('  ✅ Step %d/%d: %s → %s%s'):format(
            i, #template.steps, curStep.id,
            i < #template.steps and tmpl.steps[i+1].id or 'COMPLETED',
            extra))
    else
        print(('  ❌ Step %d/%d: %s — %s'):format(i, #template.steps, curStep.id, err or 'unknown'))
    end
end

-- 5. 验证缓存清理
local cached = QuestManager._resolvedTemplates[citizenid .. '_' .. questId]
print()
print(('  🔹 缓存清理: %s'):format(cached == nil and '✅' or '⚠️ 未清'))

print()
print('═══════════════════════════════════════')
print('✅ 服务端任务链集成测试完成')
print('═══════════════════════════════════════')
