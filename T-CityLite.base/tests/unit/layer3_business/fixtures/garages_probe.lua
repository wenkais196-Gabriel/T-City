-- tests/unit/layer3_business/fixtures/garages_probe.lua
-- 真加载 qb-garages 的 config.lua + server/main.lua，直接调用服务端回调/事件：
--   1) spawnvehicle：别人的车牌 / 车型不符 / 生成点太远 → 必须拒绝；正常 → 放行
--   2) syncGarage：非管理员不能覆盖全服车库配置
--   3) PayDepotPrice：不是自己的车 / 车没被扣押 → 不能取车

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = {
  coords = nil,
  spawned = {},
  garageTable = nil,
  dbRows = {},          -- plate → { citizenid, vehicle, state, depotprice, mods }
  permission = false,   -- HasPermission 返回
}

local player = {
  PlayerData = {
    source = 1,
    citizenid = 'TESTCID',
    license = 'LIC',
    metadata = { licences = {} },
    money = { cash = 10000, bank = 10000 },
    charinfo = { firstname = 'T', lastname = 'C' },
  },
  Functions = {
    RemoveMoney = function() return true end,
    GetItemByName = function() return nil end,
  },
}

local QBCoreMock = {
  Functions = {
    GetPlayer = function(source) return source == 1 and player or nil end,
    GetPlayerByCitizenId = function() return player end,
    HasPermission = function() return state.permission end,
    CreateCallback = function(name, fn) state.callbacks = state.callbacks or {}; state.callbacks[name] = fn end,
    GetDutyCount = function() return 0 end,
  },
  Shared = {
    Vehicles = setmetatable({}, { __index = function() return { category = 'sedan', type = 'automobile' } end }),
    Items = setmetatable({}, { __index = function(_, k) return { label = tostring(k) } end }),
  },
  Commands = { Add = function() end },
}

local handlers = {}
RegisterNetEvent = function(name, fn) handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function() end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
GetGameTimer = function() return 0 end
GetConvar = function(_, default) return default end
Lang = { t = function(a, b) local key = type(a) == 'string' and a or b; return tostring(key) end }
json = { encode = function() return '{}' end, decode = function() return {} end }
vector2 = function(x, y) return { x = x, y = y } end
local vectorMeta = {}
vectorMeta.__sub = function(a, b)
  return setmetatable({ x = (a.x or 0) - (b.x or 0), y = (a.y or 0) - (b.y or 0), z = (a.z or 0) - (b.z or 0) }, vectorMeta)
end
vectorMeta.__len = function(a) return math.sqrt((a.x or 0) ^ 2 + (a.y or 0) ^ 2 + (a.z or 0) ^ 2) end
local function vec3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vectorMeta) end
vector3 = vec3
vector4 = function(x, y, z, w)
  local value = vec3(x, y, z)
  value.w = w
  value.xyz = vec3(x, y, z)
  return value
end

GetPlayerPed = function() return 1 end
GetEntityCoords = function() return state.coords or vec3(0, 0, 0) end
CreateVehicleServerSetter = function(model)
  state.spawned[#state.spawned + 1] = model
  return 1000 + #state.spawned
end
NetworkGetNetworkIdFromEntity = function(entity) return 500 + (entity or 0) end
NetworkGetEntityFromNetworkId = function(netId) return netId end
DoesEntityExist = function(entity) return entity ~= nil and entity ~= 0 end
SetVehicleNumberPlateText = function() end

local function rowFor(plate)
  local row = state.dbRows[plate]
  if not row then return nil end
  return { citizenid = row.citizenid, vehicle = row.vehicle, state = row.state, depotprice = row.depotprice, mods = row.mods }
end

MySQL = {
  single = { await = function(_, params) return rowFor(params and params[1]) end },
  scalar = {
    await = function(sql, params)
      if type(sql) == 'string' and sql:find('COUNT', 1, true) then return 0 end
      local row = rowFor(params and params[1])
      if not row then return nil end
      if sql:find('depotprice', 1, true) then return row.depotprice end
      return row.citizenid
    end,
  },
  query = { await = function() return {} end },
  update = function() return 1 end,
  insert = function() return 1 end,
}

exports = setmetatable({}, {
  __call = function(_, name, fn) rawset(exports, name, fn) end,
  __index = function(_, name)
    if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
    if name == 'qb-houses' then return { hasKey = function() return true end } end
    return setmetatable({}, { __index = function() return function() return true end end })
  end,
})

local function load_lua(path, chunkname)
  local handle = assert(io.open(path, 'r'))
  local source = handle:read('a')
  handle:close()
  source = source:gsub('`([A-Z][A-Z0-9_]*)`', "GetHashKey('%1')")
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
  if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
  return ok
end

local function callCallback(name, src, ...)
  local fn = state.callbacks and state.callbacks[name]
  if not fn then error('callback 未注册: ' .. name) end
  local result = nil
  local packed = nil
  local function cb(...) packed = { ... } end
  local ok, err = pcall(fn, src, cb, ...)
  if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|' .. tostring(err) end
  return packed
end

state.coords = vec3(0.0, 0.0, 0.0)
state.dbRows['MINE'] = { citizenid = 'TESTCID', vehicle = 'adder', state = 1, depotprice = 0, mods = '{}' }
state.dbRows['OTHERS'] = { citizenid = 'OTHER', vehicle = 'adder', state = 1, depotprice = 0, mods = '{}' }
state.dbRows['IMPOUNDED'] = { citizenid = 'TESTCID', vehicle = 'adder', state = 2, depotprice = 500, mods = '{}' }
-- AutoRespawn = false 时 onResourceStart 给"在外"车辆标价（state 仍是 0）→ 也必须能赎
state.dbRows['PRICEONLY'] = { citizenid = 'TESTCID', vehicle = 'adder', state = 0, depotprice = 500, mods = '{}' }

-- ── 1. spawnvehicle：自己的车 / 正常坐标 → 放行 ──
emit('SCENARIO', 'spawn-own')
local out = callCallback('qb-garages:server:spawnvehicle', 1, 'MINE', 'adder', { x = 0.0, y = 0.0, z = 0.0, w = 0.0 })
emit('SPAWN_OK', tostring(out ~= nil and out[1] ~= nil))

-- ── 2. 别人的车牌 → 拒绝 ──
emit('SCENARIO', 'spawn-others-plate')
out = callCallback('qb-garages:server:spawnvehicle', 1, 'OTHERS', 'adder', { x = 0.0, y = 0.0, z = 0.0, w = 0.0 })
emit('SPAWN_OTHERS', tostring(out == nil or out[1] == nil))

-- ── 3. 车型不符（拿自己的车牌生成别的模型） → 拒绝 ──
emit('SCENARIO', 'spawn-model-mismatch')
out = callCallback('qb-garages:server:spawnvehicle', 1, 'MINE', 'jet', { x = 0.0, y = 0.0, z = 0.0, w = 0.0 })
emit('SPAWN_MISMATCH', tostring(out == nil or out[1] == nil))

-- ── 4. 生成点 5000 米外 → 拒绝 ──
emit('SCENARIO', 'spawn-far')
out = callCallback('qb-garages:server:spawnvehicle', 1, 'MINE', 'adder', { x = 5000.0, y = 5000.0, z = 0.0, w = 0.0 })
emit('SPAWN_FAR', tostring(out == nil or out[1] == nil))

-- ── 5. syncGarage：非管理员不能覆盖配置 ──
emit('SCENARIO', 'sync-garage')
local before = Config.Garages
fireAs(1, 'qb-garages:server:syncGarage', { hacked = true })
emit('SYNC_BLOCKED_FOR_PLAYER', tostring(Config.Garages ~= nil and Config.Garages.hacked == nil))
state.permission = true
fireAs(1, 'qb-garages:server:syncGarage', { hacked = true })
emit('SYNC_ALLOWED_FOR_ADMIN', tostring(Config.Garages ~= nil and Config.Garages.hacked == true))
Config.Garages = before

-- ── 6. PayDepotPrice：别人的车 / 未扣押 → 不取车 ──
emit('SCENARIO', 'depot')
local taken = 0
local originalTrigger = TriggerClientEvent
TriggerClientEvent = function(name)
  if name == 'qb-garages:client:takeOutGarage' then taken = taken + 1 end
end
fireAs(1, 'qb-garages:server:PayDepotPrice', { plate = 'OTHERS' })
emit('DEPOT_OTHERS', tostring(taken == 0))
fireAs(1, 'qb-garages:server:PayDepotPrice', { plate = 'MINE' })
emit('DEPOT_NOT_IMPOUNDED', tostring(taken == 0))
fireAs(1, 'qb-garages:server:PayDepotPrice', { plate = 'IMPOUNDED' })
emit('DEPOT_IMPOUNDED', tostring(taken == 1))
TriggerClientEvent = originalTrigger

-- ── 7. UpdateOutsideVehicle：登记 / 清空 / 别人的车牌 ──
emit('SCENARIO', 'outside')
local outsideHandler = handlers['qb-garages:server:UpdateOutsideVehicle']
local function outsideTable()
  for index = 1, 60 do
    local name, value = debug.getupvalue(outsideHandler, index)
    if not name then break end
    if name == 'OutsideVehicles' then return value end
  end
  return nil
end

fireAs(1, 'qb-garages:server:UpdateOutsideVehicle', 'MINE', 777)
emit('OUTSIDE_SET', tostring(outsideTable()['MINE'] ~= nil))
-- 存车时客户端传 nil：必须清掉，否则 IsSpawnOk 永远认为车在外面（存了就取不出来）
fireAs(1, 'qb-garages:server:UpdateOutsideVehicle', 'MINE', nil)
emit('OUTSIDE_CLEARED', tostring(outsideTable()['MINE'] == nil))
fireAs(1, 'qb-garages:server:UpdateOutsideVehicle', 'OTHERS', 778)
emit('OUTSIDE_OTHERS_BLOCKED', tostring(outsideTable()['OTHERS'] == nil))

-- ── 8. 只有 depotprice、state=0 的车也能赎（AutoRespawn=false 的口径） ──
emit('SCENARIO', 'depot-price-only')
taken = 0
TriggerClientEvent = function(name)
  if name == 'qb-garages:client:takeOutGarage' then taken = taken + 1 end
end
fireAs(1, 'qb-garages:server:PayDepotPrice', { plate = 'PRICEONLY' })
emit('DEPOT_PRICE_ONLY', tostring(taken == 1))
TriggerClientEvent = originalTrigger

emit('SCENARIO', 'done')
io.write(table.concat(OUT, '\n'), '\n')
