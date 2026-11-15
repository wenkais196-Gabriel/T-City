-- tests/unit/layer3_business/fixtures/i18n_lang_probe.lua
-- 真加载 production-freeze 的 server/i18n_server.lua。
-- 重点：`i18n:client:reportLanguage` 只接受语言包里真实存在的语言代码。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local state = { metadata = {} }

-- handler 现在走 qb-core 的 API（GetPlayer + SetMetaData），不再直接摸 QBCore.Players
local player1 = {
    PlayerData = { source = 1, citizenid = 'CID1', metadata = state.metadata },
    Functions = {
        SetMetaData = function(key, value) state.metadata[key] = value end,
    },
}

local QBCoreMock = {
    Players = { [1] = player1 },
    Functions = { GetPlayer = function(source) if tonumber(source) == 1 then return player1 end return nil end,
                  CreateCallback = function() end },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) rawset(exports, name, fn) end,
    __index = function(_, name)
        if name == 'qb-core' then return { GetCoreObject = function() return QBCoreMock end } end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
})

QBCore = QBCoreMock

RegisterNetEvent = function(name, fn) state.handlers = state.handlers or {}; state.handlers[name] = fn end
RegisterServerEvent = RegisterNetEvent
AddEventHandler = function() end
CreateThread = function() end
Wait = function() end
GetCurrentResourceName = function() return 'production-freeze' end
LoadResourceFile = function(_, filename)
    local handle = io.open(RES .. '/' .. filename, 'r')
    if not handle then return nil end
    local content = handle:read('a')
    handle:close()
    return content
end

local function load_lua(path, chunkname)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. chunkname))()
end

load_lua(RES .. '/server/i18n_server.lua', 'server/i18n_server.lua')

local handler = assert(state.handlers['i18n:client:reportLanguage'], 'handler 未注册')

local function fire(src, lang)
    _G.source = src
    local ok, err = pcall(handler, lang)
    _G.source = nil
    if not ok then OUT[#OUT + 1] = 'HANDLER_ERROR|i18n:client:reportLanguage|' .. tostring(err) end
    return ok
end

-- ── 1. 合法语言代码落地 ──
for key in pairs(state.metadata) do state.metadata[key] = nil end   -- 原地清空（桩持有的是这张表）
fire(1, 'zh')
emit('LANG_ZH_ACCEPTED', tostring(state.metadata.client_lang == 'zh'))

for key in pairs(state.metadata) do state.metadata[key] = nil end
fire(1, 'en')
emit('LANG_EN_ACCEPTED', tostring(state.metadata.client_lang == 'en'))

-- ── 2. 伪造/超长/非字符串一律丢弃 ──
for key in pairs(state.metadata) do state.metadata[key] = nil end
local okTable = fire(1, {})
local okLong = fire(1, string.rep('z', 4000))
local okBogus = fire(1, 'xx')
local okNumber = fire(1, 12)
emit('LANG_BAD_VALUES_SAFE', tostring(okTable and okLong and okBogus and okNumber))
emit('LANG_BAD_VALUES_IGNORED', tostring(state.metadata.client_lang == nil))

-- 不在线的 source 直接忽略，不抛错
local okGhost = fire(999, 'zh')
emit('LANG_OFFLINE_SOURCE_SAFE', tostring(okGhost and state.metadata.client_lang ~= 'zh'))

emit('DONE', 'ok')
io.write(table.concat(OUT, '\n'), '\n')
