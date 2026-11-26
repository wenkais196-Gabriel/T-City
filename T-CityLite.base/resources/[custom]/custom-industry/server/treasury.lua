-- server/treasury.lua — 组织金库的**唯一写入口**。
--
-- 三条不变量（写错任一条，这一片就白写）：
--
-- 1. 余额判断与扣减必须是**一条** UPDATE：
--        balance = balance + ? WHERE org_id = ? AND balance + ? >= 0
--    affectedRows == 0 就是拒绝。先 Db.Single 再比较是 TOCTOU：两个并发取款
--    都能读到同一个余额，然后把账户扣成负数。
-- 2. 先改余额，成功后才插流水；插流水失败必须把余额改回去（补偿）。
--    失败方向永远是「钱没少、流水没记」，而不是「钱少了、流水没记」。
-- 3. 流水唯一键 org_ledger.uniq_org_ref(org_id, ref) 是幂等性的**数据库事实**。
--    Lua 只负责把唯一键冲突翻译成 duplicate_ref，不自己维护「ref 用过没有」的表。
--
-- 错误码只有六个：bad_org / bad_amount / no_account / insufficient_funds /
-- duplicate_ref / db_error。调用方只按码分支，不解析英文错误文本。

Treasury = {}

local MAX_REF_LEN = 96
local MAX_REASON_LEN = 64
-- 1e15 小于 2^53：金额在 Lua number 里仍然精确，也远在 bigint 范围内。
local MAX_AMOUNT = 1000000000000000

-- ref 是唯一性键，只接受可读的安全字符；不合形状的 ref 不会被当成幂等键。
local REF_PATTERN = '^[%w:_%-%.]+$'

local seq = 0

local validOrg = IndustryOrgId.IsValid -- 统一在 server/org_id.lua（S4 合并 4 份重复实现）

local function validAmount(amount)
    return type(amount) == 'number'
        and amount == amount -- NaN
        and amount > 0
        and amount <= MAX_AMOUNT
        and amount == math.floor(amount)
end

local function normalizeReason(reason)
    if type(reason) ~= 'string' or reason == '' then return 'unspecified' end
    if #reason > MAX_REASON_LEN then return reason:sub(1, MAX_REASON_LEN) end
    return reason
end

--- 缺省或形状不合法的 ref 一律改用服务端生成的 ref。
--- 为什么不是 reject：错误码里没有 bad_ref，而把一个形状不明的字符串当唯一键
--- 更危险（超长会撞 varchar(96)，怪字符会让日志/审计难读）。S1 的 ref 全部由
--- 命令层生成，这条只是兜底。
local function normalizeRef(orgId, reason, ref)
    if type(ref) == 'string' and #ref > 0 and #ref <= MAX_REF_LEN and ref:match(REF_PATTERN) then
        return ref
    end
    seq = seq + 1
    local safeReason = reason:gsub('[^%w_%-]', '_'):sub(1, 24)
    return ('sys:%s:%s:%d:%d'):format(orgId, safeReason, os.time(), seq)
end

local function normalizeCycle(cycleNo)
    if type(cycleNo) == 'number' and cycleNo == math.floor(cycleNo) and cycleNo >= 0 then
        return cycleNo
    end
    return 0
end

local function normalizeActor(actor)
    if type(actor) == 'string' and #actor > 0 and #actor <= 64 then return actor end
    return nil
end

--- 余额 UPDATE 之后读一次余额，只为流水的 balance_after。
--- 授权判断已经由 affectedRows 完成，这次读**不**参与放行/拒绝。
local function readBalance(orgId)
    local row, err = Db.Single(
        'SELECT balance FROM org_treasury WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return nil, 'no_account' end
    local balance = tonumber(row.balance)
    if not balance then return nil, 'db_error' end
    return balance, nil
end

local function insertLedger(orgId, delta, balanceAfter, reason, actor, ref, cycleNo)
    local id, err
    if actor then
        id, err = Db.Insert(
            'INSERT INTO org_ledger (org_id, delta, balance_after, reason, actor_cid, ref, cycle_no) '
                .. 'VALUES (?, ?, ?, ?, ?, ?, ?)',
            { orgId, delta, balanceAfter, reason, actor, ref, cycleNo })
    else
        -- actor_cid 显式为 NULL：参数数组里留 nil 洞会被 oxmysql 截断（db.lua 头注释）。
        id, err = Db.Insert(
            'INSERT INTO org_ledger (org_id, delta, balance_after, reason, actor_cid, ref, cycle_no) '
                .. 'VALUES (?, ?, ?, ?, NULL, ?, ?)',
            { orgId, delta, balanceAfter, reason, ref, cycleNo })
    end

    if id then return true, nil end
    if err == 'no_insert_id' then
        -- 驱动只回了 affectedRows、没回 insertId。普通 INSERT（非 IGNORE）到这里
        -- 说明行已经写进去了；把「拿不到 id」当成失败会让余额被无谓回滚。
        return true, nil
    end
    local text = type(err) == 'string' and err:lower() or ''
    if text:find('duplicate', 1, true) or text:find('uniq_org_ref', 1, true) then
        return false, 'duplicate_ref'
    end

    -- 有的 oxmysql 构建把 SQL 错误当字符串回包，db.lua 会把它归一化成
    -- 'db_error' 并丢掉原文。唯一键冲突因此可能看不出是 duplicate；
    -- 用一次**失败之后**的存在性检查把它认回来。这不是先读后写：
    -- 插入已经尝试过，这里只解释它为什么失败。
    local row, lookupErr = Db.Single(
        'SELECT id FROM org_ledger WHERE org_id = ? AND ref = ? LIMIT 1',
        { orgId, ref })
    if not lookupErr and row then return false, 'duplicate_ref' end

    return false, 'db_error'
end

--- 把已经加上的 delta 减回去。补偿本身失败时只记录（钱与流水的不一致必须留痕）。
local function compensate(orgId, delta)
    local affected, err = Db.Update(
        'UPDATE org_treasury SET balance = balance + ? WHERE org_id = ?',
        { -delta, orgId })
    if err or affected ~= 1 then
        print(('[custom-industry] treasury rollback failed org=%s delta=%d err=%s'):format(
            tostring(orgId), -delta, tostring(err or ('affected=' .. tostring(affected)))))
        return false
    end
    return true
end

local function apply(orgId, delta, reason, opts)
    if not validOrg(orgId) then return false, 'bad_org' end
    if not validAmount(math.abs(delta)) then return false, 'bad_amount' end

    opts = opts or {}
    reason = normalizeReason(reason)
    local ref = normalizeRef(orgId, reason, opts.ref)
    local actor = normalizeActor(opts.actor)
    local cycleNo = normalizeCycle(opts.cycleNo)

    -- ① 余额与守卫在同一条 UPDATE 里：affectedRows 是唯一的裁决依据。
    local affected, updateErr = Db.Update(
        'UPDATE org_treasury SET balance = balance + ? WHERE org_id = ? AND balance + ? >= 0',
        { delta, orgId, delta })
    if updateErr then return false, 'db_error' end
    if affected ~= 1 then
        -- 正数只可能是账户不存在；负数既可能是余额不足，也可能是账户不存在。
        -- 施工计划规定取款一律报 insufficient_funds（S1 不自动开户）。
        if delta > 0 then return false, 'no_account' end
        return false, 'insufficient_funds'
    end

    -- ② 余额已变，接下来必须让流水落地；任何一步失败都回滚余额。
    local balanceAfter, readErr = readBalance(orgId)
    if not balanceAfter then
        compensate(orgId, delta)
        return false, readErr or 'db_error'
    end

    local inserted, insertErr = insertLedger(orgId, delta, balanceAfter, reason, actor, ref, cycleNo)
    if not inserted then
        compensate(orgId, delta)
        return false, insertErr
    end

    return true, nil
end

--- 确保组织金库账户存在（只建行，不改余额）。
--- S1 只有控制台 /orgfundgrant 走这里；玩家侧存/取仍要求账户已存在，
--- 避免打错一个 orgId 就凭空建账户。
---
--- 第三个返回值 created 只给审计用（fund.open 只在首次建行时写）。
---@param orgId string
---@return boolean ok, string|nil errcode, boolean created
function Treasury.EnsureAccount(orgId)
    if not validOrg(orgId) then return false, 'bad_org', false end

    -- 先读一次只为区分「本次新建」；真正的判据是插入后再读一次余额。
    local existing, lookupErr = Db.Single(
        'SELECT org_id FROM org_treasury WHERE org_id = ? LIMIT 1',
        { orgId })

    -- INSERT IGNORE：已存在时 affectedRows=0；org_treasury 没有 AUTO_INCREMENT，
    -- Db.Insert 会把这两种回包都归一成 no_insert_id —— 那不是错误。成功与否
    -- 统一用「插入后能读到余额」判定。
    Db.Insert(
        'INSERT IGNORE INTO org_treasury (org_id, balance) VALUES (?, 0)',
        { orgId })

    local balance = readBalance(orgId)
    if balance == nil then return false, 'db_error', false end

    local created = lookupErr == nil and existing == nil
    return true, nil, created
end

--- 组织入账。
---@param orgId string
---@param amount number 正整数
---@param reason string 写入流水的可读原因
---@param opts table|nil { actor = citizenid|nil, ref = string|nil, cycleNo = int|nil }
---@return boolean ok, string|nil errcode
function Treasury.Deposit(orgId, amount, reason, opts)
    if not validAmount(amount) then return false, 'bad_amount' end
    return apply(orgId, amount, reason, opts)
end

--- 组织出账。余额不足时不会产生任何余额变化与流水。
---@return boolean ok, string|nil errcode
function Treasury.Withdraw(orgId, amount, reason, opts)
    if not validAmount(amount) then return false, 'bad_amount' end
    return apply(orgId, -amount, reason, opts)
end

---@return number|nil balance, string|nil errcode
function Treasury.GetBalance(orgId)
    if not validOrg(orgId) then return nil, 'bad_org' end
    local row, err = Db.Single(
        'SELECT balance FROM org_treasury WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return nil, 'no_account' end
    local balance = tonumber(row.balance)
    if not balance then return nil, 'db_error' end
    return balance, nil
end

--- 最近流水（新→旧）。显式列名 + LIMIT，禁止 SELECT *。
---@return table rows, string|nil errcode
function Treasury.GetLedger(orgId, limit)
    if not validOrg(orgId) then return nil, 'bad_org' end
    local wanted = tonumber(limit) or 20
    wanted = math.floor(wanted)
    if wanted < 1 then wanted = 1 end
    if wanted > 100 then wanted = 100 end

    local rows, err = Db.Query(
        'SELECT id, org_id, delta, balance_after, reason, actor_cid, ref, cycle_no, created_at '
            .. 'FROM org_ledger WHERE org_id = ? ORDER BY id DESC LIMIT ?',
        { orgId, wanted })
    if err then return nil, 'db_error' end
    return rows or {}, nil
end
