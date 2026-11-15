-- 热狗模板数值探针（供 tests/architecture/test_hotdog_test_numbers.py 使用）
--
-- 为什么是文件而不是 root/python 里的 `-e`：Windows 上用 `-e` 传多行代码，子进程会挂在 stdin 上。
-- 仓库里其它探针（vendor_summary_probe / vendor_bystander_probe）也都是文件 + 路径参数。
--
-- 用法：lua5.4 lua hotdog_numbers_probe.lua <quest_hotdog.lua 的路径>
-- 输出：一行 15 个数字，空格分隔，顺序见 test_hotdog_test_numbers.py 的 KEYS

-- 模板文件带 convar 开关（默认返回 {}），这里打开再取表
GetConvar = function(_, _) return '1' end

local path = assert(..., '需要模板文件路径')
local chunk = assert(loadfile(path))
local ok, templates = pcall(chunk)
assert(ok, tostring(templates))

local template
for _, candidate in ipairs(templates or {}) do
    if type(candidate) == 'table' and candidate.id == 'hotdog_dev_rental' then template = candidate end
end
assert(template, '模板里没有 hotdog_dev_rental')

local rental, vendor
for _, step in ipairs(template.steps or {}) do
    if step.type == 'rental' then rental = step.data.validator_data end
    if step.type == 'booth' then vendor = step.data.vendor end
end
assert(rental and vendor, '模板里找不到 rental / booth 的参数')

local function n(value)
    return string.format('%.17g', assert(tonumber(value), '数值字段缺失或不是数字'))
end

print(table.concat({
    n(rental.deposit), n(rental.rate_per_min), n(rental.grace_sec), n(rental.max_minutes),
    n(vendor.prices.common), n(vendor.prices.rare), n(vendor.prices.exotic),
    n(vendor.first_customer_ms[1]), n(vendor.first_customer_ms[2]),
    n(vendor.interval_ms[1]), n(vendor.interval_ms[2]), n(vendor.patience_ms),
    n(vendor.starting_stock.common), n(vendor.starting_stock.rare), n(vendor.starting_stock.exotic),
}, ' '))
