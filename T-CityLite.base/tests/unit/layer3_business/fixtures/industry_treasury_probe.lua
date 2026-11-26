-- fixtures/industry_treasury_probe.lua — 组织金库的离线假数据库。
--
-- 用法（见 test_industry_treasury.py）：
--   load_with_db(FIXTURE.read_text(), treasury.lua, body)
-- 也就是本文件作为 stubs、后面接 core-framework/server/db.lua 与 treasury.lua。
--
-- SQL 求值规则在 industry_probe_common.lua（余额守卫 / 流水唯一键 / affectedRows）。
-- 本文件只保留 S1 特有的判据与注入点：
--
--   * `__uniqueRef` 由迁移文件里的 UNIQUE KEY 是否存在决定。删掉唯一键时，
--     幂等用例必须真的变红，而不是靠桩假装。
--   * `__race` 是一个只在第一次 org_treasury UPDATE 前触发的回调，用来制造
--     「A 已经做出判断、还没落库时 B 插进来」的 TOCTOU 交错。
--   * `__opaqueInsertError` / `__failLedgerInsert` 模拟驱动错误与写流水失败。

-- 迁移里有没有 UNIQUE KEY 由 harness 在用例前决定（这是唯一不随 reset 变的开关）。
__uniqueRef = true

function __reset()
    __orgs = {}
    __ledger = {}
    __refs = {}
    __nextLedgerId = 0
    __failLedgerInsert = false
    __opaqueInsertError = false
    __race = nil
    __raceFired = false
    __calls = { update = 0, single = 0, insert = 0, query = 0 }
    __lastQuerySql = nil
    __sqlLog = {}
    __audits = {}
end

-- 初始状态与 reset 共用一份赋值（避免模块级初始化块再抄一遍）。
__reset()

MySQL = {}

MySQL.update = { await = function(sql, values)
    __calls.update = __calls.update + 1
    __industryLogSql('update', sql)
    return __industryUpdate(sql, values) or { affectedRows = 0 }
end }

MySQL.single = { await = function(sql, values)
    __calls.single = __calls.single + 1
    __industryLogSql('single', sql)
    return __industrySingle(sql, values)
end }

MySQL.query = { await = function(sql, values)
    __calls.query = __calls.query + 1
    __industryLogSql('query', sql)
    __lastQuerySql = sql
    if sql:find('org_ledger', 1, true) then
        local orgId = values[1]
        local limit = tonumber(values[2]) or 20
        local rows = {}
        for index = #__ledger, 1, -1 do
            if __ledger[index].org_id == orgId then
                rows[#rows + 1] = __ledger[index]
                if #rows >= limit then break end
            end
        end
        return rows
    end
    return {}
end }

MySQL.insert = { await = function(sql, values)
    __calls.insert = __calls.insert + 1
    __industryLogSql('insert', sql)
    return __industryInsert(sql, values) or { insertId = 0 }
end }

__industryMysqlTail()
