-- server/db.lua — oxmysql 结果适配器（insertId / affectedRows 的唯一归一化点）
--
-- 为什么要有这一层：本服打包的 oxmysql 的 `insert.await` / `update.await`
-- 可能返回裸数字，也可能返回 `{ insertId = n, affectedRows = n }`
-- （真实回包见 `tests/unit/layer0_js/test_oxmysql.cjs`）。调用点各自解形状会
-- 长出两类事故：`affectedRows` 被当成记录 id；stock build 返回数字时 helper
-- 只认 `.insertId` 拿到 0。归一化只在这里做一次。
--
-- 契约（`tests/architecture/test_db_result_adapter.py` 逐条覆盖）：
--   Db.Insert(sql, params) -> id|nil, err
--       数字 42 / { insertId = 7 } / { [1] = 9 } / { id = 5 }  -> 对应 id
--       { affectedRows = 1 }（只有 affectedRows）              -> nil, 'no_insert_id'
--       0 / nil                                                -> nil, 'no_insert_id'
--       结果字符串                                              -> nil, 'db_error'
--       pcall 抛错                                              -> nil, 截断 160 字的错误
--   Db.Update(sql, params) -> affected|nil, err
--       affectedRows / affected_rows / [1] / 数字；0 是成功
--       结果字符串 -> nil, 'db_error'；pcall 抛错 -> nil, 截断 160 字的错误
--   Db.Query / Db.Single / Db.Scalar(sql, params) -> result|nil, err
--       pcall 包裹；错误（抛错或字符串回包）截断到 160 字。
--       Query 无结果返回 {}；Single 未命中返回 nil, nil；Scalar 原样返回。
--   Db.InsertId(result) / Db.AffectedRows(result) -> number
--       纯归一化，不碰 SQL，也不需要 MySQL 全局；缺失/不可转数字一律 0。
--       InsertId 只认 insertId / [1] / id —— affectedRows 不是 id。
--
-- 边界：不拼 SQL、不改列名、不重试、不超时、不使用 Citizen.Await。
-- 调用方负责把 err 变成业务错误码/日志；本文件不 print。
--
-- 加载：每个服务端资源在 `@oxmysql/lib/MySQL.lua` 之后 include
-- `@core-framework/server/db.lua`；`Db` 是该资源 Lua state 内的全局。

Db = {}

local ERROR_LIMIT = 160

local function truncateError(value)
    local text = tostring(value or 'unknown db error')
    if #text > ERROR_LIMIT then return text:sub(1, ERROR_LIMIT) end
    return text
end

---@param result table|number|string|nil
---@return number insertId  0 when the result carries no usable id
function Db.InsertId(result)
    if type(result) == 'table' then
        result = result.insertId or result[1] or result.id
    end
    return tonumber(result) or 0
end

---@param result table|number|string|nil
---@return number affectedRows
function Db.AffectedRows(result)
    if type(result) == 'table' then
        result = result.affectedRows or result.affected_rows or result[1]
    end
    return tonumber(result) or 0
end

---@param sql string
---@param params table|nil
---@return number|nil id, string|nil err
function Db.Insert(sql, params)
    local ok, result = pcall(function()
        return MySQL.insert.await(sql, params or {})
    end)
    if not ok then return nil, truncateError(result) end
    if type(result) == 'string' then return nil, 'db_error' end
    local id = Db.InsertId(result)
    if id == 0 then return nil, 'no_insert_id' end
    return id, nil
end

---@param sql string
---@param params table|nil
---@return number|nil affectedRows, string|nil err
function Db.Update(sql, params)
    local ok, result = pcall(function()
        return MySQL.update.await(sql, params or {})
    end)
    if not ok then return nil, truncateError(result) end
    if type(result) == 'string' then return nil, 'db_error' end
    return Db.AffectedRows(result), nil
end

---@param sql string
---@param params table|nil
---@return table|nil rows, string|nil err
function Db.Query(sql, params)
    local ok, result = pcall(function()
        return MySQL.query.await(sql, params or {})
    end)
    if not ok then return nil, truncateError(result) end
    if type(result) == 'string' then return nil, truncateError(result) end
    return result or {}, nil
end

---@param sql string
---@param params table|nil
---@return table|nil row, string|nil err
function Db.Single(sql, params)
    local ok, row = pcall(function()
        return MySQL.single.await(sql, params or {})
    end)
    if not ok then return nil, truncateError(row) end
    if type(row) == 'string' then return nil, truncateError(row) end
    return row, nil
end

---@param sql string
---@param params table|nil
---@return any value, string|nil err
function Db.Scalar(sql, params)
    local ok, value = pcall(function()
        return MySQL.scalar.await(sql, params or {})
    end)
    if not ok then return nil, truncateError(value) end
    if type(value) == 'string' then return nil, truncateError(value) end
    return value, nil
end
