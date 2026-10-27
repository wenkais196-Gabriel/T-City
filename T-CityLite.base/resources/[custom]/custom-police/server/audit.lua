-- server/audit.lua — 审计的唯一写者
--
-- 为什么要有这个文件：`police_audit` 之前有 8 份各自实现的 INSERT，分两种写法，
-- 其中一种**在 detail 为 nil 时会静默失败**。真实数据库上的实测（2026-10-25）：
--
--   写法 B: MySQL.insert.await('... VALUES (?, "player", ?, ?, ?)', { cid, action, target, nil })
--           参数表在末尾 nil 处被截断 → 发给 MariaDB 的参数少于占位符 →
--           "You have an error in your SQL syntax ... near '?)'"
--           而 pcall 返回的是 **true**（错误以字符串形式返回，不是抛异常），
--           于是调用方的 `if not audit(...)` 把失败当成了成功，审计行根本没写。
--
--   写法 A: 把 NULL 直接写进 SQL，参数数组里永远没有空洞 → 正常插入。
--
-- 结论：审计这种"宁可拒绝操作也不能记不上"的东西，只能有一份实现，而且它必须
-- (1) 不产生 nil 洞，(2) 把返回的**错误字符串**也当成失败。
--
-- 用法（同资源内直接调用，不走 exports —— 这是加载期就需要的热路径）：
--   PoliceAudit.Write(citizenid, 'citation.create', id, '超速 25km/h')
--   PoliceAudit.Write(citizenid, 'unit.duty', nil, nil, 'agent')

PoliceAudit = PoliceAudit or {}

local MAX_TARGET = 64
local MAX_DETAIL = 500

--- 记一条审计。返回 true 表示**真的写进去了**。
---@param actorCid string|nil 行为主体的 citizenid（agent 路径可以传 'agent:<id>'）
---@param action string 动作名，如 'incident.create'
---@param target string|number|nil 目标对象 id
---@param detail string|nil 说明
---@param actorKind string|nil 'player' | 'agent' | 'system'，默认 player
---@return boolean ok
function PoliceAudit.Write(actorCid, action, target, detail, actorKind)
    if type(action) ~= 'string' or action == '' then return false end

    -- 参数数组里不留空洞：NULL 写进 SQL 文本，值按需追加
    local values = { actorCid, actorKind or 'player', action }
    local sql = 'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail)'
        .. ' VALUES (?, ?, ?'

    if target ~= nil then
        sql = sql .. ', ?'
        values[#values + 1] = tostring(target):sub(1, MAX_TARGET)
    else
        sql = sql .. ', NULL'
    end

    if detail ~= nil then
        sql = sql .. ', ?'
        values[#values + 1] = tostring(detail):sub(1, MAX_DETAIL)
    else
        sql = sql .. ', NULL'
    end
    sql = sql .. ')'

    local ok, result = pcall(function()
        return MySQL.query.await(sql, values)
    end)
    if not ok then
        print(('[custom-police] audit write failed (%s): %s'):format(action, tostring(result)))
        return false
    end
    -- oxmysql 把 SQL 错误当**返回值**给，不抛异常；不检查这一点等于审计可以静默丢失。
    if type(result) == 'string' then
        print(('[custom-police] audit rejected by db (%s): %s'):format(action, result:sub(1, 160)))
        return false
    end
    return true
end

--- 只读查询用：给 `exports['custom-police']:GetAudit` 之外的调用方留个判定口。
---@param actorCid string|nil
---@param action string
---@return boolean ok
function PoliceAudit.WriteAgent(actorId, action, target, detail)
    return PoliceAudit.Write(
        ('agent:%s'):format(tostring(actorId or 'unknown'):sub(1, 40)),
        action, target, detail, 'agent')
end
