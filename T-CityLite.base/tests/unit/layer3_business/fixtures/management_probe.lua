-- tests/unit/layer3_business/fixtures/management_probe.lua
-- 真加载 qb-management 的 config.lua + server/sv_boss.lua + sv_gang.lua + sv_org.lua。
-- 重点：三个 boss 仓库入口的「本人是 boss + 站在菜单点 2.5 米内」判定。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { opened = {}, players = {}, coords = nil, callbacks = {} }

local function makePlayer(source, jobName, isboss, gangName, gangBoss)
    local player = {}
    player.PlayerData = {
        source = source, citizenid = 'CID' .. source, license = 'LIC' .. source,
        job = { name = jobName or 'unemployed', isboss = isboss == true, grade = { level = 4 } },
        gang = { name = gangName or 'none', isboss = gangBoss == true, grade = { level = 0 } },
        metadata = {}, money = { cash = 1000, bank = 1000 }, items = {},
        charinfo = { firstname = 'Test', lastname = 'Player' },
    }
    player.Functions = { SetMetaData = function() end, SetJob = function() end, SetGang = function() end }
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
        GetOfflinePlayerByCitizenId = function() return nil end,
        CreateCallback = function(name, fn) state.callbacks[name] = fn end,
        HasPermission = function() return false end,
    },
    Shared = { Items = setmetatable({}, { __index = function() return {} end }), Jobs = setmetatable({}, { __index = function() return nil end }) },
    Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function() end
CreateThread = function() end
Wait = function() end
GetGameTimer = function() return 1000 end
GetConvar = function(_, default) return default end
GetPlayerName = function(source) return 'player' .. tostring(source) end
GetPlayerPed = function(source) return source end
GetPlayerIdentifier = function() return 'license:abc' end

local vectorMeta = {}
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, vectorMeta) end
vector2 = function(x, y) return { x = x, y = y } end
vector3 = vec3
vector4 = function(x, y, z, w) local v = vec3(x, y, z); v.w = w; return v end
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
            return { OpenInventory = function(_, src, stash) state.opened[#state.opened + 1] = { src = src, stash = stash } end }
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
load_lua(RES .. '/server/sv_boss.lua', 'sv_boss.lua')
load_lua(RES .. '/server/sv_gang.lua', 'sv_gang.lua')
load_lua(RES .. '/server/sv_org.lua', 'sv_org.lua')

local function fireAs(src, name, ...)
    _G.source = src
    local handler = handlers[name]
    if not handler then error('handler 未注册: ' .. name) end
    local ok, err = pcall(handler, ...)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. name .. '|' .. tostring(err) end
    return ok
end

-- 找一对「配置里存在的职业/帮派菜单」
local bossJobName, bossCoords = nil, nil
for name, coords in pairs(Config.BossMenus) do bossJobName, bossCoords = name, coords; break end
local gangName, gangCoords = nil, nil
for name, coords in pairs(Config.GangMenus) do gangName, gangCoords = name, coords; break end

state.players[1] = makePlayer(1, bossJobName, true)
state.players[2] = makePlayer(2, bossJobName, false)     -- 同职业但不是 boss
state.players[3] = makePlayer(3, bossJobName, true)      -- boss 但站很远

-- ── 1. 职业 boss 仓库 ──
emit('SCENARIO', 'boss-stash')
state.opened = {}
state.coords = vec3(bossCoords[1].x, bossCoords[1].y, bossCoords[1].z)
fireAs(2, 'qb-bossmenu:server:stash')
emit('BOSS_STASH_NON_BOSS_BLOCKED', tostring(#state.opened == 0))

state.opened = {}
state.coords = vec3(5000.0, 5000.0, 0.0)      -- boss 但站在地图另一头
fireAs(3, 'qb-bossmenu:server:stash')
emit('BOSS_STASH_FAR_BLOCKED', tostring(#state.opened == 0))

state.opened = {}
state.coords = vec3(bossCoords[1].x, bossCoords[1].y, bossCoords[1].z)
fireAs(1, 'qb-bossmenu:server:stash')
emit('BOSS_STASH_OK', tostring(#state.opened == 1 and state.opened[1].stash == 'boss_' .. bossJobName))

-- ── 2. 组织菜单（职业 boss 走 job 分支）──
emit('SCENARIO', 'org-stash')
state.opened = {}
fireAs(1, 'qb-orgmenu:server:stash')
emit('ORG_STASH_BOSS_OK', tostring(#state.opened == 1))

state.opened = {}
fireAs(2, 'qb-orgmenu:server:stash')
emit('ORG_STASH_NON_BOSS_BLOCKED', tostring(#state.opened == 0))

-- ── 3. 帮派仓库 / 个人仓库 ──
if gangName then
    emit('SCENARIO', 'gang-stash')
    state.players[4] = makePlayer(4, 'unemployed', false, gangName, true)
    state.players[5] = makePlayer(5, 'unemployed', false, gangName, false)
    state.coords = vec3(gangCoords[1].x, gangCoords[1].y, gangCoords[1].z)

    state.opened = {}
    fireAs(5, 'qb-gangmenu:server:stash')
    emit('GANG_STASH_NON_BOSS_BLOCKED', tostring(#state.opened == 0))

    state.opened = {}
    fireAs(4, 'qb-gangmenu:server:stash')
    emit('GANG_STASH_BOSS_OK', tostring(#state.opened == 1))

    -- 个人仓库：普通成员能开自己的
    state.opened = {}
    fireAs(5, 'qb-gangmenu:server:personalStash')
    emit('PERSONAL_STASH_OK', tostring(#state.opened == 1 and state.opened[1].stash:find('cartel_personal_', 1, true) ~= nil))
end

-- 无帮派的人没有个人仓库
state.players[6] = makePlayer(6, 'unemployed', false, 'none', false)
state.opened = {}
fireAs(6, 'qb-gangmenu:server:personalStash')
emit('PERSONAL_STASH_NO_GANG_BLOCKED', tostring(#state.opened == 0))

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
