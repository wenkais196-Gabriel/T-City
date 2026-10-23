-- tests/vehiclekeys/test_vehiclekeys_claim.lua
--
-- 回归测试: qb-vehiclekeys:server:AcquireVehicleKeys 远程认领漏洞
--
-- 背景: FiveM 中任何已连接客户端都能以任意参数触发任意已注册的服务端网络事件。
-- 旧实现只校验"会话内是否已有车主"，因此任何人只要发一个车牌字符串，
-- 就能远程认领任意未登记载具（包括尚未上线的他人车辆），并获得车主钥匙。
--
-- 本测试用纯 Lua 5.4 模拟 FiveM 环境，直接加载真实的:
--   server/key_manager.lua
--   server/compat.lua
-- 然后以攻击者身份触发事件，验证所有权不会被授予。
--
-- 运行:
--   lua5.4 T-CityLite.base/tests/vehiclekeys/test_vehiclekeys_claim.lua [resource_dir]

local resourceDir = arg[1] or 'T-CityLite.base/resources/[custom]/custom-vehicles'

local TAG = '[VEHICLEKEYS-CLAIM-TEST]'
local passed, failed = 0, 0

local function ok(name)
    passed = passed + 1
    io.write(('  PASS  %s\n'):format(name))
end

local function no(name, reason)
    failed = failed + 1
    io.write(('  FAIL  %s — %s\n'):format(name, tostring(reason)))
end

-- ==============================================================
-- FiveM 环境桩
-- ==============================================================

local function vector3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, {
        __sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
    })
end

_G.vector3 = vector3

local now = 0
function GetGameTimer()
    return now
end

local entityCoords = {}   -- entity id -> vector3
local entityPlate = {}    -- vehicle id -> plate
local vehicleIds = {}
local nextVehicleId = 100

local function spawnVehicle(plate, x, y, z)
    local id = nextVehicleId
    nextVehicleId = nextVehicleId + 1
    entityCoords[id] = vector3(x, y, z)
    entityPlate[id] = plate
    vehicleIds[#vehicleIds + 1] = id
    return id
end

local players = {}        -- src -> PlayerData 表
local dbOwners = {}       -- plate -> citizenid（player_vehicles 表）
local handlers = {}       -- 事件名 -> 处理函数
local registeredExports = {}
local lastPush = nil

local logStub = {
    LogSecurity = function() end,
}

local core = {
    Functions = {
        GetPlayer = function(src) return players[src] end,
    },
}

local exportsObj = setmetatable({
    ['qb-core'] = { GetCoreObject = function() return core end },
    ['custom-logs'] = logStub,
}, {
    __call = function(_, name, fn)
        registeredExports[name] = fn
        return true
    end,
})

_G.exports = exportsObj

Config = {
    Vehicles = {
        CompatEnabled = true,
        Security = {
            ClaimMaxDistance = 10.0,
            MaxInteractionDistance = 5.0,
        },
        KeyTypes = {
            OWNER = 'owner',
            SHARED = 'shared',
            TEMP = 'temp',
            HOTWIRED = 'hotwired',
        },
        Events = {
            KEYS_UPDATED = 'custom-vehicles:client:keysUpdated',
        },
    },
}

MySQL = {
    scalar = {
        await = function(_, params)
            return dbOwners[params[1]]
        end,
    },
    query = function() end,
}

function RegisterNetEvent(name, fn) handlers[name] = fn end
function AddEventHandler(name, fn) handlers[name] = fn end

function GetPlayerName(src) return ('player%d'):format(src) end
function GetPlayerPed(src) return src * 1000 + 1 end
function GetEntityCoords(entity) return entityCoords[entity] or vector3(0, 0, 0) end
function DoesEntityExist(entity) return entityCoords[entity] ~= nil end
function GetVehicleNumberPlateText(entity) return entityPlate[entity] end
function GetAllVehicles() return vehicleIds end

function TriggerClientEvent(name, target, payload)
    lastPush = { name = name, target = target, payload = payload }
end

-- 抑制资源加载时的 print 噪声
local realPrint = print
print = function() end

-- ==============================================================
-- 加载真实实现
-- ==============================================================

dofile(resourceDir .. '/server/key_manager.lua')
dofile(resourceDir .. '/server/compat.lua')

print = realPrint

local claimEvent = handlers['qb-vehiclekeys:server:AcquireVehicleKeys']
if not claimEvent then
    io.write(TAG .. ' FAIL: AcquireVehicleKeys handler was not registered\n')
    os.exit(1)
end

-- ==============================================================
-- 测试辅助
-- ==============================================================

local function reset()
    KeyManager._keys = {}
    entityCoords = {}
    entityPlate = {}
    vehicleIds = {}
    dbOwners = {}
    lastPush = nil
    now = now + 5000   -- 绕过 1s 认领冷却
end

local function makePlayer(src, cid, x, y, z)
    players[src] = { PlayerData = { citizenid = cid, source = src } }
    entityCoords[src * 1000 + 1] = vector3(x or 0, y or 0, z or 0)
end

local function claim(src, plate)
    _G.source = src
    local okCall, err = pcall(claimEvent, plate)
    _G.source = nil
    return okCall, err
end

local function hasKeys(plate, cid)
    return (KeyManager.HasKeys(plate, cid))
end

-- ==============================================================
-- 场景 1: 远程认领他人已登记车辆 — 必须拒绝
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 0, 0, 0)
makePlayer(2, 'CID_VIC', 900, 900, 0)
dbOwners['VIC123'] = 'CID_VIC'
spawnVehicle('VIC123', 900, 900, 0)

claim(1, 'VIC123')
if hasKeys('VIC123', 'CID_ATK') or KeyManager.GetOwner('VIC123') ~= nil then
    no('远程认领他人登记车辆被拒绝', 'attacker obtained owner keys')
else
    ok('远程认领他人登记车辆被拒绝')
end

-- ==============================================================
-- 场景 2: 认领不存在的车牌 — 必须拒绝
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 0, 0, 0)

claim(1, 'GHOST1')
if hasKeys('GHOST1', 'CID_ATK') then
    no('伪造车牌无法认领', 'ghost plate claimed')
else
    ok('伪造车牌无法认领')
end

-- ==============================================================
-- 场景 3: 车主远程声明自己的车辆 — 必须放行（保留合法流程）
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 0, 0, 0)
dbOwners['MINE01'] = 'CID_ATK'

claim(1, 'MINE01')
if KeyManager.GetOwner('MINE01') == 'CID_ATK' and hasKeys('MINE01', 'CID_ATK') then
    ok('车主远程声明自有车辆仍可用')
else
    no('车主远程声明自有车辆仍可用', 'owner keys not granted')
end

-- ==============================================================
-- 场景 4: 站在无主载具旁认领 — 必须放行（警车/任务车/NPC 车）
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 100, 100, 0)
spawnVehicle('POL001', 103, 100, 0)   -- 3m

claim(1, 'POL001')
if KeyManager.GetOwner('POL001') == 'CID_ATK' then
    ok('载具旁可认领无主载具')
else
    no('载具旁可认领无主载具', 'proximity claim rejected')
end

-- ==============================================================
-- 场景 5: 站在他人车辆旁认领 — 必须拒绝（登记车主优先于距离）
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 100, 100, 0)
dbOwners['VIC123'] = 'CID_VIC'
spawnVehicle('VIC123', 101, 100, 0)   -- 1m

claim(1, 'VIC123')
if KeyManager.GetOwner('VIC123') == 'CID_ATK' then
    no('载具旁认领他人车辆被拒绝', 'attacker obtained owner keys')
else
    ok('载具旁认领他人车辆被拒绝')
end

-- ==============================================================
-- 场景 6: 非法参数类型 — 不得报错，不得授予
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 0, 0, 0)

local badInputs = {
    { {}, 'table' },
    { 123, 'number' },
    { string.rep('A', 99), '超长字符串' },
    { 'AB;DROP TABLE players', '含 SQL 元字符' },
    { '', '空字符串' },
}

for _, case in ipairs(badInputs) do
    local okCall, err = claim(1, case[1])
    if not okCall then
        no('非法参数不报错 (' .. case[2] .. ')', err)
    end
end
if next(KeyManager._keys) ~= nil then
    no('非法参数不授予钥匙', 'key store is not empty')
else
    ok('非法参数不报错且不授予钥匙')
end

-- ==============================================================
-- 场景 7: 认领频率限制
-- ==============================================================

reset()
makePlayer(1, 'CID_ATK', 100, 100, 0)
spawnVehicle('RATE01', 101, 100, 0)
spawnVehicle('RATE02', 101, 100, 0)

claim(1, 'RATE01')                -- 消耗冷却
claim(1, 'RATE02')                -- 立即第二次必须被限流
if KeyManager.GetOwner('RATE02') ~= nil then
    no('认领频率限制', 'second claim within cooldown was accepted')
else
    ok('认领频率限制')
end

-- ==============================================================
-- 场景 8: KeyManager 自身拒绝非法类型（防御纵深）
-- ==============================================================

if KeyManager.GiveKeys({}, 'CID_X') == false
    and KeyManager.HasKeys(nil, 'CID_X') == false
    and KeyManager.GetOwner({}) == nil then
    ok('KeyManager 拒绝非法车牌类型')
else
    no('KeyManager 拒绝非法车牌类型', 'invalid type accepted')
end

-- ==============================================================
-- 汇总
-- ==============================================================

io.write(('%s RESULT passed=%d failed=%d\n'):format(TAG, passed, failed))
if failed > 0 then
    os.exit(1)
end
