-- fixtures/industry_treasury_probe.lua — 组织金库的离线假数据库。
--
-- 用法（见 test_industry_treasury.py）：
--   load_with_db(FIXTURE.read_text(), treasury.lua, body)
-- 也就是本文件作为 stubs、后面接 core-framework/server/db.lua 与 treasury.lua。
--
-- 这里只实现 treasury.lua 会发出的那几条语句的语义。关键判据是 SQL 文本本身：
--
--   * UPDATE 里**带** `balance + ? >= 0` 才按余额守卫执行；删掉守卫的版本会
--     变成无守卫更新，余额不足用例必须因此变红。
--   * 流水唯一性由 `__uniqueRef` 控制。测试从迁移文件里读 UNIQUE KEY 是否存在，
--     再设置这个开关 —— 迁移删掉唯一键时，幂等用例必须真的变红，而不是靠桩假装。
--   * `__race` 是一个只在第一次 org_treasury UPDATE 前触发的回调，用来制造
--     「A 已经做出判断、还没落库时 B 插进来」的 TOCTOU 交错。

__orgs = {}
__ledger = {}
__refs = {}
__uniqueRef = true
__nextLedgerId = 0
__failLedgerInsert = false
__opaqueInsertError = false
__race = nil
__raceFired = false
__calls = { update = 0, single = 0, insert = 0, query = 0 }
__lastQuerySql = nil

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
end

function __seed(orgId, balance)
    __orgs[orgId] = balance
end

function __balance(orgId)
    return __orgs[orgId]
end

function __ledgerCount()
    return #__ledger
end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end

local function ledgerRef(values)
    -- 有 actor：{ org, delta, balance_after, reason, actor, ref, cycle } → 6
    -- 无 actor：SQL 里 actor_cid 是 NULL，参数只有 6 个              → 5
    if #values == 7 then return values[6] end
    return values[5]
end

MySQL = {}

MySQL.update = { await = function(sql, values)
    __calls.update = __calls.update + 1
    if not sql:find('org_treasury', 1, true) then
        return { affectedRows = 0 }
    end

    local delta = tonumber(values[1]) or 0
    local orgId = values[2]
    local guarded = sql:find('balance + ? >= 0', 1, true) ~= nil

    -- 交错点必须在「读余额 / 判断」之后、真正写余额之前。
    if __race and not __raceFired then
        __raceFired = true
        local hook = __race
        __race = nil
        hook()
    end

    if __orgs[orgId] == nil then return { affectedRows = 0 } end
    if guarded and (__orgs[orgId] + delta) < 0 then
        return { affectedRows = 0 }
    end

    __orgs[orgId] = __orgs[orgId] + delta
    return { affectedRows = 1 }
end }

MySQL.single = { await = function(sql, values)
    __calls.single = __calls.single + 1
    if sql:find('org_treasury', 1, true) then
        local orgId = values[1]
        if __orgs[orgId] == nil then return nil end
        return { balance = __orgs[orgId] }
    end
    if sql:find('org_ledger', 1, true) then
        local orgId = tostring(values[1])
        local ref = tostring(values[2])
        if __refs[orgId .. '\0' .. ref] then return { id = 1 } end
        return nil
    end
    return nil
end }

MySQL.query = { await = function(sql, values)
    __calls.query = __calls.query + 1
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

    if sql:find('org_ledger', 1, true) then
        local orgId = values[1]
        local ref = tostring(ledgerRef(values))
        local key = orgId .. '\0' .. ref

        if __opaqueInsertError then
            -- 模拟「驱动把 SQL 错误当字符串回包」：db.lua 会把它归一化成
            -- db_error，唯一键冲突的原文因此丢失。
            return 'probe: opaque driver error'
        end
        if __uniqueRef and __refs[key] then
            error("Duplicate entry '" .. ref .. "' for key 'org_ledger.uniq_org_ref'")
        end
        if __failLedgerInsert then
            error('probe: forced ledger insert failure')
        end

        __refs[key] = true
        __nextLedgerId = __nextLedgerId + 1
        __ledger[#__ledger + 1] = {
            id = __nextLedgerId,
            org_id = orgId,
            delta = values[2],
            balance_after = values[3],
            reason = values[4],
            ref = ref,
        }
        return { insertId = __nextLedgerId }
    end

    if sql:find('industry_audit', 1, true) then
        __nextLedgerId = __nextLedgerId + 1
        return { insertId = __nextLedgerId }
    end

    return { insertId = 0 }
end }

MySQL.scalar = { await = function() return 0 end }
MySQL.execute = { await = function() return 1 end }
