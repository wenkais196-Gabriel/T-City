-- fixtures/industry_production_probe.lua — S3 生产写库的离线假 DB。
--
-- 只实现 production.lua 会发出的两条语句：
--
--   * SELECT org_id, facility_type, workstations, stock,
--            UNIX_TIMESTAMP(last_tick_at) AS last_tick_epoch ...
--   * UPDATE industry_facility
--        SET stock = stock + ?, produced_units = produced_units + ?,
--            last_tick_at = FROM_UNIXTIME(?)
--      WHERE org_id = ? AND last_tick_at = FROM_UNIXTIME(?) AND stock = ?
--
-- UPDATE 必须带 produced_units 与 last_tick_at / stock 两个 CAS 条件；
-- 少任何一个，探针直接报错 —— 不允许静默退化成「无守卫更新」。
--
-- `__raceBeforeUpdate` 在第一次生产 UPDATE 落库前触发一次，用来制造
-- 「A 已读到旧 last_tick_at、还没落库时 B 先结算了」的交错。

__facilities = {}
__productionUpdates = 0
__raceBeforeUpdate = nil
__raceFired = false

local function copy(row)
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

function __reset()
    __facilities = {}
    __productionUpdates = 0
    __raceBeforeUpdate = nil
    __raceFired = false
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
        produced_units = values.produced_units or 0,
        last_tick_epoch = values.last_tick_epoch or 0,
    }
end

function __facility(orgId)
    return __facilities[orgId]
end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end

MySQL = {}

MySQL.single = { await = function(sql, values)
    if not sql:find('industry_facility', 1, true) then return nil end
    if not sql:find('UNIX_TIMESTAMP(last_tick_at)', 1, true) then
        error('probe: facility SELECT 必须把 last_tick_at 转成 epoch')
    end
    local row = __facilities[values[1]]
    if not row then return nil end
    return copy(row)
end }

MySQL.update = { await = function(sql, values)
    if not sql:find('industry_facility', 1, true) then return { affectedRows = 0 } end
    if not sql:find('produced_units', 1, true) then
        error('probe: UPDATE 缺 produced_units 累计')
    end
    if not sql:find('last_tick_at = FROM_UNIXTIME(?)', 1, true) then
        error('probe: UPDATE 缺 last_tick_at CAS')
    end
    if not sql:find('stock = ?', 1, true) then
        error('probe: UPDATE 缺 stock CAS')
    end

    __productionUpdates = __productionUpdates + 1

    if __raceBeforeUpdate and not __raceFired then
        __raceFired = true
        local hook = __raceBeforeUpdate
        __raceBeforeUpdate = nil
        hook()
    end

    local produced = tonumber(values[1]) or 0
    local newLast = tonumber(values[3]) or 0
    local orgId = values[4]
    local oldLast = tonumber(values[5]) or 0
    local oldStock = tonumber(values[6]) or 0

    local row = __facilities[orgId]
    if not row then return { affectedRows = 0 } end
    if tonumber(row.last_tick_epoch) ~= oldLast then return { affectedRows = 0 } end
    if tonumber(row.stock) ~= oldStock then return { affectedRows = 0 } end

    row.stock = tonumber(row.stock) + produced
    row.produced_units = tonumber(row.produced_units) + produced
    row.last_tick_epoch = newLast
    return { affectedRows = 1 }
end }

MySQL.query = { await = function() return {} end }
MySQL.insert = { await = function() return { affectedRows = 1 } end }
MySQL.scalar = { await = function() return 0 end }
MySQL.execute = { await = function() return 1 end }
