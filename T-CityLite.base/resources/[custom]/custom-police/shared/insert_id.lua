-- shared/insert_id.lua — InsertId 门面（服务端脚本）。
--
-- oxmysql 的 insert.await 可能返回数字、{insertId, ...} 或 {[1]=...}；
-- insertId / affectedRows 的归一化只在 core-framework/server/db.lua 做一份。
-- 这里保留 InsertId( 这个名字，是为了不牵动 p0/p2/p3 的调用点。
function InsertId(result)
    return Db.InsertId(result)
end
