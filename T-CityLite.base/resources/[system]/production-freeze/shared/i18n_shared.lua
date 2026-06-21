-- ============================================================================
-- shared/i18n_shared.lua — _L() for shared_scripts + server compatible
-- ============================================================================
-- 在 shared_scripts 的 Lua 状态里定义 _L()
-- 兼容两种调用: _L(key, ...)    (客户端)
--              _L(source, key, ...)  (服务端, source 可 nil)
-- 不覆写已存在的 _L (server_scripts 版本的优先级更高)
-- ============================================================================

-- 🔧 v0.9 fix: 用模块级哨兵 _I18N_LOADED 替代函数属性 _L._hasLocale
-- FiveM lua54 运行时禁止在函数对象上直接设属性 (attempt to index a function value)
-- 旧的 `_L._hasLocale` 模式在 shared/server/client 三处均会崩溃
if _I18N_LOADED then return end

local localeData = nil
local currentLang = 'en'

local content = LoadResourceFile(GetCurrentResourceName(), 'locales/locales.lua')
if content then
    local ok, result = pcall(function() return load(content)() end)
    if ok and type(result) == 'table' then localeData = result end
end
if not localeData then localeData = {} end

local langId = 0  -- default English (FiveM lang 0 = en-US; only override to zh when GetCurrentLanguage returns 12/9)
if GetCurrentLanguage then langId = GetCurrentLanguage() end
if langId == 12 or langId == 9 then currentLang = 'zh' end

function _L(a1, a2, ...)
    -- 兼容两种签名: _L(key, ...) 或 _L(source, key, ...)
    local source, key
    if type(a1) == 'number' or a1 == nil then
        source, key = a1, a2
    else
        source, key = nil, a1
    end

    if not key then return '' end
    local entry = localeData[key]
    if not entry then return '[' .. key .. ']' end
    local text = entry[currentLang] or entry['en'] or ('[' .. key .. ']')
    if type(text) ~= 'string' then return '[' .. key .. ']' end
    local args = {...}
    if #args > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
        return text
    end
    return text
end

-- 🔧 v0.9: 哨兵标记 — 防止 shared/server/client 重复定义 _L
_I18N_LOADED = true
