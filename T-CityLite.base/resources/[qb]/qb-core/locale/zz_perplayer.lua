-- ============================================================================
-- zz_perplayer.lua — 按玩家语言分流 QBCore Lang:t()
-- ============================================================================
-- 策略: _L 未就位时不插手 (用 QBCore 原生链); _L 就位后按玩家语言分流
-- ============================================================================

local OriginalLang = Lang  -- 启动时的原生链 (zh-tw → ... → en)

-- 找到英文包
local EnglishLang = OriginalLang
while EnglishLang.fallback and EnglishLang.fallback ~= false do
    EnglishLang = EnglishLang.fallback
end

Lang = setmetatable({}, {
    __index = function(_, k)
        if k == 't' then
            return function(self, key, subs)
                -- _L 没就位 → 完全不插手
                if not _L or type(_L) ~= 'function' then
                    return OriginalLang:t(key, subs)
                end
                -- 先查我们的翻译
                local lang = _L('_lang')
                if lang == 'en' or lang == 'zh' then
                    local tr = _L(nil, key)
                    if tr and type(tr) == 'string' and tr ~= ('[' .. key .. ']') then
                        if subs and type(subs) == 'table' then
                            for sk, sv in pairs(subs) do tr = tr:gsub('%%{' .. sk .. '}', tostring(sv)) end
                        end
                        return tr
                    end
                    if lang == 'en' then return EnglishLang:t(key, subs) end
                end
                return OriginalLang:t(key, subs)
            end
        end
        return OriginalLang[k]
    end
})
