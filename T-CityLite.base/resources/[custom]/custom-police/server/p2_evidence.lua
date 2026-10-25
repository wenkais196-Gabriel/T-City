-- server/p2_evidence.lua — evidence register + custody chain (P1).
local QBCore = exports['qb-core']:GetCoreObject()
local EV = {}

local function pd(source)
    local p = QBCore.Functions.GetPlayer(source)
    return p and p.PlayerData or nil
end

local function trim(v)
    return type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
end

local function audit(cid, action, target, detail)
    -- 唯一写者见 server/audit.lua（这里只保留同名包装，调用点不用改）
    return PoliceAudit.Write(cid, action, target, detail)
end

--- 写一条证据链记录。note 为 nil 时把 NULL 写进 SQL —— 参数数组留洞会被 oxmysql 截断，
--- MariaDB 然后报 "syntax error near '?)'"，而 pcall 看不见（错误是返回值），链条静默丢失。
local function chain(evidenceId, action, cid, note)
    local sql = 'INSERT INTO police_evidence_chain (evidence_id, action, actor_citizenid, note) VALUES (?, ?, ?'
    local values = { tonumber(evidenceId), action, cid }
    if note ~= nil then
        sql = sql .. ', ?)'
        values[#values + 1] = tostring(note):sub(1, 500)
    else
        sql = sql .. ', NULL)'
    end
    local ok, result = pcall(function() return MySQL.insert.await(sql, values) end)
    if not ok or type(result) == 'string' then
        print(('[custom-police] evidence chain write failed (%s): %s'):format(
            tostring(action), tostring(result):sub(1, 160)))
        return false
    end
    return true
end

local function exhibitNo(id)
    return ('EX-%06d'):format(id)
end

--- police_evidence + police_evidence_chain 的**唯一写入点**。
--- 收口前这里 `VALUES (?,?,?,?,?,?,?,?)` 配 `{ nil, incidentId, ... }`：参数数组第一个就是洞，
--- oxmysql 截断 → 0 个参数给 8 个占位符 → 语法错 → 每次登记都返回 db_error（真库实测）。
---@param actorCid string 采集人
---@param params table { label, description?, location?, incident_id?, report_id?, case_id? }
---@return table|nil result { id, exhibit_no, status }, string|nil reason
local function insertEvidence(actorCid, params)
    if type(params) ~= 'table' then return nil, 'invalid_params' end
    local label = trim(params.label):sub(1, 120)
    if #label < 3 then return nil, 'invalid_label' end
    local incidentId = tonumber(params.incident_id)
    local reportId = tonumber(params.report_id)
    local caseId = tonumber(params.case_id)
    if not incidentId and not reportId and not caseId then return nil, 'missing_case' end

    if caseId then
        local caseRow = MySQL.single.await('SELECT id FROM police_cases WHERE id = ? LIMIT 1', { caseId })
        if not caseRow then return nil, 'case_not_found' end
    end
    if incidentId then
        local inc = MySQL.single.await('SELECT id FROM police_incidents WHERE id = ? LIMIT 1', { incidentId })
        if not inc then return nil, 'incident_not_found' end
    end

    local columns = { 'label', 'collected_by' }
    local placeholders = { '?', '?' }
    local values = { label, actorCid }
    local function add(column, value)
        if value == nil then return end
        columns[#columns + 1] = column
        placeholders[#placeholders + 1] = '?'
        values[#values + 1] = value
    end
    local description = trim(params.description)
    add('description', description ~= '' and description:sub(1, 1000) or nil)
    local location = trim(params.location)
    add('location', location ~= '' and location:sub(1, 120) or nil)
    add('incident_id', incidentId)
    add('report_id', reportId)
    add('case_id', caseId)

    local inserted = MySQL.insert.await(
        ('INSERT INTO police_evidence (%s) VALUES (%s)'):format(
            table.concat(columns, ', '), table.concat(placeholders, ', ')),
        values)
    local id = InsertId(inserted)
    if not id or id == 0 then return nil, 'db_error' end

    -- 展品号依赖自增 id，只能插入后补写；失败不致命（列表仍能看到记录）
    local number = exhibitNo(tonumber(id))
    local numbered = pcall(function()
        return MySQL.update.await('UPDATE police_evidence SET exhibit_no = ? WHERE id = ?', { number, id })
    end)
    if not numbered then
        print(('[custom-police] exhibit_no write failed for #%s'):format(tostring(id)))
    end
    local chained = chain(tonumber(id), 'collected', actorCid, label)
    -- chain_ok 给"链写失败必须整体回滚"的调用方（agent 的提交路径）用
    return { id = tonumber(id), exhibit_no = number, status = 'collected', chain_ok = chained }
end

--- 同资源内的唯一写者句柄（p2_system 的两条 child 路径都用它）。
PoliceEvidenceWriter = { Register = insertEvidence, Chain = chain }

function EV.Register(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'evidence.register')
    if not allowed then return false, reason end

    local result, why = insertEvidence(actor.citizenid, params)
    if not result then return false, why end

    if not audit(actor.citizenid, 'evidence.register', result.exhibit_no,
            trim(params and params.label):sub(1, 120)) then
        print(('[custom-police] evidence.register audit failed for %s'):format(tostring(result.exhibit_no)))
    end
    return result
end

function EV.Get(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'evidence.view')
    if not allowed then return false, reason end
    -- FIT-05: audit before the read; a failed audit refuses the listing.
    if not audit(actor.citizenid, 'evidence.view', nil, params and tostring(params.incident_id or '') or '') then
        return false, 'audit_unavailable'
    end
    local rows
    if params and params.incident_id then
        rows = MySQL.query.await(
            'SELECT id, exhibit_no, incident_id, report_id, case_id, label, description, location, collected_by, status, created_at, updated_at FROM police_evidence WHERE incident_id = ? ORDER BY id DESC LIMIT 50',
            { tonumber(params.incident_id) })
    else
        rows = MySQL.query.await(
            'SELECT id, exhibit_no, incident_id, report_id, case_id, label, description, location, collected_by, status, created_at, updated_at FROM police_evidence ORDER BY id DESC LIMIT 50')
    end
    return { rows = rows or {}, count = #(rows or {}) }
end

function EV.GetChain(source, evidenceId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'evidence.view')
    if not allowed then return false, reason end
    local id = tonumber(evidenceId)
    if not id then return false, 'invalid_evidence' end
    -- FIT-05: the custody chain is evidence too; fail closed on audit.
    if not audit(actor.citizenid, 'evidence.chain', tostring(id), nil) then
        return false, 'audit_unavailable'
    end
    local rows = MySQL.query.await(
        'SELECT action, actor_citizenid, note, created_at FROM police_evidence_chain WHERE evidence_id = ? ORDER BY id ASC LIMIT 100',
        { id })
    return { rows = rows or {}, count = #(rows or {}) }
end

exports('RegisterEvidence', EV.Register)
exports('GetEvidence', EV.Get)
exports('GetEvidenceChain', EV.GetChain)
print('[custom-police] P1 evidence register loaded')
