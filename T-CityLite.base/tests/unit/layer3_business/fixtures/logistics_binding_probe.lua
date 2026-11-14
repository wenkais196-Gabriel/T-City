-- logistics_binding_probe.lua — 真跑 quest_logistics_validators 里的绑定存储与关闭路径
--
-- 用 -- [quest-logistics-binding-store] / [quest-logistics-binding-api] 两个标记，
-- 从源码里抽出**真实实现**（不复制一份），只桩掉它依赖的外部符号。
--
-- 验收三件事（对应 2026-11-14 修的三个 bug）：
--   1. 押金按 stepData 记录，不再写死 0；
--   2. ClearLogisticsBinding 幂等（清两次不报错）；
--   3. ClearAllLogisticsBindings 断线整表清、返回清掉的条数。

local SOURCE = arg[1]
if not SOURCE then
    error('用法: lua5.4 logistics_binding_probe.lua <quest_logistics_validators.lua>')
end

local file = assert(io.open(SOURCE, 'r'))
local text = file:read('a')
file:close()

local function extract(name)
    local pattern = '%-%- %[' .. name .. '%] begin(.-)%-%- %[' .. name .. '%] end'
    local body = text:match(pattern)
    if not body then
        error('找不到标记块: ' .. name)
    end
    return body
end

local store = extract('quest%-logistics%-binding%-store')
local api = extract('quest%-logistics%-binding%-api')

-- 外部依赖桩
QuestManager = { FailQuest = function() end }
TriggerClientEvent = function() end
GetPlayers = function() return {} end
QBCore = { Functions = { GetPlayer = function() return nil end } }

-- setBinding / clearBinding 在源码里是 local，只能在同一个 chunk 内可见：
-- 拼接一段导出代码，把它们挂到全局上给探针用（不改变源码语义）。
local exporter = '\n_G.__probeSetBinding = setBinding\n_G.__probeClearBinding = clearBinding\n'
local chunk = assert(load(store .. '\n' .. api .. exporter, 'binding-store'))
chunk()
local setBinding = __probeSetBinding

local results = {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok, detail = detail or '' }
end

-- 1. 清一个不存在的绑定：幂等、不报错
local ok1 = pcall(ClearLogisticsBinding, 'cid-a', 'quest-a')
local ok2 = pcall(ClearLogisticsBinding, 'cid-a', 'quest-a')
check('clear_absent_is_idempotent', ok1 and ok2, tostring(ok1) .. '/' .. tostring(ok2))

-- 2. 断线整表清：空状态返回 0，不报错
local okEmpty, clearedEmpty = pcall(ClearAllLogisticsBindings, 'cid-a')
check('clear_all_empty_returns_zero', okEmpty and clearedEmpty == 0, tostring(clearedEmpty))

-- 3. 塞两条绑定后整表清，返回 2 且清空
setBinding('cid-b', 'quest-1', { plate = 'AAA111', netId = 1, isRental = true, rentalDeposit = 500, rentalFeePct = 20 })
setBinding('cid-b', 'quest-2', { plate = 'BBB222', netId = 2, isRental = true, rentalDeposit = 1200, rentalFeePct = 15 })
local okMany, clearedMany = pcall(ClearAllLogisticsBindings, 'cid-b')
local after = GetLogisticsBinding('cid-b', 'quest-1')
check('clear_all_counts_and_clears', okMany and clearedMany == 2 and after == nil,
    ('cleared=%s, after=%s'):format(tostring(clearedMany), tostring(after)))

-- 4. 只清一个任务，不动同一玩家的其他任务
setBinding('cid-c', 'quest-1', { plate = 'CCC333', netId = 3, isRental = true, rentalDeposit = 300, rentalFeePct = 20 })
setBinding('cid-c', 'quest-2', { plate = 'DDD444', netId = 4, isRental = true, rentalDeposit = 800, rentalFeePct = 20 })
ClearLogisticsBinding('cid-c', 'quest-1')
local kept = GetLogisticsBinding('cid-c', 'quest-2')
check('clear_one_keeps_siblings', kept ~= nil and kept.plate == 'DDD444',
    kept and kept.plate or 'nil')

-- 5. 押金字段能原样带出去（修复前恒为 0）
setBinding('cid-d', 'quest-1', { plate = 'EEE555', netId = 5, isRental = true, rentalDeposit = 1500, rentalFeePct = 20 })
local binding = GetLogisticsBinding('cid-d', 'quest-1')
check('deposit_survives_the_store', binding ~= nil and binding.rentalDeposit == 1500,
    binding and tostring(binding.rentalDeposit) or 'nil')

local failures = 0
for _, r in ipairs(results) do
    if not r.ok then failures = failures + 1 end
    print(('%-32s %s  %s'):format(r.name, r.ok and 'OK' or 'FAIL', r.detail))
end
print(('SUMMARY %d/%d'):format(#results - failures, #results))
os.exit(failures == 0 and 0 or 1)
