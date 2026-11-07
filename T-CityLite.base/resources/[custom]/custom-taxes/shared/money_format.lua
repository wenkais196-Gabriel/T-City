-- money_format.lua — 金额渲染的唯一实现（custom-taxes 内部）
--
-- 为什么不用 `%d`：`('$%d'):format(0.5)` 在 Lua 5.4 直接抛
--   bad argument #1 to 'format' (number has no integer representation)
-- 而税是按比例算出来的（5% / 3% / 阶梯税率 × 地段系数），**必然带小数**。
-- 真机 2026-11-01 已经在 economy_service 的审计日志上炸过一次（钱进了账、日志没写）。
--
-- 语义：整数不带小数点（$500），小数保留两位（$61.75）。负数保留符号。

function TCMoney(value)
    local num = tonumber(value)
    if not num then return '0' end
    if num % 1 == 0 then
        return ('%d'):format(num)
    end
    return ('%.2f'):format(num)
end
