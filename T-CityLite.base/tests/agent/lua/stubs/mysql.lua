-- tests/agent/lua/stubs/mysql.lua — programmable oxmysql queue for the harness.
--
-- Both call styles are supported:
--   MySQL.query.await(sql, params)   -- synchronous (what custom-director uses)
--   MySQL.query(sql, params, cb)     -- callback
--
-- A queued entry is matched by a substring of the SQL (or by entry.match(sql))
-- and consumed once. Tests push failures with { match = 'INSERT', error = '...' }.

return function(env)
    local mysql = { queue = {} }

    function mysql.push(entry)
        mysql.queue[#mysql.queue + 1] = entry
        return mysql
    end

    function mysql.reset()
        mysql.queue = {}
        return mysql
    end

    local function take(sql)
        sql = tostring(sql or '')
        for index, entry in ipairs(mysql.queue) do
            local matches
            if type(entry.match) == 'function' then
                matches = entry.match(sql)
            elseif entry.match == nil then
                matches = true
            else
                matches = sql:find(tostring(entry.match), 1, true) ~= nil
            end
            if matches then
                table.remove(mysql.queue, index)
                return entry
            end
        end
        return {}
    end

    local function makeMethod(kind)
        local function impl(sql, params, callback)
            if type(params) == 'function' then
                callback, params = params, {}
            end
            local entry = take(sql)
            if entry.error then error(entry.error, 0) end
            local result = entry.result
            if result == nil and entry.default ~= nil then result = entry.default end
            if result == nil then
                if kind == 'query' or kind == 'prepare' then
                    result = {}
                elseif kind ~= 'single' and kind ~= 'scalar' then
                    result = 1
                end
            end
            if callback then callback(result) end
            return result
        end
        -- Functions are not tables in Lua, so expose a callable table whose
        -- .await field points at the same synchronous implementation.
        return setmetatable({ await = impl }, {
            __call = function(_, ...)
                return impl(...)
            end,
        })
    end

    _G.MySQL = {
        query = makeMethod('query'),
        single = makeMethod('single'),
        scalar = makeMethod('scalar'),
        insert = makeMethod('insert'),
        update = makeMethod('update'),
        execute = makeMethod('execute'),
        prepare = makeMethod('prepare'),
    }

    env.mysql = mysql
    return env
end
