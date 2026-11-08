-- tests/unit/layer3_business/fixtures/weapons_probe.lua
-- 只加载 qb-weapons 的 config.lua 与 server/main.lua，把 FiveM 运行时换成记录器，
-- 真的触发 net event，观察「武器有没有被加进背包 / 弹药被写成多少」。
-- main.lua 里有 CfxLua 的反引号哈希字面量（`WEAPON_UNARMED`），luac/标准 Lua 解析不了，
-- 所以读进来先换成 GetHashKey('...') 再 load。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { addedItems = {}, now = 0 }

local player = {
    PlayerData = {
        source = 1,
        citizenid = 'TESTCID',
        items = {
            [1] = { name = 'weapon_pistol', info = { ammo = 0, quality = 100 } },
        },
    },
    Functions = {
        SetInventory = function() end,
        AddMoney = function() return true end,
    },
}

local QBCoreMock = {
    Functions = {
        GetPlayer = function(source) return source == 1 and player or nil end,
        CreateCallback = function() end,
        CreateUseableItem = function() end,
        GetPlayers = function() return {} end,
        GetDutyCount = function() return 0 end,
        AddCommand = function() end,
    },
    Commands = { Add = function() end },
    Shared = {
        Items = setmetatable({}, { __index = function(_, key) return { label = tostring(key) } end }),
        Weapons = setmetatable({}, { __index = function(_, key) return { name = 'weapon_pistol', ammo = 1 } end }),
        Round = function(value, digits)
            local mult = 10 ^ (digits or 0)
            return math.floor(value * mult + 0.5) / mult
        end,
    },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function() end
TriggerServerEvent = function() end
SetTimeout = function() end
Wait = function() end
CreateThread = function() end
GetGameTimer = function() return state.now end
os.time = os.time
GetHashKey = function(value) return 'hash:' .. tostring(value) end
joaat = GetHashKey
json = { encode = function() return '{}' end, decode = function() return {} end }
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
GetConvar = function(_, default) return default end
GetConvarInt = function(_, default) return tonumber(default) or 0 end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
MySQL = setmetatable({}, { __index = function() return setmetatable({}, { __call = function() end, __index = function() return function() end end }) end })

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCoreMock end }
        end
        return setmetatable({}, {
            __index = function(_, method)
                return function(_, ...)
                    local args = { ... }
                    if method == 'AddItem' then
                        state.addedItems[#state.addedItems + 1] = { item = args[2], amount = args[3], source = args[1] }
                    end
                    return true
                end
            end,
        })
    end,
})

local function fire(name, ...)
    _G.source = 1
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
    return ok
end

-- config.lua 与 main.lua 都含 CfxLua 的反引号哈希字面量（`WEAPON_PISTOL`），
-- 标准 Lua 解析不了 → 统一读进来降级成 GetHashKey('...') 再 load。
local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    source = source:gsub('`([%w_]+)`', "GetHashKey('%1')")
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/config.lua', 'config.lua')
load_lua(RES .. '/server/main.lua', 'main.lua')

-- ── 场景 1：取别人送修的枪（旧实现：任意 k 都能取 → 双方各得一把 = 复制）──
Config.WeaponRepairPoints = {
    [1] = {
        IsRepairing = false,
        RepairingData = {
            CitizenId = 'OTHERCID',
            WeaponData = { name = 'weapon_pistol', info = {} },
            Ready = true,
        },
    },
    [2] = {
        IsRepairing = true,
        RepairingData = {
            CitizenId = 'TESTCID',
            WeaponData = { name = 'weapon_carbinerifle', info = {} },
            Ready = false,
        },
    },
    [3] = {
        IsRepairing = false,
        RepairingData = {
            CitizenId = 'TESTCID',
            WeaponData = { name = 'weapon_pistol', info = {} },
            Ready = true,
        },
    },
}

emit('SCENARIO', 'takeback-foreign')
fire('qb-weapons:server:TakeBackWeapon', 1)
emit('ADDED', #state.addedItems)

emit('SCENARIO', 'takeback-not-ready')
fire('qb-weapons:server:TakeBackWeapon', 2)
emit('ADDED', #state.addedItems)

emit('SCENARIO', 'takeback-bad-index')
fire('qb-weapons:server:TakeBackWeapon', 999)
emit('ADDED', #state.addedItems)

emit('SCENARIO', 'takeback-own')
fire('qb-weapons:server:TakeBackWeapon', 3)
emit('ADDED', #state.addedItems)
-- 再取一次：记录已被清空，不能再发一把
fire('qb-weapons:server:TakeBackWeapon', 3)
emit('ADDED', #state.addedItems)

-- ── 场景 2：弹药范围（旧实现把 amount 原样写入 → 无限子弹）──
emit('SCENARIO', 'ammo-cap')
fire('qb-weapons:server:UpdateWeaponAmmo', { slot = 1, name = 'weapon_pistol' }, 999999)
emit('AMMO', player.PlayerData.items[1].info.ammo)

emit('SCENARIO', 'ammo-negative')
fire('qb-weapons:server:UpdateWeaponAmmo', { slot = 1, name = 'weapon_pistol' }, -5)
emit('AMMO', player.PlayerData.items[1].info.ammo)

emit('SCENARIO', 'ammo-bad-slot')
local ok = fire('qb-weapons:server:UpdateWeaponAmmo', { slot = 999, name = 'weapon_pistol' }, 10)
emit('OK', ok)
emit('AMMO', player.PlayerData.items[1].info.ammo)

emit('SCENARIO', 'ammo-name-mismatch')
fire('qb-weapons:server:UpdateWeaponAmmo', { slot = 1, name = 'weapon_carbinerifle' }, 42)
emit('AMMO', player.PlayerData.items[1].info.ammo)

io.write(table.concat(OUT, '\n'), '\n')
