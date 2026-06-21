-- ============================================================================
-- i18n.lua — 动态中英文自适应引擎 v1.0
-- ============================================================================
-- 检测: GetCurrentLanguage() == 12 → zh-CN, 其余 → en (兜底)
-- 用法: _L('key')              → '完成任务'
--       _L('key', 100, 'item') → '获得: item ×100'
-- 零延迟: 语言包在资源启动时一次性加载到内存, 不重复解析
-- ============================================================================

-- 🔒 生产模式 + 客户端静默: 无条件劫持 _G.print, 只留 ERROR/SECURITY/玩家事件
_G.PRODUCTION_MODE = true
do
    local _raw = _G.print
    _G.print = function(...)
        local m = tostring(select(1, ...) or '')
        if m:match('%[ERROR%]') or m:match('%[SECURITY%]') or m:match('%[WARNING%]')
            or m:match('无敌保护') or m:match('OnPlayerLoaded')
            or m:match('%[i18n%]') then
            return _raw(...)
        end
    end
end

-- ── 语言包加载 ────────────────────────────────────────────────────────

local localeData = nil
local currentLang = 'en'

-- 加载语言包文件
local content = LoadResourceFile(GetCurrentResourceName(), 'locales/locales.lua')
if content then
    local ok, result = pcall(function() return load(content)() end)
    if ok and type(result) == 'table' then
        localeData = result
    end
end

if not localeData then
    -- 语言包加载失败 → 降到纯英文硬兜底 (永远不会返回 nil)
    print('[i18n] ⚠️ Failed to load locales/locales.lua — using empty fallback')
    localeData = {}
end

-- ── 语言检测 ──────────────────────────────────────────────────────────

local function detectLanguage()
    -- GTA5 原生 API: GetCurrentLanguage() 返回值
    -- 0 = American, 1 = French, 2 = German, 3 = Italian,
    -- 4 = Spanish, 5 = Brazilian, 6 = Polish, 7 = Russian,
    -- 8 = Korean, 9 = Chinese Traditional, 10 = Japanese,
    -- 11 = Mexican, 12 = Chinese Simplified
    local langId = GetCurrentLanguage()

    if langId == 12 or langId == 9 then
        -- 简体中文 (12) 或 繁体中文 (9) → 默认走中文
        return 'zh'
    end

    -- 也检查 Convar (某些服务器可能覆盖)
    local convarLocale = GetConvar('locale', '')
    if convarLocale:match('zh') then
        return 'zh'
    end

    return 'en'
end

-- 初始化: 立即检测
currentLang = detectLanguage()

-- ── 全局翻译函数 _L ───────────────────────────────────────────────────

--- 获取本地化文本
--- @param key string 语言键
--- @param ... any 格式化参数 (传给 string.format)
--- @return string
_G._L = function(key, ...)
    if not key then return '' end

    -- 查找语言包条目
    local entry = localeData[key]
    if not entry then
        -- 未找到 → 返回 key 本身 (开发者友好,不会出 nil)
        local args = { ... }
        if #args > 0 then
            return ('[%s]'):format(key) .. ' ' .. table.concat(args, ', ')
        end
        return '[' .. key .. ']'
    end

    -- 获取当前语言的文本
    local text = entry[currentLang] or entry['en'] or ('[' .. key .. ']')
    if type(text) ~= 'string' then
        return '[' .. key .. ']'
    end

    -- 格式化参数
    local args = { ... }
    if #args > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then
            return formatted
        end
        -- 格式化失败 → 返回原始文本 + 参数
        return text .. ' (' .. table.concat(args, ', ') .. ')'
    end

    return text
end

-- 🔧 v0.9: 哨兵标记 — 防止 shared/server/client 重复定义 _L
_I18N_LOADED = true

-- ── 服务端注册 (供服务端脚本使用 _L) ──────────────────────────────────

-- 客户端语言检测结果同步到服务端
RegisterNetEvent('i18n:client:reportLanguage', function(lang)
    -- 服务端记录 (用于服务端发送本地化通知)
    local src = source
    if src and src > 0 then
        -- 将语言存储到玩家 metadata 或临时表
        if QBCore and QBCore.Players and QBCore.Players[src] then
            QBCore.Players[src].PlayerData.metadata.client_lang = lang
        end
    end
end)

-- 玩家加载完成后上报语言
AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('i18n:client:reportLanguage', currentLang)
end)

-- ── 初始化输出 ────────────────────────────────────────────────────────

local keyCount = 0
if localeData then for _ in pairs(localeData) do keyCount = keyCount + 1 end end

print(('[i18n] %s | Keys: %d | %s'):format(
    currentLang:upper(), keyCount,
    currentLang == 'zh' and '简体中文' or 'English'))
