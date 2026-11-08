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

local state = { money = { crypto = 0 }, items = {}, addedMoney = {}, clientEvents = {}, coords = nil, addMoneyFails = false }

-- metadata 单独一张表：SetMetaData 里不能引用 player 自身（局部变量在初始化式里还不可见）
local playerMeta = {}
local player = {
    PlayerData = { source = 1, citizenid = 'TESTCID', charinfo = { firstname = 'T', lastname = 'C' }, metadata = playerMeta },
    Functions = {
        SetMetaData = function(key, value)
            playerMeta[key] = value
        end,
        GetItemByName = function(name)
            return state.items[name] and { name = name, amount = state.items[name] } or nil
        end,
        AddMoney = function(account, amount, reason)
            if state.addMoneyFails then return false end
            state.money[account] = (state.money[account] or 0) + amount
            state.addedMoney[#state.addedMoney + 1] = { account = account, amount = amount }
            return true
        end,
        GetMoney = function(account) return state.money[account] or 0 end,
    },
}

-- 第二个在线玩家（模拟"非 owner 也想改全服状态"）
local otherPlayer = {
    PlayerData = { source = 2, citizenid = 'OTHER', charinfo = { firstname = 'O', lastname = 'T' }, metadata = {} },
    Functions = {
        GetItemByName = function() return nil end,
        AddMoney = function() return true end,
        GetMoney = function() return 0 end,
    },
}

local QBCoreMock = {
    Functions = { GetPlayer = function(source)
        if source == 1 then return player end
        if source == 2 then return otherPlayer end
        return nil
    end, CreateCallback = function() end },
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
AddEventHandler = function(name, fn) handlers[name] = fn end
GetPlayerPed = function() return 1 end
GetEntityCoords = function() return state.coords or vector3(0.0, 0.0, 0.0) end
-- FiveM 向量支持 `-` 与 `#`（资源里用 #(coords - anchor.xyz) 算距离）
local vectorMeta = {}
vectorMeta.__index = vectorMeta
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z)
    local value = setmetatable({ x = x, y = y, z = z }, vectorMeta)
    value.xyz = setmetatable({ x = x, y = y, z = z }, vectorMeta)
    return value
end
vector2 = function(x, y) return vec3(x, y, 0) end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end
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
                    if method == 'AddItem' then
                        local args = { ... }
                        if state.addItemFails then return false end
                        local itemName = args[2]
                        state.items[itemName] = (state.items[itemName] or 0) + (args[3] or 1)
                        return true
                    end
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

-- 场景 3b：扣货成功但加钱失败 → 必须把 cryptostick 还回去
emit('SCENARIO', 'add-money-fails')
state.items = { cryptostick = 1 }
state.addMoneyFails = true
fireAs(1, 'qb-crypto:server:ExchangeSuccess')
state.addMoneyFails = false
emit('STICKS_BACK_AFTER_PAY_FAIL', state.items.cryptostick or 0)

-- 场景 3c：加钱失败 + 回补也失败（背包满）→ 欠账写进 metadata，下次上线补发
emit('SCENARIO', 'refund-fails-then-retry')
state.items = { cryptostick = 1 }
state.addMoneyFails = true
state.addItemFails = true
fireAs(1, 'qb-crypto:server:ExchangeSuccess')
state.addMoneyFails = false
state.addItemFails = false
emit('OWED_AFTER_DOUBLE_FAIL', tostring(player.PlayerData.metadata.cryptostick_refunds or 0))
local loaded = handlers['QBCore:Server:PlayerLoaded']
if loaded then loaded(player) end
emit('OWED_AFTER_RELOAD', tostring(player.PlayerData.metadata.cryptostick_refunds or 0))
emit('STICKS_AFTER_RELOAD', state.items.cryptostick or 0)

-- 场景 4：重启会话由服务端在 ExchangeFail 时创建；Rebooting 只做进度上报
emit('SCENARIO', 'rebooting-validation')
state.coords = vector3(Crypto.Exchange.coords.x, Crypto.Exchange.coords.y, Crypto.Exchange.coords.z)
state.items = { cryptostick = 1 }
fireAs(1, 'qb-crypto:server:ExchangeFail')
emit('SESSION_STATE_AFTER_FAIL', tostring(Crypto.Exchange.RebootInfo.state))
clock = clock + 1000
fireAs(1, 'qb-crypto:server:Rebooting', 'hax', 50)
emit('REBOOT_PCT_AFTER_BAD', tostring(Crypto.Exchange.RebootInfo.percentage))
clock = clock + 1000
fireAs(1, 'qb-crypto:server:Rebooting', true, 150)
emit('REBOOT_PCT_AFTER_OUT_OF_RANGE', tostring(Crypto.Exchange.RebootInfo.percentage))
clock = clock + 1000
fireAs(1, 'qb-crypto:server:Rebooting', true, 42)
emit('REBOOT_PCT_AFTER_GOOD', tostring(Crypto.Exchange.RebootInfo.percentage))

-- 场景 4b：没有会话时，任何玩家都不能自己发起重启
emit('SCENARIO', 'reboot-without-session')
clock = clock + 1000
fireAs(1, 'qb-crypto:server:Rebooting', false, 0)
emit('SESSION_CLEARED', tostring(Crypto.Exchange.RebootInfo.state))
clock = clock + 1000
fireAs(2, 'qb-crypto:server:Rebooting', true, 10)
emit('REBOOT_PCT_WITHOUT_SESSION', tostring(Crypto.Exchange.RebootInfo.percentage))

-- 场景 4c：会话硬上限 5 分钟 —— 拥有者持续上报也不能永久占用
emit('SCENARIO', 'reboot-session-expiry')
state.items = { cryptostick = 1 }
fireAs(1, 'qb-crypto:server:ExchangeFail')
clock = clock + 6 * 60 * 1000
fireAs(1, 'qb-crypto:server:Rebooting', true, 55)
emit('REBOOT_STATE_AFTER_EXPIRY', tostring(Crypto.Exchange.RebootInfo.state))
emit('REBOOT_PCT_AFTER_EXPIRY', tostring(Crypto.Exchange.RebootInfo.percentage))

-- 场景 5：会话拥有者存在时，其他玩家（同样站在柜员机前）不能改进度
emit('SCENARIO', 'reboot-non-owner')
state.coords = vector3(Crypto.Exchange.coords.x, Crypto.Exchange.coords.y, Crypto.Exchange.coords.z)
state.items = { cryptostick = 1 }
fireAs(1, 'qb-crypto:server:ExchangeFail')
clock = clock + 1000
fireAs(2, 'qb-crypto:server:Rebooting', true, 99)
emit('REBOOT_PCT_AFTER_NON_OWNER', tostring(Crypto.Exchange.RebootInfo.percentage))

-- 场景 6：会话拥有者走出 20 米，仍然必须能把状态收尾（否则全服永久卡"重启中"）
emit('SCENARIO', 'reboot-owner-finish-remote')
state.coords = vector3(9999.0, 9999.0, 9999.0)
clock = clock + 1000
fireAs(1, 'qb-crypto:server:Rebooting', false, 0)
emit('REBOOT_STATE_OWNER_FINISH', tostring(Crypto.Exchange.RebootInfo.state))
emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
