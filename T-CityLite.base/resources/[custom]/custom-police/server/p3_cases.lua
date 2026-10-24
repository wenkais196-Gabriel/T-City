-- server/p3_cases.lua — P2 cases, BOLOs, warrants, arrests.
local QBCore = exports['qb-core']:GetCoreObject()
local C = {}

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

local function caseNo(id)
    return ('CASE-%s-%06d'):format(os.date('%Y'), id)
end

function C.CreateCase(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'case.create')
    if not allowed then return false, reason end
    local title = trim(params and params.title):sub(1, 160)
    local summary = trim(params and params.summary):sub(1, 2000)
    if #title < 3 then return false, 'invalid_title' end
    local id = MySQL.insert.await(
        'INSERT INTO police_cases (title, summary, lead_citizenid, created_by) VALUES (?, ?, ?, ?)',
        { title, summary, trim(params and params.lead_citizenid):sub(1, 50), actor.citizenid })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    local no = caseNo(tonumber(id))
    MySQL.update.await('UPDATE police_cases SET case_no = ? WHERE id = ?', { no, id })
    audit(actor.citizenid, 'case.create', no, title)
    return { id = tonumber(id), case_no = no, status = 'open' }
end

function C.GetCases(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'case.view')
    if not allowed then return false, reason end
    local rows = MySQL.query.await(
        'SELECT * FROM police_cases ORDER BY id DESC LIMIT 50') or {}
    audit(actor.citizenid, 'case.view', nil, params and tostring(params.status or '') or '')
    return { rows = rows, count = #rows }
end

function C.CreateBolo(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'bolo.create')
    if not allowed then return false, reason end
    local kind = trim(params and params.kind)
    if kind ~= 'person' and kind ~= 'vehicle' then return false, 'invalid_kind' end
    local target = trim(params and params.target):sub(1, 50)
    local why = trim(params and params.reason):sub(1, 500)
    if target == '' then return false, 'invalid_target' end
    if #why < 3 then return false, 'invalid_reason' end
    local id = MySQL.insert.await(
        'INSERT INTO police_bolos (kind, target, reason, created_by) VALUES (?, ?, ?, ?)',
        { kind, target, why, actor.citizenid })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    audit(actor.citizenid, 'bolo.create', target, why)
    return { id = tonumber(id), kind = kind, target = target, status = 'active' }
end

function C.GetBolos(source)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'bolo.view')
    if not allowed then return false, reason end
    local rows = MySQL.query.await(
        "SELECT * FROM police_bolos WHERE status = 'active' ORDER BY id DESC LIMIT 50") or {}
    audit(actor.citizenid, 'bolo.view', nil, nil)
    return { rows = rows, count = #rows }
end

function C.ClearBolo(source, boloId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'bolo.create')
    if not allowed then return false, reason end
    local id = tonumber(boloId)
    if not id then return false, 'invalid_bolo' end
    MySQL.update.await("UPDATE police_bolos SET status = 'cleared', cleared_at = NOW() WHERE id = ? AND status = 'active'", { id })
    audit(actor.citizenid, 'bolo.clear', tostring(id), nil)
    return { id = id, status = 'cleared' }
end

function C.RequestWarrant(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'warrant.request')
    if not allowed then return false, reason end
    local target = trim(params and params.citizenid):sub(1, 50)
    local why = trim(params and params.reason):sub(1, 500)
    if target == '' then return false, 'invalid_citizen' end
    if #why < 3 then return false, 'invalid_reason' end
    local exists = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ? LIMIT 1', { target })
    if not exists then return false, 'citizen_not_found' end
    local id = MySQL.insert.await(
        'INSERT INTO police_warrants (citizenid, reason, requested_by) VALUES (?, ?, ?)',
        { target, why, actor.citizenid })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    audit(actor.citizenid, 'warrant.request', target, why)
    return { id = tonumber(id), citizenid = target, status = 'requested' }
end

function C.DecideWarrant(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'warrant.approve')
    if not allowed then return false, reason end
    local id = tonumber(params and params.warrant_id)
    local approve = params and params.approve == true
    if not id then return false, 'invalid_warrant' end
    local status = approve and 'approved' or 'denied'
    local changed = MySQL.update.await(
        "UPDATE police_warrants SET status = ?, approved_by = ?, decided_at = NOW() WHERE id = ? AND status = 'requested'",
        { status, actor.citizenid, id })
    if not changed then return false, 'not_pending' end
    audit(actor.citizenid, 'warrant.decide', tostring(id), status)
    return { id = id, status = status }
end

function C.GetWarrants(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'warrant.view')
    if not allowed then return false, reason end
    local rows
    if params and params.citizenid then
        rows = MySQL.query.await(
            'SELECT * FROM police_warrants WHERE citizenid = ? ORDER BY id DESC LIMIT 50',
            { tostring(params.citizenid):sub(1, 50) })
    else
        rows = MySQL.query.await('SELECT * FROM police_warrants ORDER BY id DESC LIMIT 50')
    end
    audit(actor.citizenid, 'warrant.view', nil, nil)
    return { rows = rows or {}, count = #(rows or {}) }
end

function C.RegisterArrest(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'arrest.create')
    if not allowed then return false, reason end
    local target = trim(params and params.citizenid):sub(1, 50)
    local charges = trim(params and params.charges):sub(1, 1000)
    if target == '' then return false, 'invalid_citizen' end
    if #charges < 3 then return false, 'invalid_charges' end
    local id = MySQL.insert.await([[
        INSERT INTO police_arrests (citizenid, officer_citizenid, charges, incident_id, case_id)
        VALUES (?, ?, ?, ?, ?)
    ]], { target, actor.citizenid, charges,
          tonumber(params and params.incident_id), tonumber(params and params.case_id) })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    audit(actor.citizenid, 'arrest.register', target, charges)
    return { id = tonumber(id), citizenid = target, status = 'registered' }
end

function C.GetArrests(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'arrest.create')
    if not allowed then return false, reason end
    local rows
    if params and params.citizenid then
        rows = MySQL.query.await(
            'SELECT * FROM police_arrests WHERE citizenid = ? ORDER BY id DESC LIMIT 50',
            { tostring(params.citizenid):sub(1, 50) })
    else
        rows = MySQL.query.await('SELECT * FROM police_arrests ORDER BY id DESC LIMIT 50')
    end
    audit(actor.citizenid, 'arrest.view', nil, nil)
    return { rows = rows or {}, count = #(rows or {}) }
end

--- Aggregate a case and everything linked to it. Sensitive: audited, and the
--- audit write must succeed or the read is refused.
function C.GetCaseDetail(source, caseId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'case.view')
    if not allowed then return false, reason end
    local id = tonumber(caseId)
    if not id then return false, 'invalid_case' end
    local caseRow = MySQL.single.await('SELECT * FROM police_cases WHERE id = ? LIMIT 1', { id })
    if not caseRow then return false, 'not_found' end
    if not audit(actor.citizenid, 'case.detail', tostring(id), nil) then
        return false, 'audit_unavailable'
    end
    local reports = MySQL.query.await(
        'SELECT id, title, author_citizenid, status, created_at FROM police_reports WHERE case_id = ? ORDER BY id DESC LIMIT 50', { id }) or {}
    local evidence = MySQL.query.await(
        'SELECT id, exhibit_no, label, status, created_at FROM police_evidence WHERE case_id = ? ORDER BY id DESC LIMIT 50', { id }) or {}
    local arrests = MySQL.query.await(
        'SELECT id, citizenid, charges, officer_citizenid, created_at FROM police_arrests WHERE case_id = ? ORDER BY id DESC LIMIT 50', { id }) or {}
    return {
        case = { id = tonumber(caseRow.id), case_no = caseRow.case_no, title = caseRow.title,
                 summary = caseRow.summary, status = caseRow.status,
                 lead_citizenid = caseRow.lead_citizenid, created_at = tostring(caseRow.created_at) },
        reports = reports, evidence = evidence, arrests = arrests,
    }
end

exports('CreateCase', C.CreateCase)
exports('GetCaseDetail', C.GetCaseDetail)
exports('GetCases', C.GetCases)
exports('CreateBolo', C.CreateBolo)
exports('GetBolos', C.GetBolos)
exports('ClearBolo', C.ClearBolo)
exports('RequestWarrant', C.RequestWarrant)
exports('DecideWarrant', C.DecideWarrant)
exports('GetWarrants', C.GetWarrants)
exports('RegisterArrest', C.RegisterArrest)
exports('GetArrests', C.GetArrests)
print('[custom-police] P2 cases/bolos/warrants/arrests loaded')
