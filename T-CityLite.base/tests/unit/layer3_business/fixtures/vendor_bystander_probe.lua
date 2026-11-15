-- vendor_bystander_probe.lua — 真跑 quest_vendor_bridge.lua 的旁观者 payload 构造块
--
-- 只抽取 `-- [vendor-bystander] begin/end` 之间的代码，桩一个 QuestVendorBridge 表。
-- 断言（10 项）：
--   1. 返回表的键恰好是 isOwner / boothNetId / state / coords / items；
--   2. isOwner 必须显式为 false（买家客户端靠它区分“我的摊”与“别人的摊”）；
--   3. boothNetId / state / coords 是展示所需字段；
--   4. items 的每一项只有 quality / unitPrice 两个键；
--   5. items 只列有货档位，单价来自 session.cfg.prices；
--   6. 深扫返回值：没有 citizenid / 收入 / 库存 / 原料 / 已售 / 报价等摊主私有字段或值；
--   7. 打烊（session=nil）时 state=closed、items 为空。
--
-- 反向校验由 pytest 把 `citizenid` / `revenue` 塞进返回表后重跑本探针完成。
--
-- 用法:
--   lua5.4 vendor_bystander_probe.lua <quest_vendor_bridge.lua>

local SOURCE = arg[1]
if not SOURCE then
    error('用法: lua5.4 vendor_bystander_probe.lua <quest_vendor_bridge.lua>')
end

local file = assert(io.open(SOURCE, 'r'))
local text = file:read('a')
file:close()

local body = ('\n' .. text):match(
    '\r?\n%-%- %[vendor%-bystander%] begin\r?\n(.-)\r?\n%-%- %[vendor%-bystander%] end')
if not body then error('找不到标记块: vendor-bystander') end

-- ---------------------------------------------------------------------------
-- 沙箱：块里只允许依赖 QuestVendorBridge 与标准库
-- ---------------------------------------------------------------------------

QuestVendorBridge = {}
local env = {
    QuestVendorBridge = QuestVendorBridge,
    ipairs = ipairs,
    pairs = pairs,
    tonumber = tonumber,
    type = type,
}
local chunk = assert(load(body, '@vendor-bystander-block', 't', env))
chunk()

-- ---------------------------------------------------------------------------
-- 断言助手
-- ---------------------------------------------------------------------------

local checks, passed = 0, 0
local function check(name, ok, detail)
    checks = checks + 1
    if ok then
        passed = passed + 1
    else
        print(('FAIL %s: %s'):format(name, tostring(detail or '')))
    end
end

local function same_key_set(actual, expected)
    for key in pairs(expected) do
        if actual[key] == nil then return false end
    end
    for key in pairs(actual) do
        if expected[key] == nil then return false end
    end
    return true
end

local FORBIDDEN_KEYS = {
    citizenid = true,
    questId = true,
    stock = true,
    raw = true,
    sold = true,
    revenue = true,
    offers = true,
    deposit = true,
    cfg = true,
    prices = true,
    ownerCitizenid = true,
    ownerSource = true,
    owner_citizenid = true,
    owner_source = true,
}
local FORBIDDEN_VALUES = {
    ['cid-secret-001'] = true,
    [424242] = true,
    [171717] = true,
    [3333] = true,
}

local function deep_scan(value, path, problems)
    if type(value) ~= 'table' then
        if FORBIDDEN_VALUES[value] then
            problems[#problems + 1] = path .. '=' .. tostring(value)
        end
        return
    end
    for key, item in pairs(value) do
        if FORBIDDEN_KEYS[key] then
            problems[#problems + 1] = path .. '.' .. tostring(key)
        end
        deep_scan(item, path .. '.' .. tostring(key), problems)
    end
end

-- ---------------------------------------------------------------------------
-- 假数据：故意在会话里塞满摊主私有字段
-- ---------------------------------------------------------------------------

local booth = { netId = 777, x = 1.5, y = -2.5, z = 30.0 }
local session = {
    citizenid = 'cid-secret-001',
    questId = 'quest_hotdog',
    stock = { common = 2, rare = 0, exotic = 1 },
    raw = 171717,
    sold = 3333,
    revenue = 424242,
    offers = {
        ['cid-secret-001#1'] = { item = 'common', count = 1, unitPrice = 6 },
    },
    cfg = { prices = { common = 6, rare = 9, exotic = 14 } },
}

local payload = QuestVendorBridge.BuildBystanderPayload(booth, session, 'open')

check('payload_keys', same_key_set(payload, {
    isOwner = true, boothNetId = true, state = true, coords = true, items = true,
}), '实际键：' .. table.concat((function()
    local keys = {}
    for key in pairs(payload or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    return keys
end)(), ','))
check('payload_is_owner_false', payload.isOwner == false, tostring(payload.isOwner))
check('payload_booth_net_id', payload.boothNetId == 777, tostring(payload.boothNetId))
check('payload_state_open', payload.state == 'open', tostring(payload.state))
check('payload_coords', type(payload.coords) == 'table'
    and payload.coords.x == 1.5 and payload.coords.y == -2.5 and payload.coords.z == 30.0,
    tostring(payload.coords))

local itemKeysOk = type(payload.items) == 'table' and #payload.items == 2
local available, prices = {}, {}
if type(payload.items) == 'table' then
    for _, item in ipairs(payload.items) do
        if not same_key_set(item, { quality = true, unitPrice = true }) then
            itemKeysOk = false
        end
        if type(item) == 'table' then
            available[item.quality] = true
            prices[item.quality] = item.unitPrice
        end
    end
end
check('items_keys', itemKeysOk, 'items 的每一项只能有 quality / unitPrice')
check('items_available_only_in_stock',
    available.common == true and available.exotic == true and available.rare == nil,
    '实际：' .. tostring(available.common) .. '/'
    .. tostring(available.rare) .. '/' .. tostring(available.exotic))
check('items_unit_prices', prices.common == 6 and prices.exotic == 14,
    tostring(prices.common) .. '/' .. tostring(prices.exotic))

local leaks = {}
deep_scan(payload, 'payload', leaks)
check('no_owner_data', #leaks == 0, table.concat(leaks, ', '))

local closed = QuestVendorBridge.BuildBystanderPayload(booth, nil, 'closed')
check('closed_state_and_items', closed.state == 'closed'
    and type(closed.items) == 'table' and #closed.items == 0,
    tostring(closed.state) .. '/' .. tostring(closed.items and #closed.items))

print(('SUMMARY %d/%d'):format(passed, checks))
if passed ~= checks then
    os.exit(1)
end
