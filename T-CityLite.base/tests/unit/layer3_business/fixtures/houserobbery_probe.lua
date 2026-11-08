-- tests/unit/layer3_business/fixtures/houserobbery_probe.lua
-- 真加载 qb-houserobbery 的 config.lua + server/main.lua。
-- 重点：客户端传的 house/cabin 索引校验、已搜状态、以及**导出资源名**（custom-crime 而不是 custom-main）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
    added = {},
    notifications = 0,
    checkCalls = {},
    missingExportErrors = 0,
    callbacks = {},
    players = {},
}

local function makePlayer(source, citizenid)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = citizenid or ('CID' .. source),
        license = 'LIC' .. source, job = { name = 'unemployed', onduty = false },
        metadata = {}, money = { cash = 1000, bank = 1000 },
    }
    player.Functions = { SetMetaData = function() end, RemoveMoney = function() return true end }
    return player
end

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return state.players[tonumber(source) or -1] end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        GetDutyCount = function() return 0 end,
        HasPermission = function() return false end,
    },
    Shared = {
        Items = setmetatable({}, {
            __index = function(_, key)
                return { name = key, label = tostring(key), unique = false, weight = 1 }
            end,
        }),
    },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name)
    if name == 'QBCore:Notify' then state.notifications = state.notifications + 1 end
end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetConvarInt = function(_, default) return tonumber(default) or 0 end
vector2 = function(x, y) return { x = x or 0.0, y = y or 0.0 } end
vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end
GetConvarBool = function(_, default) return default ~= false end
GetPlayerName = function(source) return 'player' .. tostring(source) end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    insert = function() end,
    update = function() end,
}

-- exports：custom-main **没有** CheckHouseRobbery（正是原来的 bug），custom-crime 才有
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        if name == 'custom-main' then
            return setmetatable({}, {
                __index = function(_, method)
                    if method == 'CheckHouseRobbery' then
                        -- 模拟真机：资源没有这个导出 → 调用即抛错
                        return function() error("No such export CheckHouseRobbery in resource custom-main") end
                    end
                    return function() return true end
                end,
            })
        end
        if name == 'custom-crime' then
            return {
                CheckHouseRobbery = function(_, src, house, cabin)
                    state.checkCalls[#state.checkCalls + 1] = { src = src, house = house, cabin = cabin }
                    return state.checkResult ~= false
                end,
            }
        end
        if name == 'qb-inventory' then
            return {
                AddItem = function(_, src, item, amount)
                    state.added[#state.added + 1] = { src = src, item = item, amount = amount }
                    return true
                end,
                RemoveItem = function() return true end,
            }
        end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
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

-- 找一间有家具的房子
local houseName, houseConfig = nil, nil
for name, cfg in pairs(Config.Houses) do
    if type(cfg) == 'table' and type(cfg['furniture']) == 'table' then
        for cabin in pairs(cfg['furniture']) do
            houseName, houseConfig = name, cfg
            break
        end
        if houseName then break end
    end
end
assert(houseName, '配置里找不到可搜刮的房子')
local cabinId = next(houseConfig['furniture'])
local cabinConfig = houseConfig['furniture'][cabinId]

-- ── 1. SetBusyState：坏 key 不崩、正常 key 生效 ──
emit('SCENARIO', 'busy')
emit('BUSY_BAD_HOUSE_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:SetBusyState', 1, 'no-such-house', true)))
emit('BUSY_BAD_CABIN_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:SetBusyState', 999, houseName, true)))
emit('BUSY_BAD_TYPE_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:SetBusyState', cabinId, houseName, 'yes')))
fireAs(1, 'qb-houserobbery:server:SetBusyState', cabinId, houseName, true)
emit('BUSY_SET_OK', tostring(cabinConfig['isBusy'] == true))
fireAs(1, 'qb-houserobbery:server:SetBusyState', cabinId, houseName, false)

-- ── 2. enterHouse：坏 key 不崩 ──
emit('SCENARIO', 'enter')
emit('ENTER_BAD_HOUSE_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:enterHouse', 'no-such-house')))
emit('ENTER_BAD_TYPE_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:enterHouse', 42)))

-- ── 3. searchFurniture：导出必须打到 custom-crime（写成 custom-main 会抛错）──
emit('SCENARIO', 'search')
cabinConfig['searched'] = false
state.added = {}
state.checkResult = true
local okSearch = fireAs(1, 'qb-houserobbery:server:searchFurniture', cabinId, houseName)
emit('SEARCH_NO_ERROR', tostring(okSearch))
emit('SEARCH_CHECK_DELEGATED', tostring(#state.checkCalls > 0))
emit('SEARCH_MARKED_SEARCHED', tostring(cabinConfig['searched'] == true))

-- 已经搜过的抽屉：再搜必须直接拒（不再发奖、不再调准入）
local callsBefore = #state.checkCalls
state.added = {}
fireAs(1, 'qb-houserobbery:server:searchFurniture', cabinId, houseName)
emit('SEARCH_AGAIN_BLOCKED', tostring(#state.checkCalls == callsBefore and #state.added == 0))

-- 坏 cabin / 坏 house：不崩、不发奖
cabinConfig['searched'] = false
state.added = {}
emit('SEARCH_BAD_CABIN_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:searchFurniture', 999, houseName)))
emit('SEARCH_BAD_HOUSE_SAFE', tostring(fireAs(1, 'qb-houserobbery:server:searchFurniture', cabinId, 'no-such-house')))
emit('SEARCH_BAD_ARGS_NO_ITEMS', tostring(#state.added == 0))

-- 准入拒绝时不发奖
cabinConfig['searched'] = false
state.checkResult = false
state.added = {}
fireAs(1, 'qb-houserobbery:server:searchFurniture', cabinId, houseName)
emit('SEARCH_DENIED_NO_ITEMS', tostring(#state.added == 0 and cabinConfig['searched'] == false))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
