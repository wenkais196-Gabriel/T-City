-- money_format.lua — 金额渲染门面（custom-quest）
-- 唯一实现：core-framework/shared/util.lua 的 FormatMoney（两端注册）。
-- S6 收口计划：本文件只转调 owner，不再保留实现体。
function QuestMoney(value)
    if GetResourceState('core-framework') ~= 'started' then return '0' end
    return exports['core-framework']:FormatMoney(value)
end
