-- ============================================================================
-- i18n_server.lua — 服务端本地化引擎 v1.0
-- ============================================================================
-- 服务端 _L() 函数: 根据玩家的 client_lang 返回对应语言文本
-- 用法: _L(source, 'key', arg1, arg2)
--       _L(nil, 'key')  → 默认英文 (无玩家上下文时)
-- ============================================================================

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
    if source and tonumber(source) and QBCore and QBCore.Players then
        local Player = QBCore.Players[tonumber(source)]
        if Player and Player.PlayerData and Player.PlayerData.metadata then
            lang = Player.PlayerData.metadata.client_lang or 'en'
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
RegisterNetEvent('i18n:client:reportLanguage', function(lang)
    local src = source
    if src and src > 0 and QBCore and QBCore.Players and QBCore.Players[src] then
        if not QBCore.Players[src].PlayerData.metadata then
            QBCore.Players[src].PlayerData.metadata = {}
        end
        QBCore.Players[src].PlayerData.metadata.client_lang = lang
    end
end)

-- (生产模式静默: 服务端 i18n 引擎已激活)
