-- ============================================================================
-- i18n_server.lua — 服务端本地化引擎 v1.0
-- ============================================================================
-- 服务端 _L() 函数: 根据玩家的 client_lang 返回对应语言文本
-- 用法: _L(source, 'key', arg1, arg2)
--       _L(nil, 'key')  → 默认英文 (无玩家上下文时)
-- ============================================================================

-- ⚠️ 这个文件原来完全没取 core object：`QBCore` 在本资源里恒为 nil，
-- 于是「读玩家 client_lang」和「写玩家 client_lang」两条路都是死代码（服务端永远按 en 渲染）。
-- 这里显式取一次，`_L` 与下面的上报 handler 都用它。
local QBCore = exports['qb-core'] and exports['qb-core']:GetCoreObject() or nil

local localeData = nil

-- 加载语言包
local content = LoadResourceFile(GetCurrentResourceName(), 'locales/locales.lua')
if content then
    local ok, result = pcall(function() return load(content)() end)
    if ok and type(result) == 'table' then
        localeData = result
    end
end

if not localeData then
    localeData = {}
end

--- 服务端本地化 (根据玩家语言)
--- @param source number|nil 玩家 source (nil = 默认英文)
--- @param key string
--- @param ... any
function _L(source, key, ...)
    if not key then return '' end

    local entry = localeData[key]
    if not entry then
        local args = { ... }
        if #args > 0 then return ('[%s]'):format(key) .. ' ' .. table.concat(args, ', ') end
        return '[' .. key .. ']'
    end

    -- 检测玩家语言
    local lang = 'en'
    if source and tonumber(source) and QBCore then
        local Player = QBCore.Functions.GetPlayer(tonumber(source))
        local data = Player and Player.PlayerData
        if type(data) == 'table' and type(data.metadata) == 'table' then
            lang = data.metadata.client_lang or 'en'
        end
    end

    local text = entry[lang] or entry['en'] or ('[' .. key .. ']')
    local args = { ... }
    if #args > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
        return text
    end

    return text
end

-- 🔧 v0.9: 哨兵标记 — 防止 shared/server/client 重复定义 _L
_I18N_LOADED = true

-- 接收客户端语言上报
-- 语言代码只有语言包里存在的那几种（zh / en）。原来客户端传什么就写什么：
-- 表、5KB 字符串、任意伪造值都会直接落进 metadata.client_lang，服务端渲染时再拿它拼串。
local SUPPORTED_LANGS = { zh = true, en = true }

RegisterNetEvent('i18n:client:reportLanguage', function(lang)
    local src = source
    if type(lang) ~= 'string' or #lang > 5 then return end
    if not SUPPORTED_LANGS[lang] then return end
    if not (src and src > 0 and QBCore) then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 走 qb-core 的 SetMetaData：既只碰调用者自己，也保证投影/持久化与其它资源一致
    Player.Functions.SetMetaData('client_lang', lang)
end)

-- (生产模式静默: 服务端 i18n 引擎已激活)
