-- money_format.lua — 金额渲染（custom-phone）
--
-- 手机银行/任务板都会把金额拼进文案，而金额可能是小数：
--   * 转账允许小数（`%d` 遇 0.5 直接抛 `number has no integer representation`）；
--   * 任务奖励按 `scale`（如 0.85）乘算后再展示（jobboard 里 `%.2f` 就在旁边）。
--
-- 语义：整数不带小数点（$500），小数保留两位（$61.75）。
-- 与 custom-taxes 的同名实现一致；抽公共模块登记为 P2（见 P1-5 计划）。

function PhoneMoney(value)
    local num = tonumber(value)
    if not num then return '0' end
    if num % 1 == 0 then
        return ('%d'):format(num)
    end
    return ('%.2f'):format(num)
end
