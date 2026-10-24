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
    return pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, "player", ?, ?, ?)',
            { cid, action, target, detail and tostring(detail):sub(1, 500) or nil })
    end)
end

local function chain(evidenceId, action, cid, note)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_evidence_chain (evidence_id, action, actor_citizenid, note) VALUES (?, ?, ?, ?)',
            { evidenceId, action, cid, note and tostring(note):sub(1, 500) or nil })
    end)
end

local function exhibitNo(id)
    return ('EX-%06d'):format(id)
end

function EV.Register(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'evidence.register')
    if not allowed then return false, reason end
    local label = trim(params and params.label):sub(1, 120)
    if #label < 3 then return false, 'invalid_label' end
    local description = trim(params and params.description):sub(1, 1000)
    local incidentId = tonumber(params and params.incident_id)
    local reportId = tonumber(params and params.report_id)
    local caseId = tonumber(params and params.case_id)
    if not incidentId and not reportId and not caseId then return false, 'missing_case' end
    if caseId then
        local caseRow = MySQL.single.await('SELECT id FROM police_cases WHERE id = ? LIMIT 1', { caseId })
        if not caseRow then return false, 'case_not_found' end
    end
    if incidentId then
        local inc = MySQL.single.await('SELECT id FROM police_incidents WHERE id = ? LIMIT 1', { incidentId })
        if not inc then return false, 'incident_not_found' end
    end
    local id = MySQL.insert.await([[
        INSERT INTO police_evidence (exhibit_no, incident_id, report_id, case_id, label, description, location, collected_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], { nil, incidentId, reportId, caseId, label, description,
          trim(params and params.location):sub(1, 120), actor.citizenid })
    if not id then return false, 'db_error' end
    local number = exhibitNo(tonumber(id))
    MySQL.update.await('UPDATE police_evidence SET exhibit_no = ? WHERE id = ?', { number, id })
    chain(tonumber(id), 'collected', actor.citizenid, label)
    audit(actor.citizenid, 'evidence.register', number, label)
    return { id = tonumber(id), exhibit_no = number, status = 'collected' }
end

function EV.Get(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'evidence.view')
    if not allowed then return false, reason end
    local rows
    if params and params.incident_id then
        rows = MySQL.query.await(
            'SELECT * FROM police_evidence WHERE incident_id = ? ORDER BY id DESC LIMIT 50',
            { tonumber(params.incident_id) })
    else
        rows = MySQL.query.await('SELECT * FROM police_evidence ORDER BY id DESC LIMIT 50')
    end
    audit(actor.citizenid, 'evidence.view', nil, params and tostring(params.incident_id or '') or '')
    return { rows = rows or {}, count = #(rows or {}) }
end

function EV.GetChain(source, evidenceId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'evidence.view')
    if not allowed then return false, reason end
    local id = tonumber(evidenceId)
    if not id then return false, 'invalid_evidence' end
    local rows = MySQL.query.await(
        'SELECT action, actor_citizenid, note, created_at FROM police_evidence_chain WHERE evidence_id = ? ORDER BY id ASC LIMIT 100',
        { id })
    audit(actor.citizenid, 'evidence.chain', tostring(id), nil)
    return { rows = rows or {}, count = #(rows or {}) }
end

exports('RegisterEvidence', EV.Register)
exports('GetEvidence', EV.Get)
exports('GetEvidenceChain', EV.GetChain)
print('[custom-police] P1 evidence register loaded')
