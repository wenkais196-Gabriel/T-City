-- fixtures/industry_facility_probe.lua — 在 S1 假 DB（industry_treasury_probe.lua）
-- 之上补 industry_facility。测试里两段文本按顺序拼接成一个 stubs 块。
--
-- 这里只模拟 facility.lua 会发出的 SQL 语义：
--   * UPDATE 的 `workstations < ?` 存在时才执行上限守卫；
--   * 乐观锁 `workstations = ?` 用读到的旧值比较；
--   * INSERT 撞 PK 时抛 Duplicate（Db.Insert 会归一成 db_error）；
--   * `__facilityRace` 在第一次 facility UPDATE 前触发，用来制造 CAS 冲突。

__facilities = {}
__facilityRace = nil
__facilityRaceFired = false
__failFacilityInsert = false
__lastFacilityUpdateSql = nil

local __baseReset = __reset
function __reset()
    __baseReset()
    __facilities = {}
    __facilityRace = nil
    __facilityRaceFired = false
    __failFacilityInsert = false
    __lastFacilityUpdateSql = nil
end

function __facilitySeed(orgId, values)
    values = values or {}
    __facilities[orgId] = {
        org_id = orgId,
        facility_type = values.facility_type or 'mine',
        level = values.level or 1,
        workstations = values.workstations or 0,
        recipe_id = values.recipe_id,
        stock = values.stock or 0,
    }
end

function __facility(orgId)
    return __facilities[orgId]
end

function __facilityCount()
    local count = 0
    for _ in pairs(__facilities) do count = count + 1 end
    return count
end

local __baseSingle = MySQL.single.await
MySQL.single = { await = function(sql, values)
    if sql:find('industry_facility', 1, true) then
        logSql('single', sql)
        local orgId = values[1]
        local row = __facilities[orgId]
        if not row then return nil end
        local copy = {}
        for key, value in pairs(row) do copy[key] = value end
        return copy
    end
    return __baseSingle(sql, values)
end }

local __baseUpdate = MySQL.update.await
MySQL.update = { await = function(sql, values)
    if sql:find('industry_facility', 1, true) then
        logSql('update', sql)
        __lastFacilityUpdateSql = sql

        if __facilityRace and not __facilityRaceFired then
            __facilityRaceFired = true
            local hook = __facilityRace
            __facilityRace = nil
            hook()
        end

        local orgId = values[1]
        local old = tonumber(values[2])
        local cap = tonumber(values[3])
        local row = __facilities[orgId]
        if not row then return { affectedRows = 0 } end
        if tonumber(row.workstations) ~= old then return { affectedRows = 0 } end

        local guarded = sql:find('workstations < ?', 1, true) ~= nil
        if guarded and cap and tonumber(row.workstations) >= cap then
            return { affectedRows = 0 }
        end

        row.workstations = tonumber(row.workstations) + 1
        return { affectedRows = 1 }
    end
    return __baseUpdate(sql, values)
end }

local __baseInsert = MySQL.insert.await
MySQL.insert = { await = function(sql, values)
    if sql:find('industry_facility', 1, true) then
        logSql('insert', sql)
        local orgId = values[1]
        if __facilities[orgId] then
            error("Duplicate entry '" .. tostring(orgId) .. "' for key 'PRIMARY'")
        end
        if __failFacilityInsert then
            error('probe: forced facility insert failure')
        end
        __facilities[orgId] = {
            org_id = orgId,
            facility_type = values[2],
            level = 1,
            workstations = 0,
            recipe_id = nil,
            stock = 0,
        }
        -- 没有 AUTO_INCREMENT：Db.Insert 会归一成 no_insert_id，这不是错误。
        return { affectedRows = 1 }
    end
    return __baseInsert(sql, values)
end }
