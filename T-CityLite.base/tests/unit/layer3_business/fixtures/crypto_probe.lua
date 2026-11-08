-- tests/unit/layer3_business/fixtures/crypto_probe.lua
-- 真加载 qb-crypto 的 config.lua + server/main.lua，检查：
--   1) 没有 cryptostick 时 ExchangeSuccess 不发钱；
--   2) 有 cryptostick 但 qb-inventory 扣货失败（返回 false）时也不发钱（原来忽略返回值 = 白拿钱）；
--   3) 正常兑换：扣 1 根、加一次钱；
--   4) Rebooting 拒绝未知 state 与越界进度。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { money = { crypto = 0 }, items = {}, addedMoney = {}, clientEvents = {} }

local player = {
    PlayerData = { source = 1, citizenid = 'TESTCID', charinfo = { firstname = 'T', lastname = 'C' } },
    Functions = {
        GetItemByName = function(name)
            return state.items[name] and { name = name, amount = state.items[name] } or nil
        end,
        AddMoney = function(account, amount, reason)
            state.money[account] = (state.money[account] or 0) + amount
            state.addedMoney[#state.addedMoney + 1] = { account = account, amount = amount }
            return true
        end,
        GetMoney = function(account) return state.money[account] or 0 end,
    },
}

local QBCoreMock = {
    Functions = { GetPlayer = function(source) return source == 1 and player or nil end, CreateCallback = function() end },
    Shared = { Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, target, ...)
    state.clientEvents[#state.clientEvents + 1] = { name = name, target = target, args = { ... } }
end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
local clock = 0
GetGameTimer = function() return clock end
GetConvar = function(_, default) return default end
vector2 = function(x, y) return { x = x, y = y, xyz = { x = x, y = y } } end
vector3 = function(x, y, z) return { x = x, y = y, z = z, xyz = { x = x, y = y } } end
vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w, xyz = { x = x, y = y } } end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCoreMock end }
        end
        return setmetatable({}, {
            __index = function(_, method)
                return function(_, ...)
                    if method == 'RemoveItem' then
                        local args = { ... }
                        local itemName = args[2]
                        if state.removeFails then return false end
                        if (state.items[itemName] or 0) <= 0 then return false end
                        state.items[itemName] = state.items[itemName] - 1
                        return true
                    end
                    return true
                end
            end,
        })
    end,
})

MySQL = setmetatable({}, {
    __index = function()
        return setmetatable({}, {
            __call = function() return 1 end,
            __index = function()
                return function() return { { worth = 1, history = nil } } end
            end,
        })
    end,
})

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
    return ok
end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    -- 只把 CfxLua 的哈希字面量（`WEAPON_PISTOL`）换成 GetHashKey；
    -- SQL 里的反引号标识符（`` `players` ``）必须原样保留，否则会写出非法 Lua。
    source = source:gsub('`([A-Z][A-Z0-9_]*)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end
GetHashKey = function(value) return 'hash:' .. tostring(value) end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'main.lua')

-- 场景 1：没有 cryptostick
emit('SCENARIO', 'no-stick')
state.items = {}
local b = #state.addedMoney
fireAs(1, 'qb-crypto:server:ExchangeSuccess')
emit('MONEY_EVENTS', #state.addedMoney - b)

-- 场景 2：有 cryptostick，但扣货失败
emit('SCENARIO', 'remove-fails')
state.items = { cryptostick = 1 }
state.removeFails = true
b = #state.addedMoney
fireAs(1, 'qb-crypto:server:ExchangeSuccess')
emit('MONEY_EVENTS', #state.addedMoney - b)

-- 场景 3：正常兑换
emit('SCENARIO', 'normal')
state.removeFails = false
state.items = { cryptostick = 1 }
b = #state.addedMoney
fireAs(1, 'qb-crypto:server:ExchangeSuccess')
emit('MONEY_EVENTS', #state.addedMoney - b)
emit('STICKS_LEFT', state.items.cryptostick or 0)

-- 场景 4：Rebooting 只接受已知 state 与 0~100
emit('SCENARIO', 'rebooting-validation')
-- 客户端真实发的是 Rebooting(true/false, pct)（见 client/main.lua 的重启循环）
fireAs(1, 'qb-crypto:server:Rebooting', 'hax', 50)          -- 非 boolean → 拒
emit('REBOOT_STATE_AFTER_BAD', tostring(Crypto.Exchange.RebootInfo.state))
fireAs(1, 'qb-crypto:server:Rebooting', true, 150)          -- 越界 → 拒
emit('REBOOT_PCT_AFTER_BAD', tostring(Crypto.Exchange.RebootInfo.percentage))
clock = clock + 1000
fireAs(1, 'qb-crypto:server:Rebooting', true, 42)           -- 合法
emit('REBOOT_PCT_AFTER_GOOD', tostring(Crypto.Exchange.RebootInfo.percentage))
emit('REBOOT_STATE_AFTER_GOOD', tostring(Crypto.Exchange.RebootInfo.state))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
