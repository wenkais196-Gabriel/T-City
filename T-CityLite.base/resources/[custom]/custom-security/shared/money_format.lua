-- money_format.lua — 金额渲染门面（custom-security）
-- 唯一实现：core-framework/shared/util.lua 的 FormatMoney（两端注册）。
function Money(value)
    if GetResourceState('core-framework') ~= 'started' then return '0' end
    return exports['core-framework']:FormatMoney(value)
end
