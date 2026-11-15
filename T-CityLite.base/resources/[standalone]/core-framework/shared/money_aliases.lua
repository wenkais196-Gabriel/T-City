-- shared/money_aliases.lua — 金额格式化的**别名**（实现只有一处：shared/util.lua 的 FormatMoney）
--
-- 为什么是一个文件而不是每个资源一份门面：8 份门面逐行相同，Sonar 会把它们算成新代码重复；
-- 而这些名字只是历史调用点的引用面（Money/PhoneMoney/QuestMoney/TCMoney），别名集中定义一次，
-- 资源各自 include 即可。
--
-- 用法：资源 fxmanifest 的 shared_scripts（或 client/server_scripts）里
--   '@core-framework/shared/money_aliases.lua'
-- 与 '@core-framework/shared/util.lua' 一起加载（util.lua 必须在前面）。

local function alias(value)
    if GetResourceState('core-framework') ~= 'started' then return '0' end
    return exports['core-framework']:FormatMoney(value)
end

function Money(value) return alias(value) end
function PhoneMoney(value) return alias(value) end
function QuestMoney(value) return alias(value) end
function TCMoney(value) return alias(value) end
