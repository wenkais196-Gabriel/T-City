-- tests/unit/layer3_business/fixtures/money_path_probe.lua
-- 真加载 qb-core 的 security_service.lua + economy_service.lua。
-- 重点：AddMoney / RemoveMoney / SetMoney 三个入口对**同一组非法输入**给出同一个答复
--       （拒绝语义，不 clamp），且金额规则只有一份实现。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { money = { cash = 1000, bank = 1000 }, events = 0, audits = 0 }

local QBCoreMock = {
    Players = {},
    Config = {
        Money = {
            MoneyTypes = { cash = true, bank = true, crypto = true },
            DontAllowMinus = { 'bank' },
            MinusLimit = -1000,
        },
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }) },
    Functions = {
        GetPlayer = function(source) return QBCoreMock.Players[source] end,
        CreateCallback = function() end,
    },
}
QBCore = QBCoreMock

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetCurrentResourceName = function() return 'qb-core' end
GetPlayerName = function(source) return 'player' .. tostring(source) end
TriggerClientEvent = function() state.events = state.events + 1 end
TriggerEvent = function() state.events = state.events + 1 end

Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    scalar = { await = function() return 0 end },
    prepare = { await = function() return nil end },
    insert = function() end,
    update = function() end,
}
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function()
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([A-Za-z0-9_]+)`', "GetHashKey('%1')")
    source = source:gsub('(%w+)%s*%+=%s*%1%s*%+%s*', '%1 = %1 + ')
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/server/services/security_service.lua', 'security_service.lua')
load_lua(RES .. '/server/services/economy_service.lua', 'economy_service.lua')

local Security = assert(_G.Bus and _G.Bus.SecurityService, 'SecurityService 未注册')
local Economy = assert(_G.Bus and _G.Bus.EconomyService, 'EconomyService 未注册')

-- 一个在线玩家对象（EconomyService 通过 QBCore.Players 里的 citizenid 找）
local player = {
    PlayerData = { source = 1, citizenid = 'CID1', money = state.money },
    Functions = { UpdatePlayerData = function() end },
}
QBCoreMock.Players[1] = player

-- ── 1. 单一实现 ──
emit('SCENARIO', 'validator')
emit('VALIDATOR_EXISTS', tostring(type(Security.ValidateAmount) == 'function'))
emit('THRESHOLD_IS_FIVE_MILLION', tostring(Security.MONEY_MAX_SINGLE_TRANSACTION == 5000000))

local function checkValidate(amount, opts)
    -- 旧实现没有 ValidateAmount：返回 nil 让下面每条断言都变 false（区分度来自这里）
    if type(Security.ValidateAmount) ~= 'function' then return nil end
    return Security.ValidateAmount(amount, opts)
end
emit('VALIDATOR_REJECTS_NAN', tostring(checkValidate(0 / 0) == false))
emit('VALIDATOR_REJECTS_INF', tostring(checkValidate(math.huge) == false))
emit('VALIDATOR_REJECTS_NEG_INF', tostring(checkValidate(-math.huge) == false))
emit('VALIDATOR_REJECTS_STRING', tostring(checkValidate('abc') == false))
emit('VALIDATOR_REJECTS_NEGATIVE', tostring(checkValidate(-1) == false))
emit('VALIDATOR_REJECTS_ZERO_BY_DEFAULT', tostring(checkValidate(0) == false))
emit('VALIDATOR_ALLOWS_ZERO_WHEN_ASKED', tostring(checkValidate(0, { allowZero = true }) == true))
emit('VALIDATOR_ALLOWS_999999', tostring(checkValidate(999999) == true))
emit('VALIDATOR_REJECTS_OVER_LIMIT', tostring(checkValidate(5000001) == false))
emit('VALIDATOR_ALLOWS_LIMIT', tostring(checkValidate(5000000) == true))

-- ── 2. economy_service 三个入口 ──
local CASES = { 'nan', 'inf', 'string', 'negative', 'zero', '999999', 'over' }
local VALUES = {
    nan = 0 / 0, inf = math.huge, string = 'abc', negative = -5, zero = 0,
    ['999999'] = 999999, over = 5000001,
}

local function resetMoney()
    state.money.cash = 1000
    state.money.bank = 1000
end

for _, op in ipairs({ 'AddMoney', 'RemoveMoney', 'SetMoney' }) do
    local rejected = {}
    for _, case in ipairs(CASES) do
        resetMoney()
        local before = state.money.cash
        local called, ok = pcall(Economy[op], 'CID1', 'cash', VALUES[case], 'probe')
        if not called then
            rejected[case] = 'error'
        else
            rejected[case] = (ok == false and state.money.cash == before) and 'reject' or 'accept'
        end
    end
    emit('ECONOMY_' .. op .. '_NAN', rejected.nan)
    emit('ECONOMY_' .. op .. '_INF', rejected.inf)
    emit('ECONOMY_' .. op .. '_STRING', rejected.string)
    emit('ECONOMY_' .. op .. '_NEGATIVE', rejected.negative)
    emit('ECONOMY_' .. op .. '_ZERO', rejected.zero)
    emit('ECONOMY_' .. op .. '_OVER', rejected.over)
    emit('ECONOMY_' .. op .. '_999999', rejected['999999'])
end

-- 正常值必须能过（全拒的实现也能让负向用例全绿）
resetMoney()
emit('ECONOMY_ADD_NORMAL', tostring(Economy.AddMoney('CID1', 'cash', 500, 'probe') == true and state.money.cash == 1500))
resetMoney()
emit('ECONOMY_REMOVE_NORMAL', tostring(Economy.RemoveMoney('CID1', 'cash', 500, 'probe') == true and state.money.cash == 500))
resetMoney()
emit('ECONOMY_SET_NORMAL', tostring(Economy.SetMoney('CID1', 'cash', 750, 'probe') == true and state.money.cash == 750))
resetMoney()
emit('ECONOMY_SET_ZERO_ALLOWED', tostring(Economy.SetMoney('CID1', 'cash', 0, 'probe') == true and state.money.cash == 0))

-- moneytype 非字符串不能抛错
resetMoney()
local calledBadType, okBadType = pcall(Economy.AddMoney, 'CID1', nil, 100, 'probe')
if not calledBadType then okBadType = false end
emit('ECONOMY_BAD_MONEYTYPE_SAFE', tostring(okBadType == false))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
