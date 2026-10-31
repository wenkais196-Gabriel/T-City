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
    -- 待挂载证据：盘查读数发生在立案之前，有 subject 就先收着，等立案再绑。
    -- 只有系统路径（fieldTest）能走这里；普通采集仍然必须带父级。
    local subject = trim(params.subject_citizenid):sub(1, 50)
    if not incidentId and not reportId and not caseId and subject == '' then
        return nil, 'missing_case'
    end

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
    add('subject_citizenid', subject ~= '' and subject or nil)
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

--- 把一条待挂载证据绑到案卷上（AC-P4-07/08/09/10）。
--- 证据行只改 case_id；保管链走 append-only 的新行，不改旧行（AC-P4-02）。
---@param actor table 警察 actor（来自 pd(source)）
---@param evidenceId number
---@param caseId number
---@param opts table|nil { force?: boolean }
---@return table|nil result { id, case_id }
---@return string|nil reason
function EV.BindEvidence(actor, evidenceId, caseId, opts)
    local allowed, why = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return nil, why end
    local id = tonumber(evidenceId)
    local cid = tonumber(caseId)
    if not id then return nil, 'invalid_evidence' end
    if not cid then return nil, 'invalid_case' end

    local row = MySQL.single.await(
        'SELECT id, case_id, subject_citizenid FROM police_evidence WHERE id = ? LIMIT 1', { id })
    if not row then return nil, 'evidence_not_found' end
    if row.case_id ~= nil then return nil, 'already_bound' end

    local caseRow = MySQL.single.await(
        'SELECT id, lead_citizenid FROM police_cases WHERE id = ? LIMIT 1', { cid })
    if not caseRow then return nil, 'case_not_found' end

    local subject = tostring(row.subject_citizenid or '')
    local lead = tostring(caseRow.lead_citizenid or '')
    local force = type(opts) == 'table' and opts.force == true
    if subject ~= '' and lead ~= '' and subject ~= lead and not force then
        return nil, 'subject_mismatch'
    end

    MySQL.update.await('UPDATE police_evidence SET case_id = ? WHERE id = ? AND case_id IS NULL', { cid, id })
    if not audit(actor.citizenid, force and 'evidence.bind_forced' or 'evidence.bind',
            tostring(id), tostring(cid)) then
        return nil, 'audit_unavailable'
    end
    return { id = id, case_id = cid }
end

--- 立案后自动把该公民的待挂载读数挂上去（AC-P4-08）。
--- 只按精确 citizenid 匹配；不匹配就留着等人工。
---@param caseId number
---@param actorCid string
---@return number bound
function EV.BindPendingFor(caseId, actorCid)
    local cid = tonumber(caseId)
    if not cid then return 0 end
    local caseRow = MySQL.single.await(
        'SELECT id, lead_citizenid FROM police_cases WHERE id = ? LIMIT 1', { cid })
    if not caseRow then return 0 end
    local subject = tostring(caseRow.lead_citizenid or '')
    if subject == '' then return 0 end
    local rows = MySQL.query.await(
        'SELECT id FROM police_evidence WHERE subject_citizenid = ? AND case_id IS NULL LIMIT 20',
        { subject }) or {}
    local bound = 0
    for _, row in ipairs(rows) do
        local changed = MySQL.update.await(
            'UPDATE police_evidence SET case_id = ? WHERE id = ? AND case_id IS NULL', { cid, row.id })
        if type(changed) == 'table' then changed = changed.affectedRows or changed[1] end
        if changed and changed ~= 0 then
            chain(row.id, 'auto_bound', tostring(actorCid or 'system'), ('case:%s'):format(tostring(cid)))
            bound = bound + 1
        end
    end
    return bound
end

--- 指纹 / DNA 比对（police_evidence 的唯一写者在这儿，所以比对也在这儿做）。
--- 只认采样时写进 description 的"现场候选"名单：命中就给证据补 subject，
--- 链上追加 matched；不在名单上就是 no_match，不做任何修改。
function EV.CompareSample(actor, evidenceId, subjectCid)
    local allowed, why = PolicePolicy.Can(actor, 'evidence.register')
    if not allowed then return nil, why end
    local id = tonumber(evidenceId)
    local subject = tostring(subjectCid or ''):sub(1, 50)
    if not id then return nil, 'invalid_evidence' end
    if subject == '' then return nil, 'invalid_subject' end

    local row = MySQL.single.await(
        'SELECT id, label, description, subject_citizenid FROM police_evidence WHERE id = ? LIMIT 1', { id })
    if not row then return nil, 'evidence_not_found' end
    if row.subject_citizenid ~= nil then return nil, 'already_matched' end
    local label = tostring(row.label or '')
    if not (label:find('指纹', 1, true) or label:find('DNA', 1, true)) then
        return nil, 'not_a_sample'
    end

    local haystack = ',' .. tostring(row.description or '') .. ','
    if not haystack:find(',' .. subject .. ',', 1, true) then
        return { match = false }
    end

    MySQL.update.await(
        'UPDATE police_evidence SET subject_citizenid = ? WHERE id = ? AND subject_citizenid IS NULL',
        { subject, id })
    chain(id, 'matched', actor.citizenid, subject)
    return { match = true, subject_citizenid = subject }
end

exports('CompareSample', function(source, evidenceId, citizenid)
    local actor = pd(source)
    local allowed, why = PolicePolicy.Can(actor, 'evidence.register')
    if not allowed then return nil, why end
    return EV.CompareSample(actor, evidenceId, citizenid)
end)

exports('BindEvidence', function(source, evidenceId, caseId, force)
    local actor = pd(source)
    local allowed, why = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return nil, why end
    return EV.BindEvidence(actor, evidenceId, caseId, { force = force == true })
end)
exports('BindPendingFor', EV.BindPendingFor)
exports('RegisterEvidence', EV.Register)
exports('GetEvidence', EV.Get)
exports('GetEvidenceChain', EV.GetChain)
print('[custom-police] P1 evidence register loaded')
