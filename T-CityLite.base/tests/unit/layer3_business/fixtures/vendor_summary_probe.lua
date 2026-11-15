-- vendor_summary_probe.lua — 真加载 quest_vendor / quest_vendor_bridge / quest_settle
--
-- 证明「摊主先收摊 → 任务完成」这条路径上 QuestSettle.Compute 拿到的 soldTotal 不是 0：
--   1. 开摊 → 卖出 → CloseFor（收摊）→ 汇总里有 sold / revenue
--   2. 完成路径第二次 CloseFor 拿不到活会话（nil）—— CloseFor 的返回值语义不能被改
--   3. TakeLastSummary 取回那份汇总，Compute 的 soldTotal > 0
--   4. 再取一次为 nil（一次性消费）→ 不会二次出账
--   5. 同一 citizenid 开新会话 / 超过 TTL 后缓存失效
--
-- 用法：lua5.4 vendor_summary_probe.lua <custom-quest 资源目录>

local RES = arg[1] or error('用法: lua5.4 vendor_summary_probe.lua <resource dir>')

-- ── FXServer 环境桩 ────────────────────────────────────────────────────────
local STATE = { now = 1000, handlers = {} }

function RegisterNetEvent(name, fn) STATE.handlers[name] = fn end
function RegisterServerEvent(name, fn) STATE.handlers[name] = fn end
function AddEventHandler() end
function CreateThread() end          -- StartTick 的循环不在离线探针里跑
function Wait() end
function TriggerClientEvent() end
function TriggerEvent() end
function GetGameTimer() return STATE.now end
function GetPlayers() return {} end
function GetPlayerPed(src) return src end
function GetEntityCoords() return { x = 0.0, y = 0.0, z = 0.0 } end
function vector3(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end

local CID = 'cid-summary'
local OTHER = 'cid-other'
local PAID = 0
local player = {
    PlayerData = { citizenid = CID, source = 7, money = { cash = 1000 } },
    Functions = {
        AddMoney = function(self, account, amount)
            PAID = PAID + (tonumber(amount) or 0)
            return true
        end,
    },
}
exports = {
    ['qb-core'] = {
        GetPlayerByCitizenId = function(self, cid) return cid == CID and player or nil end,
        GetPlayer = function(self, src) return tonumber(src) == 7 and player or nil end,
    },
}

-- ── 载入真实实现（不复制逻辑） ──────────────────────────────────────────────
local function load_lua(path, name)
    local handle = assert(io.open(path, 'r'))
    local source = handle:read('a')
    handle:close()
    assert(load(source, '@' .. name))()
end

load_lua(RES .. '/server/quest_vendor.lua', 'quest_vendor.lua')
load_lua(RES .. '/server/quest_settle.lua', 'quest_settle.lua')
load_lua(RES .. '/server/quest_vendor_bridge.lua', 'quest_vendor_bridge.lua')

-- ── 断言脚手架 ──────────────────────────────────────────────────────────────
local results = {}
local function check(name, condition, detail)
    results[#results + 1] = { name = name, ok = condition and true or false }
    print(('%s %s%s'):format(condition and 'OK  ' or 'FAIL', name,
        detail ~= nil and (' — ' .. tostring(detail)) or ''))
end

local PRICES = { common = 6, rare = 9, exotic = 14 }

--- 开摊 → 放库存 → 玩家买走 count 份（走内核 Purchase，钱只进摊主现金）。
local function openAndSell(questId, count)
    local ok, err = QuestVendorBridge.OpenFor(7, CID, questId, 4242, { prices = PRICES })
    assert(ok, 'OpenFor 失败: ' .. tostring(err))
    assert(QuestVendor.AddStock(CID, 'common', 3))
    local bought, buyErr = QuestVendor.Purchase(CID, 'common', count)
    assert(bought, 'Purchase 失败: ' .. tostring(buyErr))
end

local function rowOf(receipt, id)
    for _, row in ipairs(receipt.rows) do
        if row.id == id then return row end
    end
    return nil
end

check('CACHE_API_EXISTS', type(QuestVendorBridge.TakeLastSummary) == 'function',
    type(QuestVendorBridge.TakeLastSummary))

-- 1) 收摊 → 任务完成：第二次 CloseFor 没有会话，但缓存里还有售出汇总
openAndSell('quest_hotdog', 2)
local summary = QuestVendorBridge.CloseFor(CID, 'quest_hotdog', 'closed_by_player')
check('CLOSE_RETURNS_SUMMARY', summary ~= nil and (summary.revenue or 0) > 0,
    summary and summary.revenue or 'nil')
check('CLOSE_SUMMARY_SOLD', summary ~= nil and summary.sold == 2, summary and summary.sold or 'nil')

local secondClose = QuestVendorBridge.CloseFor(CID, 'quest_hotdog', 'completed')
check('SECOND_CLOSE_IS_NIL', secondClose == nil, tostring(secondClose))

local cached = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_hotdog') or nil
check('TAKE_RETURNS_CACHE', cached ~= nil and cached.revenue == summary.revenue,
    cached and cached.revenue or 'nil')

local receipt = QuestSettle.Compute({
    depositRefund = 250, rent = 36,
    soldTotal = cached and cached.revenue or 0,
    leftover = cached and cached.stock or nil,
    prices = PRICES,
    raw = cached and cached.raw or 0,
    taxRate = 0,
})
check('COMPUTE_SOLD_TOTAL_NONZERO', receipt.soldTotal > 0, receipt.soldTotal)
check('COMPUTE_SOLD_ROW_NONZERO', (rowOf(receipt, 'sold') or {}).amount == receipt.soldTotal,
    (rowOf(receipt, 'sold') or {}).amount)

-- 2) 一次性消费：再取一次必须是 nil，账单 soldTotal 回到 0（不会二次出账）
local again = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_hotdog') or nil
check('TAKE_IS_ONE_SHOT', again == nil, tostring(again))
local empty = QuestSettle.Compute({ soldTotal = again and again.revenue or 0, taxRate = 0 })
check('NO_DOUBLE_SETTLE', empty.soldTotal == 0, empty.soldTotal)

-- 3) 同一 citizenid 开新会话：上一班的汇总必须作废
openAndSell('quest_hotdog', 1)
QuestVendorBridge.CloseFor(CID, 'quest_hotdog', 'closed_by_player')
local reopened = QuestVendorBridge.OpenFor(7, CID, 'quest_hotdog', 4243, { prices = PRICES })
check('REOPEN_OK', reopened == true, tostring(reopened))
local afterReopen = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_hotdog') or nil
check('NEW_SESSION_CLEARS_CACHE', afterReopen == nil, tostring(afterReopen))
QuestVendorBridge.CloseFor(CID, 'quest_hotdog', 'closed_by_player')
-- 清掉这次收摊留下的缓存，避免干扰下一节
if type(QuestVendorBridge.TakeLastSummary) == 'function' then
    QuestVendorBridge.TakeLastSummary(CID, 'quest_hotdog')
end

-- 4) 过期：超过 TTL 的缓存不能再结算
openAndSell('quest_hotdog', 1)
QuestVendorBridge.CloseFor(CID, 'quest_hotdog', 'closed_by_player')
STATE.now = STATE.now + 24 * 60 * 60 * 1000
local expired = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_hotdog') or nil
check('TTL_EXPIRES_CACHE', expired == nil, tostring(expired))

-- 5) questId 不匹配：不能把 A 任务的汇总结算到 B 任务上，也不能误删 A 的缓存
openAndSell('quest_a', 1)
QuestVendorBridge.CloseFor(CID, 'quest_a', 'closed_by_player')
local wrongQuest = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_b') or nil
check('WRONG_QUEST_IS_NIL', wrongQuest == nil, tostring(wrongQuest))
local rightQuest = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_a') or nil
check('MISMATCH_DOES_NOT_CONSUME', rightQuest ~= nil and (rightQuest.revenue or 0) > 0,
    rightQuest and rightQuest.revenue or 'nil')
local afterRight = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_a') or nil
check('RIGHT_QUEST_CONSUMED', afterRight == nil, tostring(afterRight))

-- 6) 按 citizenid 隔离：别人的缓存不能被取走
local openedOther = QuestVendorBridge.OpenFor(8, OTHER, 'quest_hotdog', 4244, { prices = PRICES })
assert(openedOther, '给 OTHER 开摊失败')
QuestVendorBridge.CloseFor(OTHER, 'quest_hotdog', 'closed_by_player')
local otherRead = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(CID, 'quest_hotdog') or nil
check('CITIZEN_ISOLATED', otherRead == nil, tostring(otherRead))
local otherIntact = type(QuestVendorBridge.TakeLastSummary) == 'function'
    and QuestVendorBridge.TakeLastSummary(OTHER, 'quest_hotdog') or nil
check('OTHER_CITIZEN_CACHE_INTACT', otherIntact ~= nil, tostring(otherIntact))

-- ── 汇总 ────────────────────────────────────────────────────────────────────
local passed = 0
for _, r in ipairs(results) do if r.ok then passed = passed + 1 end end
print(('SUMMARY %d/%d'):format(passed, #results))
os.exit(passed == #results and 0 or 1)
