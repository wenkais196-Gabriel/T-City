-- money_format.lua — 金额渲染（custom-quest）
--
-- 任务奖励是**乘算**出来的：基础收益 × 时效修正 × 货物修正 × 自有车抽成，
-- 任何一环带比例就是小数。`('$%d'):format(0.5)` 在 Lua 5.4 直接抛
-- `bad argument #1 to 'format' (number has no integer representation)`。
--
-- 语义：整数不带小数点（$500），小数保留两位（$61.75）。
-- 与 custom-taxes / custom-phone 的同名实现一致；抽公共模块登记为 P2（见 P1-5 计划）。

function QuestMoney(value)
    local num = tonumber(value)
    if not num then return '0' end
    if num % 1 == 0 then
        return ('%d'):format(num)
    end
    return ('%.2f'):format(num)
end
