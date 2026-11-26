-- server/facility.lua — S2 设施 / 工位。
--
-- 铁律：
--   1. 组织层的钱只有一条出口：Treasury.Withdraw；退回只有 Treasury.Deposit。
--   2. 先扣钱、再改设施行；改行失败必须退回（失败方向永远是「钱没少、工位没加」）。
--   3. 工位上限与乐观锁在同一条 UPDATE 的 WHERE 里：
--        UPDATE industry_facility SET workstations = workstations + 1
--         WHERE org_id = ? AND workstations = ? AND workstations < ?
--      affectedRows 是唯一裁决依据；affected = 0 才重读一次区分 cap_reached / conflict。
--      注意：顺序执行时「预读上限」只用于避免无谓扣款，真正的守卫仍是 UPDATE。
--   4. 每次动作（成功与失败）写 industry_audit，payload 只有金额 / 结果码 / ref / 工位数。

Facility = {}

local seq = 0

local validOrg = IndustryOrgId.IsValid -- 统一在 server/org_id.lua（S4 合并 4 份重复实现）

local function normalizeActor(actor)
    if type(actor) == 'string' and #actor > 0 and #actor <= 64 then return actor end
    return nil
end

local function makeRef(kind, orgId, n)
    seq = seq + 1
    return ('fac:%s:%s:%d:%d:%d'):format(kind, orgId, n or 0, os.time(), seq)
end

--- 审计 payload：在 S1 的金额/结果码/ref 之外多带一个 workstations。
local function auditPayload(amount, result, ref, workstations)
    local safeResult = tostring(result or 'unknown'):gsub('[^%w_%-%.]', '_')
    local safeRef = tostring(ref or ''):gsub('[^%w:_%-%.]', '_')
    local count = math.floor(tonumber(workstations) or 0)
    return ('{"amount":%s,"result":"%s","ref":"%s","workstations":%d}'):format(
        tostring(tonumber(amount) or 0), safeResult, safeRef, count)
end

local function audit(orgId, actor, action, amount, result, ref, workstations)
    IndustryAudit.Write(orgId, actor, action,
        auditPayload(amount, result, ref, workstations))
end

--- Treasury 的错误码里只有三个属于设施动作；其余一律折叠成 db_error。
--- （Withdraw 不会返回 no_account：账户不存在时 S1 报 insufficient_funds。）
local function treasuryCode(err)
    if err == 'bad_org' or err == 'insufficient_funds' or err == 'db_error' then
        return err
    end
    return 'db_error'
end

local function insertLikelySucceeded(id, err)
    if id then return true end
    -- industry_facility 没有 AUTO_INCREMENT：成功的 INSERT 也会被 Db.Insert
    -- 归一成 no_insert_id，那不是错误。
    return err == 'no_insert_id'
end

--- 第 n 个工位成本：n = 当前 workstations + 1。
--- 即 WorkstationCost(type, 0) = baseCost（第 1 个工位）。
---@return number|nil cost, string|nil errcode
function Facility.WorkstationCost(facilityType, workstations)
    local config = Config.Industry.Facilities[facilityType]
    if not config then return nil, 'bad_type' end
    local current = math.floor(tonumber(workstations) or 0)
    if current < 0 then return nil, 'bad_type' end
    return math.floor(config.baseCost * (1.35 ^ current))
end

--- 读整行（只读）。显式列名 + LIMIT，禁止 SELECT *。
---@return table|nil row, string|nil errcode
function Facility.Get(orgId)
    if not validOrg(orgId) then return nil, 'bad_org' end
    local row, err = Db.Single(
        'SELECT org_id, facility_type, level, workstations, recipe_id, stock, last_tick_at, created_at, '
            .. 'produced_units FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if err then return nil, 'db_error' end
    if not row then return nil, 'not_built' end
    return row, nil
end

--- 建设施（L1，workstations = 0）。一组织一设施；已存在返回 already_built，不扣钱。
---@param orgId string
---@param facilityType string Config.Industry.Facilities 的键
---@param opts table|nil { actor = citizenid|nil, ref = string|nil }
---@return boolean ok, string|nil errcode, number|nil cost
function Facility.Build(orgId, facilityType, opts)
    if not validOrg(orgId) then return false, 'bad_org' end

    opts = opts or {}
    local actor = normalizeActor(opts.actor)
    local ref = opts.ref or makeRef('build', orgId, 0)

    local config = Config.Industry.Facilities[facilityType]
    if not config then
        audit(orgId, actor, 'facility.build', 0, 'bad_type', ref, 0)
        return false, 'bad_type'
    end
    local cost = config.baseCost

    local existing, lookupErr = Db.Single(
        'SELECT org_id FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if lookupErr then
        audit(orgId, actor, 'facility.build', cost, 'db_error', ref, 0)
        return false, 'db_error'
    end
    if existing then
        audit(orgId, actor, 'facility.build', 0, 'already_built', ref, 0)
        return false, 'already_built'
    end

    local paid, payErr = Treasury.Withdraw(orgId, cost, 'facility-build', {
        actor = actor,
        ref = ref,
    })
    if not paid then
        local code = treasuryCode(payErr)
        audit(orgId, actor, 'facility.build', cost, code, ref, 0)
        return false, code
    end

    local id, insertErr = Db.Insert(
        'INSERT INTO industry_facility (org_id, facility_type, level, workstations, stock) '
            .. 'VALUES (?, ?, 1, 0, 0)',
        { orgId, facilityType })

    if not insertLikelySucceeded(id, insertErr) then
        -- 并发 Build 会撞 PK；驱动把错误当字符串回包时原文会丢，用存在性检查认回来。
        local text = type(insertErr) == 'string' and insertErr:lower() or ''
        local duplicate = text:find('duplicate', 1, true) ~= nil
            or text:find('primary', 1, true) ~= nil
        if not duplicate then
            local row, rowErr = Db.Single(
                'SELECT org_id FROM industry_facility WHERE org_id = ? LIMIT 1',
                { orgId })
            duplicate = (not rowErr and row ~= nil)
        end

        local code = duplicate and 'already_built' or 'db_error'
        local refunded, refundErr = Treasury.Deposit(orgId, cost, 'facility-build-rollback', {
            actor = actor,
            ref = ref .. ':rb',
        })
        if not refunded then
            print(('[custom-industry] CRITICAL build rollback failed org=%s ref=%s err=%s'):format(
                orgId, ref, tostring(refundErr)))
            code = 'db_error'
        end
        audit(orgId, actor, 'facility.build', cost, code, ref, 0)
        return false, code
    end

    audit(orgId, actor, 'facility.build', cost, 'ok', ref, 0)
    return true, nil, cost
end

--- 雇一个工位。上限与并发都在同一条 UPDATE 里；affected = 0 时退款并重读定性。
---@param orgId string
---@param opts table|nil { actor = citizenid|nil, ref = string|nil }
---@return boolean ok, string|nil errcode, number|nil cost, number|nil workstations
function Facility.AddWorkstation(orgId, opts)
    if not validOrg(orgId) then return false, 'bad_org' end

    opts = opts or {}
    local actor = normalizeActor(opts.actor)

    local row, readErr = Db.Single(
        'SELECT facility_type, workstations FROM industry_facility WHERE org_id = ? LIMIT 1',
        { orgId })
    if readErr then
        audit(orgId, actor, 'facility.hire', 0, 'db_error', opts.ref, 0)
        return false, 'db_error'
    end
    if not row then
        audit(orgId, actor, 'facility.hire', 0, 'not_built', opts.ref, 0)
        return false, 'not_built'
    end

    local facilityType = row.facility_type
    local config = Config.Industry.Facilities[facilityType]
    if not config then
        audit(orgId, actor, 'facility.hire', 0, 'bad_type', opts.ref, tonumber(row.workstations))
        return false, 'bad_type'
    end

    local current = math.floor(tonumber(row.workstations) or 0)
    local cap = math.floor(tonumber(config.workstationCap) or 0)
    local ref = opts.ref or makeRef('hire', orgId, current + 1)

    -- 预读只用于避免「上限了还先扣一笔再退」；真正的守卫在下面的 UPDATE。
    if current >= cap then
        audit(orgId, actor, 'facility.hire', 0, 'cap_reached', ref, current)
        return false, 'cap_reached'
    end

    local cost = Facility.WorkstationCost(facilityType, current)
    local paid, payErr = Treasury.Withdraw(orgId, cost, 'workstation-hire', {
        actor = actor,
        ref = ref,
    })
    if not paid then
        local code = treasuryCode(payErr)
        audit(orgId, actor, 'facility.hire', cost, code, ref, current)
        return false, code
    end

    -- 上限 + 乐观锁：affectedRows 是唯一裁决依据。
    local affected, updateErr = Db.Update(
        'UPDATE industry_facility SET workstations = workstations + 1 '
            .. 'WHERE org_id = ? AND workstations = ? AND workstations < ?',
        { orgId, current, cap })

    if updateErr then
        local refunded, refundErr = Treasury.Deposit(orgId, cost, 'workstation-rollback', {
            actor = actor,
            ref = ref .. ':rb',
        })
        if not refunded then
            print(('[custom-industry] CRITICAL hire rollback failed org=%s ref=%s err=%s'):format(
                orgId, ref, tostring(refundErr)))
        end
        audit(orgId, actor, 'facility.hire', cost, 'db_error', ref, current)
        return false, 'db_error'
    end

    if affected ~= 1 then
        -- 重读一次只为分类：cap_reached（别人填满）还是 conflict（别人改了工位）。
        local after, afterErr = Db.Single(
            'SELECT workstations FROM industry_facility WHERE org_id = ? LIMIT 1',
            { orgId })
        local code
        local count = current
        if afterErr then
            code = 'db_error'
        elseif not after then
            code = 'not_built'
        else
            count = math.floor(tonumber(after.workstations) or 0)
            code = count >= cap and 'cap_reached' or 'conflict'
        end

        local refunded, refundErr = Treasury.Deposit(orgId, cost, 'workstation-rollback', {
            actor = actor,
            ref = ref .. ':rb',
        })
        if not refunded then
            print(('[custom-industry] CRITICAL hire rollback failed org=%s ref=%s err=%s'):format(
                orgId, ref, tostring(refundErr)))
            code = 'db_error'
        end
        audit(orgId, actor, 'facility.hire', cost, code, ref, count)
        return false, code
    end

    local workstations = current + 1
    audit(orgId, actor, 'facility.hire', cost, 'ok', ref, workstations)
    return true, nil, cost, workstations
end
