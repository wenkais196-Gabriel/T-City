-- tests/unit/layer3_business/fixtures/cityhall_probe.lua
-- 真加载 qb-cityhall 的 config.lua + server/main.lua。
-- 覆盖：证件申领的索引校验、新手三件套不可重复领取、驾校邮件条数上限、申请工作的距离用服务端坐标。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local clock = 1000000
os = setmetatable({ time = function() return clock end, date = os.date }, { __index = os })

local state = {
    added = {},
    removed = 0,
    mails = {},
    jobs = {},
    money = {},
    players = {},
    notifications = {},
    coords = nil,
}

local function makePlayer(source, citizenid)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = citizenid or ('CID' .. source),
        license = 'LIC' .. source,
        job = { name = 'unemployed', onduty = false, grade = { level = 0 } },
        metadata = { licences = {}, cert_status = {} },
        money = { cash = 5000, bank = 5000 },
        items = {},
        charinfo = { firstname = 'Test', lastname = 'Player', birthdate = '1990-01-01', gender = 0, nationality = 'FR', phone = '555-0100' },
    }
    player.Functions = {
        SetMetaData = function(key, value) player.PlayerData.metadata[key] = value end,
        RemoveMoney = function(kind, amount)
            state.money[#state.money + 1] = { kind = kind, amount = amount }
            return true
        end,
        AddMoney = function() return true end,
        SetJob = function(name, grade) state.jobs[#state.jobs + 1] = { name = name, grade = grade } end,
    }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        GetPlayerByCitizenId = function(cid)
            for _, player in pairs(state.players) do
                if player.PlayerData.citizenid == cid then return player end
            end
            return nil
        end,
        CreateCallback = function() end,
        HasPermission = function() return false end,
        GetDutyCount = function() return 0 end,
    },
    Shared = {
        Items = setmetatable({}, { __index = function(_, key) return { label = tostring(key) } end }),
        StarterItems = { { item = 'phone' }, { item = 'id_card' }, { item = 'driver_license' } },
        Jobs = setmetatable({}, {
            __index = function(_, key)
                if key == 'trucker' then
                    return { label = 'Trucker', grades = { ['0'] = { name = 'Trainee' } } }
                end
                if key == 'police' then
                    return { label = 'Police', grades = { ['0'] = { name = 'Cadet' } } }
                end
                return nil
            end,
        }),
    },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    if name == 'QBCore:Notify' then
        state.notifications[#state.notifications + 1] = { target = target, args = { ... } }
    end
end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return clock end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
local function vec4(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = vec4
GetEntityCoords = function() return state.coords or vec3(0.0, 0.0, 0.0) end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    insert = function() end,
    update = function() end,
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'qb-inventory' then
            return {
                AddItem = function(_, src, item, amount)
                    state.added[#state.added + 1] = { src = src, item = item, amount = amount }
                    return state.addItemResult ~= false
                end,
            }
        end
        if name == 'custom-certificates' then
            return { GrantLicense = function(_, src, kind)
                state.licenses = state.licenses or {}
                state.licenses[#state.licenses + 1] = { src = src, kind = kind }
                return true, 'ok'
            end }
        end
        if name == 'qb-phone' then
            return { sendNewMailToOffline = function(_, cid) state.mails[#state.mails + 1] = cid end }
        end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
    source = source:gsub('vec3%(', 'vector3(')
    source = source:gsub('vec4%(', 'vector4(')
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'main.lua')

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

state.players[1] = makePlayer(1)
state.players[2] = makePlayer(2, 'CIDSCHOOL')

-- 先把"新手三件套"标记为已领取（模拟正常玩家），让后面的取证流程不被它干扰
state.players[1].PlayerData.items = {
    { name = 'phone', amount = 1 }, { name = 'id_card', amount = 1 }, { name = 'driver_license', amount = 1 },
}

-- ── 1. requestId：坏 hall / 坏 item 不崩 ──
emit('SCENARIO', 'request-id')
emit('ID_BAD_HALL_SAFE', tostring(fireAs(1, 'qb-cityhall:server:requestId', 'id_card', 'not-a-hall')))
emit('ID_BAD_HALL_INDEX_SAFE', tostring(fireAs(1, 'qb-cityhall:server:requestId', 'id_card', 99)))
emit('ID_BAD_ITEM_SAFE', tostring(fireAs(1, 'qb-cityhall:server:requestId', 42, 1)))

-- ── 2. getIDs：已有的东西不再发（原来可以无限刷）──
emit('SCENARIO', 'starter-items')
state.added = {}
fireAs(1, 'qb-cityhall:server:getIDs')
emit('STARTER_REPEAT_NOTHING_ADDED', tostring(#state.added == 0))

state.added = {}
state.players[1].PlayerData.items = {}         -- 新角色：什么都没有
fireAs(1, 'qb-cityhall:server:getIDs')
emit('STARTER_FIRST_TIME_ADDED', tostring(#state.added == 3))
state.added = {}
fireAs(1, 'qb-cityhall:server:getIDs')          -- 但背包没同步（还没真正入包）→ 仍会补发；用第二次的语义说明
emit('STARTER_REPEAT_WITH_EMPTY_BAG', tostring(#state.added))

-- ── 3. sendDriverTest：条数上限 ──
emit('SCENARIO', 'driver-test')
state.mails = {}
local many = {}
for index = 1, 50 do many[index] = 'CID' .. index end
clock = clock + 100
fireAs(1, 'qb-cityhall:server:sendDriverTest', many)
emit('DRIVERTEST_MAIL_COUNT', tostring(#state.mails))
state.mails = {}
fireAs(1, 'qb-cityhall:server:sendDriverTest', many)   -- 冷却内
emit('DRIVERTEST_COOLDOWN', tostring(#state.mails == 0))

-- ── 4. ApplyJob：距离必须用服务端配置里的市政厅坐标 ──
emit('SCENARIO', 'apply-job')
local hall = Config.Cityhalls[1]
state.coords = vec3(hall.coords.x, hall.coords.y, hall.coords.z)
-- 正常客户端传的就是这间市政厅的坐标
state.jobs = {}
fireAs(1, 'qb-cityhall:server:ApplyJob', 'trucker', vec3(hall.coords.x, hall.coords.y, hall.coords.z))
emit('APPLY_JOB_OK', tostring(#state.jobs == 1 and state.jobs[1].name == 'trucker'))

state.jobs = {}
fireAs(1, 'qb-cityhall:server:ApplyJob', 'police', vec3(0.0, 0.0, 0.0))
emit('APPLY_JOB_NOT_IN_LIST_REJECTED', tostring(#state.jobs == 0))

-- 玩家在远处，但把"市政厅坐标"谎报成自己脚下 → 必须仍被拒
state.coords = vec3(5000.0, 5000.0, 0.0)
state.jobs = {}
fireAs(1, 'qb-cityhall:server:ApplyJob', 'trucker', vec3(5000.0, 5000.0, 0.0))
emit('APPLY_JOB_REMOTE_REJECTED', tostring(#state.jobs == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
