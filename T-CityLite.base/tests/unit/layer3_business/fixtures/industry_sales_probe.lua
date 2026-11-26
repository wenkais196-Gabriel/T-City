-- fixtures/industry_sales_probe.lua — S4 销售 / 配额的离线假数据库。
--
-- 用法（见 test_industry_sales.py）：
--   fixture 作为 stubs → core-framework/server/db.lua → config* → treasury.lua
--   → audit.lua → sale.lua → body
--
-- SQL 求值规则在 industry_probe_common.lua（库存守卫 / 配额截断 / 唯一键 /
-- affectedRows）。本文件只保留 S4 特有的判据与注入点：
--
--   * 扣库存必须是 `SET stock = stock - ? ... AND stock >= ?`；少掉守卫就变成
--     无守卫扣减 —— 公共层会直接报错。
--   * 扣配额必须是 `quota_used + ? <= quota_total`，并且带
--     `SUM(s.qty) ... FLOOR(quota_total * ?)` 的本组织 50% 子查询。探针按
--     SQL 里是否出现 `SUM(s.qty)` 决定要不要执行「本组织累计」判据 ——
--     反向注入删掉这段条件时，第二家组织会真的卖出去，用例必须红。
--   * industry_sales 的 UNIQUE(org_id, ref) 由 `__saleRefs` 模拟。
--   * `__failTreasuryUpdate` 让 Treasury.Deposit 的第一步 UPDATE 失败，
--     用来验证「Deposit 失败 → 库存与配额都退回」。
--   * `__raceBeforeStockUpdate` 在第一次扣库存落库前触发一次，制造 await 交错。
--   * `__seedPrestige(orgId, points)` 种 S8 的 `org_treasury.prestige` 读取路径。
--
-- 事件：`TriggerEvent('industry:sale', ...)` 被记进 __saleEvents（已入账才发）。

__convars = {}

function __reset()
    __orgs = {}
    __prestige = {}
    __ledger = {}
    __ledgerRefs = {}
    __sales = {}
    __saleRefs = {}
    __nextSaleId = 0
    __nextLedgerId = 0
    __demands = {}
    __facilities = {}
    __audits = {}
    __saleEvents = {}
    __sqlLog = {}
    __globalMultiplier = 1.0
    __activityHeat = 1.0
    __failTreasuryUpdate = false
    __raceBeforeStockUpdate = nil
    __raceFired = false
end

-- 初始状态与 reset 共用一份赋值（避免模块级初始化块再抄一遍）。
__reset()

--- S8：org_treasury.prestige（永久加成读取路径）。
function __seedPrestige(orgId, points)
    __prestige[orgId] = tonumber(points) or 0
end

-- 构造器来自 industry_probe_common.lua（industry_harness 负责注入）。
function __seedDemand(item, total, used, cycleNo, phase)
    local cycle = cycleNo or 0
    local stage = phase or 'static'
    __demands[__industryDemandKey(cycle, stage, item)] =
        __industryDemandRow(cycle, stage, item, total, used)
end

function __demandRow(item, cycleNo, phase)
    local row = __demands[__industryDemandKey(cycleNo or 0, phase or 'static', item)]
    if not row then return nil end
    return __industryCopy(row)
end

--- S4 的设施状态是「库存数字」，不是整行。
function __seedFacility(orgId, stock)
    __facilities[orgId] = tonumber(stock) or 0
end

function __saleEventCount()
    return #__saleEvents
end

function __lastSaleEvent()
    return __saleEvents[#__saleEvents]
end

exports = __industryExports()

MySQL = {}

MySQL.update = { await = function(sql, values)
    __industryLogSql('update', sql)
    return __industryUpdate(sql, values) or { affectedRows = 0 }
end }

MySQL.single = { await = function(sql, values)
    __industryLogSql('single', sql)
    return __industrySingle(sql, values, { facility = 'basic' })
end }

MySQL.query = { await = function(sql)
    __industryLogSql('query', sql)
    return {}
end }

MySQL.insert = { await = function(sql, values)
    __industryLogSql('insert', sql)
    return __industryInsert(sql, values) or { insertId = 0 }
end }

__industryMysqlTail()
