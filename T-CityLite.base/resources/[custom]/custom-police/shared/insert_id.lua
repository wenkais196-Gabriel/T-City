-- shared/insert_id.lua — oxmysql's insert.await returns either a numeric id or
-- a {insertId, affectedRows} table depending on the build. Normalize once so
-- every police write uses a numeric id.
function InsertId(result)
    if type(result) == 'table' then
        return tonumber(result.insertId or result[1] or result.id) or 0
    end
    return tonumber(result) or 0
end
