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

-- UTF-8-safe head slice: `limit` counts characters, not bytes, so truncating a
-- Chinese title/target never leaves half a codepoint behind.
local function utf8Sub(s, limit)
    s = tostring(s or '')
    if type(limit) ~= 'number' or limit < 1 then return '' end
    if #s <= limit then return s end
    if utf8 and utf8.len and utf8.offset then
        local ok, length = pcall(utf8.len, s)
        if ok and length then
            if length <= limit then return s end
            local offsetOk, byteEnd = pcall(utf8.offset, s, limit + 1)
            if offsetOk and byteEnd then return s:sub(1, byteEnd - 1) end
            return s
        end
    end
    return s:sub(1, limit)
end

local function audit(cid, action, target, detail, actorKind)
    -- 唯一写者见 server/audit.lua（这里只保留同名包装，调用点不用改）
    return PoliceAudit.Write(cid, action, target, detail, actorKind)
end

local function caseNo(id)
    return ('CASE-%s-%06d'):format(os.date('%Y'), id)
end

function C.CreateCase(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'case.create')
    if not allowed then return false, reason end
    local title = utf8Sub(trim(params and params.title), 160)
    local summary = utf8Sub(trim(params and params.summary), 2000)
    if #title < 3 then return false, 'invalid_title' end
    -- 主办人：调用方给了就用它（允许指派别人），没给就默认**立案人自己**。
    -- 之前这里是 NULL —— MDT 那条路径从来不传，于是案卷永远查不出"谁负责"。
    local lead = utf8Sub(trim(params and params.lead_citizenid), 50)
    if lead == '' then lead = actor.citizenid end
    local id, no = PoliceRecords.InsertCase(actor.citizenid, {
        title = title,
        summary = summary,
        lead_citizenid = lead,
    })
    if not id then return false, 'db_error' end
    return { id = tonumber(id), case_no = no, status = 'open' }
end

function C.GetCases(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'case.view')
    if not allowed then return false, reason end
    -- FIT-05: audit before the read; a failed audit refuses the listing.
    if not audit(actor.citizenid, 'case.view', nil, params and tostring(params.status or '') or '') then
        return false, 'audit_unavailable'
    end
    local rows = MySQL.query.await(
        'SELECT id, case_no, title, status, lead_citizenid, created_by, created_at, updated_at FROM police_cases ORDER BY id DESC LIMIT 50') or {}
    return { rows = rows, count = #rows }
end

function C.CreateBolo(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'bolo.create')
    if not allowed then return false, reason end
    local kind = trim(params and params.kind)
    if kind ~= 'person' and kind ~= 'vehicle' then return false, 'invalid_kind' end
    local target = utf8Sub(trim(params and params.target), 50)
    local why = utf8Sub(trim(params and params.reason), 500)
    if target == '' then return false, 'invalid_target' end
    if #why < 3 then return false, 'invalid_reason' end
    local id = MySQL.insert.await(
        'INSERT INTO police_bolos (kind, target, reason, created_by) VALUES (?, ?, ?, ?)',
        { kind, target, why, actor.citizenid })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    if not audit(actor.citizenid, 'bolo.create', target, why) then
        print(('[custom-police] bolo.create audit failed for %s'):format(tostring(target)))
    end
    return { id = tonumber(id), kind = kind, target = target, status = 'active' }
end

function C.GetBolos(source)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'bolo.view')
    if not allowed then return false, reason end
    -- FIT-05: audit before the read; a failed audit refuses the listing.
    if not audit(actor.citizenid, 'bolo.view', nil, nil) then
        return false, 'audit_unavailable'
    end
    -- P3: BOLOs are tagged on reports; police_bolos is the legacy table. Read
    -- both and merge here so old rows keep showing until they are cleared.
    local reportRows = MySQL.query.await([[
        SELECT id, bolo_kind AS kind, bolo_target AS target,
               SUBSTRING(title, 1, 160) AS reason, created_at, 'report' AS source
          FROM police_reports
         WHERE is_bolo=1 AND kind IN ('report','arrest')
         ORDER BY id DESC LIMIT 50
    ]]) or {}
    local legacyRows = MySQL.query.await(
        "SELECT id, kind, target, reason, status, created_by, created_at, cleared_at FROM police_bolos WHERE status = 'active' ORDER BY id DESC LIMIT 50") or {}
    local rows = {}
    for _, row in ipairs(reportRows) do rows[#rows + 1] = row end
    for _, row in ipairs(legacyRows) do
        row.source = 'legacy'
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
        local at = tostring(a.created_at or '')
        local bt = tostring(b.created_at or '')
        if at ~= bt then return at > bt end
        return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
    end)
    if #rows > 50 then
        local kept = {}
        for i = 1, 50 do kept[i] = rows[i] end
        rows = kept
    end
    return { rows = rows, count = #rows }
end

function C.ClearBolo(source, boloId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'bolo.create')
    if not allowed then return false, reason end
    local id = tonumber(boloId)
    if not id then return false, 'invalid_bolo' end
    MySQL.update.await("UPDATE police_bolos SET status = 'cleared', cleared_at = NOW() WHERE id = ? AND status = 'active'", { id })
    if not audit(actor.citizenid, 'bolo.clear', tostring(id), nil) then
        print(('[custom-police] bolo.clear audit failed for #%s'):format(tostring(id)))
    end
    return { id = id, status = 'cleared' }
end

function C.RequestWarrant(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'warrant.request')
    if not allowed then return false, reason end
    local target = utf8Sub(trim(params and params.citizenid), 50)
    local why = utf8Sub(trim(params and params.reason), 500)
    if target == '' then return false, 'invalid_citizen' end
    if #why < 3 then return false, 'invalid_reason' end
    local exists = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ? LIMIT 1', { target })
    if not exists then return false, 'citizen_not_found' end
    local id = MySQL.insert.await(
        'INSERT INTO police_warrants (citizenid, reason, requested_by) VALUES (?, ?, ?)',
        { target, why, actor.citizenid })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    if not audit(actor.citizenid, 'warrant.request', target, why) then
        print(('[custom-police] warrant.request audit failed for %s'):format(tostring(target)))
    end
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
    if not audit(actor.citizenid, 'warrant.decide', tostring(id), status) then
        print(('[custom-police] warrant.decide audit failed for #%s'):format(tostring(id)))
    end
    return { id = id, status = status }
end

function C.GetWarrants(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'warrant.view')
    if not allowed then return false, reason end
    -- FIT-05: audit before the read; a failed audit refuses the listing.
    if not audit(actor.citizenid, 'warrant.view', nil, nil) then
        return false, 'audit_unavailable'
    end
    local rows
    if params and params.citizenid then
        rows = MySQL.query.await(
            'SELECT id, citizenid, reason, status, requested_by, approved_by, created_at, decided_at FROM police_warrants WHERE citizenid = ? ORDER BY id DESC LIMIT 50',
            { utf8Sub(tostring(params.citizenid), 50) })
    else
        rows = MySQL.query.await(
            'SELECT id, citizenid, reason, status, requested_by, approved_by, created_at, decided_at FROM police_warrants ORDER BY id DESC LIMIT 50')
    end
    return { rows = rows or {}, count = #(rows or {}) }
end

function C.RegisterArrest(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'arrest.create')
    if not allowed then return false, reason end
    local target = utf8Sub(trim(params and params.citizenid), 50)
    local charges = utf8Sub(trim(params and params.charges), 1000)
    if target == '' then return false, 'invalid_citizen' end
    if #charges < 3 then return false, 'invalid_charges' end
    local id = PoliceRecords.InsertArrest(actor.citizenid, {
        citizenid = target,
        charges = charges,
        incident_id = params and params.incident_id,
        case_id = params and params.case_id,
    })
    if not id then return false, 'db_error' end
    if not audit(actor.citizenid, 'arrest.register', target, charges) then
        print(('[custom-police] arrest.register audit failed for %s'):format(tostring(target)))
    end
    return { id = tonumber(id), citizenid = target, status = 'registered' }
end

function C.GetArrests(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'arrest.create')
    if not allowed then return false, reason end
    -- FIT-05: audit before the read; a failed audit refuses the listing.
    if not audit(actor.citizenid, 'arrest.view', nil, nil) then
        return false, 'audit_unavailable'
    end
    -- New arrests live in police_reports(kind='arrest'); police_arrests is only
    -- kept for history written before v3.4 and is read via case detail.
    local sql = [[
        SELECT id, subject_citizenid AS citizenid, charges, officer_citizenid,
               justice_case_id, justice_verdict, justice_status, created_at
          FROM police_reports
         WHERE kind = 'arrest'
    ]]
    local rows
    if params and params.citizenid then
        rows = MySQL.query.await(
            sql .. ' AND subject_citizenid = ? ORDER BY id DESC LIMIT 50',
            { utf8Sub(tostring(params.citizenid), 50) })
    else
        rows = MySQL.query.await(sql .. ' ORDER BY id DESC LIMIT 50')
    end
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
    -- FIT-04: audit first, then read. The aggregate below contains reports,
    -- evidence and arrests, so a failed audit must never release any of it.
    if not audit(actor.citizenid, 'case.detail', tostring(id), nil) then
        return false, 'audit_unavailable'
    end
    local caseRow = MySQL.single.await(
        'SELECT id, case_no, title, summary, status, lead_citizenid, created_by, created_at, updated_at FROM police_cases WHERE id = ? LIMIT 1',
        { id })
    if not caseRow then return false, 'not_found' end
    local reports = MySQL.query.await(
        'SELECT id, title, author_citizenid, status, created_at, justice_case_id, justice_verdict, justice_status FROM police_reports WHERE case_id = ? ORDER BY id DESC LIMIT 50', { id }) or {}
    local evidence = MySQL.query.await(
        'SELECT id, exhibit_no, label, status, created_at FROM police_evidence WHERE case_id = ? ORDER BY id DESC LIMIT 50', { id }) or {}
    local arrests = MySQL.query.await([[
        SELECT id, subject_citizenid AS citizenid, charges, officer_citizenid,
               justice_case_id, justice_verdict, justice_status, created_at
          FROM police_reports WHERE kind = 'arrest' AND case_id = ?
        UNION ALL
        SELECT id, citizenid, charges, officer_citizenid,
               NULL AS justice_case_id, NULL AS justice_verdict, NULL AS justice_status, created_at
          FROM police_arrests WHERE case_id = ?
        ORDER BY id DESC LIMIT 50
    ]], { id, id }) or {}
    return {
        case = { id = tonumber(caseRow.id), case_no = caseRow.case_no, title = caseRow.title,
                 summary = caseRow.summary, status = caseRow.status,
                 lead_citizenid = caseRow.lead_citizenid, created_at = tostring(caseRow.created_at) },
        reports = reports, evidence = evidence, arrests = arrests,
    }
end

--- Owner write path for the justice verdict projection (FIT-02). custom-justice
--- keeps verdicts in memory and used to UPDATE police_reports directly; it now
--- calls this export instead, so `police_reports` has a single writer.
---
--- `justiceCaseId` is the string id stored in v3.6's VARCHAR(32); the verdict is
--- the JSON blob from the justice verdict (TEXT, so 65535 bytes max); `status`
--- is the v3.7 closed state ('sentenced' is accepted for callers that persist
--- before closing the in-memory case).
---@param justiceCaseId string|number
---@param verdictJson string
---@param status string
---@return boolean ok, string|nil error
function C.RecordVerdict(justiceCaseId, verdictJson, status)
    local caseId = type(justiceCaseId) == 'string' and justiceCaseId
        or (type(justiceCaseId) == 'number' and tostring(justiceCaseId) or '')
    if caseId == '' or #caseId > 32 then return false, 'invalid_justice_case' end
    if type(verdictJson) ~= 'string' or verdictJson == '' or #verdictJson > 65535 then
        return false, 'invalid_verdict'
    end
    if status ~= 'sentenced' and status ~= 'closed' then return false, 'invalid_status' end

    -- 判决字段的写入也在唯一写者里（server/records.lua）
    local ok = PoliceRecords.RecordVerdict(caseId, verdictJson, status)
    if not ok then
        print(('[custom-police] justice verdict write failed for %s'):format(tostring(caseId)))
        return false, 'db_error'
    end
    -- FIT-04: owner writes are audited too. The row is already committed, so a
    -- failed audit is logged rather than reported as a write failure.
    if not audit('system', 'justice.verdict', caseId, status, 'system') then
        print(('[custom-police] justice.verdict audit failed for %s'):format(tostring(caseId)))
    end
    return true
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
-- 案卷维度的判决回写（v3.11 加的两列）；报告维度仍是 RecordVerdict。
exports('RecordCaseVerdict', function(caseId, courtStatus, minutes)
    local ok, affected = PoliceRecords.RecordCaseVerdict(caseId, courtStatus, minutes)
    if not ok then return false, 'db_error' end
    return { ok = true, affected_rows = affected }
end)

exports('RecordVerdict', C.RecordVerdict)
print('[custom-police] P2 cases/bolos/warrants/arrests loaded')
