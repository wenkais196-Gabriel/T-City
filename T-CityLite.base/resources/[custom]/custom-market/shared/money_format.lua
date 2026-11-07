-- money_format.lua — 金额渲染（custom-market）
--
-- 为什么需要：`('%d'):format(x)` 在 x 是小数时直接抛
--   `bad argument #N to 'format' (number has no integer representation)`，
-- 而且往往是"钱已经到账、审计没写、调用方还收到错误"（真机 2026-11-01 在 economy_service 上撞过）。
-- 本资源里金额可能带小数（比例/乘算/客户端传入），所以统一走这里。
--
-- 语义：整数不带小数点（$500），小数保留两位（$61.75）。

function Money(value)
    local num = tonumber(value)
    if not num then return '0' end
    if num % 1 == 0 then
        return ('%d'):format(num)
    end
    return ('%.2f'):format(num)
end
