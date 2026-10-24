-- server/p2_system.lua — system (agent) entry points for the police board.
-- These have no player source: the actor is an agent id and every write is
-- audited with actor_kind='agent'. Authorization/approval happens in
-- custom-director (L1-L3); this layer only validates data and state.
local QBCore = exports['qb-core']:GetCoreObject()
local Sys = {}

local function trim(v)
    return type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
end

-- UTF-8-safe head slice: `limit` counts characters, not bytes, so a Chinese
-- label is never cut through the middle of a codepoint. utf8.offset returns the
-- byte position of the (limit + 1)-th character; everything before it is kept.
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

local function audit(actorId, action, target, detail)
    return pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, "agent", ?, ?, ?)',
            { ('agent:%s'):format(utf8Sub(tostring(actorId or 'unknown'), 40)), action, target,
              detail and utf8Sub(tostring(detail), 500) or nil })
    end)
end

local function broadcast(title, content)
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if d and type(d.job) == 'table' and d.job.name == 'police' and d.job.onduty == true then
            MySQL.insert.await(
                'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)',
                { d.citizenid, utf8Sub(title, 200), utf8Sub(content, 500), 'police_mdt' })
            TriggerClientEvent('phone:client:newNotification', src, {
                id = 0, title = utf8Sub(title, 200), content = utf8Sub(content, 500),
                timestamp = os.date('%Y-%m-%d %H:%M:%S'), is_read = false, app_id = 'police_mdt',
            })
        end
    end
end

--- L1: create an incident as an agent. Returns {id=...}.
function Sys.CreateIncident(actorId, data)
    if type(data) ~= 'table' then return false, 'invalid_params' end
    local title = utf8Sub(trim(data.title), 120)
    if #title < 3 then return false, 'invalid_title' end
    local code = trim(data.code):sub(1, 16)
    if code == '' then code = '911' end
    local priority = math.max(1, math.min(3, math.floor(tonumber(data.priority) or 2)))
    local details = utf8Sub(trim(data.details or data.description), 1000)
    if not audit(actorId, 'incident.create', nil, title) then return false, 'audit_unavailable' end
    local id = MySQL.insert.await([[
        INSERT INTO police_incidents (code, title, description, priority, created_by)
        VALUES (?, ?, ?, ?, ?)
    ]], { code, title, details, priority, ('agent:%s'):format(utf8Sub(tostring(actorId), 40)) })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    broadcast(('%s: %s'):format(code, title), details)
    return { id = tonumber(id), status = 'open' }
end

--- L2: assign a unit to an incident as an agent.
function Sys.AssignUnit(actorId, incidentId, citizenid)
    local id = tonumber(incidentId)
    local target = tostring(citizenid or ''):sub(1, 50)
    if not id then return false, 'invalid_incident' end
    if target == '' then return false, 'invalid_unit' end
    local incident = MySQL.single.await('SELECT id FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    local unit = MySQL.single.await('SELECT citizenid, status FROM police_units WHERE citizenid = ? LIMIT 1', { target })
    if not unit then return false, 'unit_not_found' end
    if unit.status == 'off_duty' then return false, 'unit_off_duty' end
    if not audit(actorId, 'incident.assign', tostring(id), target) then return false, 'audit_unavailable' end
    MySQL.insert.await([[
        INSERT INTO police_incident_units (incident_id, citizenid) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE joined_at = joined_at
    ]], { id, target })
    MySQL.update.await("UPDATE police_units SET status = 'assigned', incident_id = ? WHERE citizenid = ?", { id, target })
    MySQL.update.await("UPDATE police_incidents SET status = 'assigned' WHERE id = ?", { id })
    return { id = id, unit = target, status = 'assigned' }
end

--- L3: jail a citizen as an agent. Delegates to custom-justice so the normal
--- sentence bookkeeping and qb-prison handoff are reused.
function Sys.Jail(actorId, citizenid, minutes, reason)
    local target = tostring(citizenid or ''):sub(1, 50)
    local mins = math.floor(tonumber(minutes) or 0)
    local text = utf8Sub(trim(reason), 240)
    if target == '' then return false, 'invalid_citizen' end
    if mins < 1 or mins > 120 then return false, 'invalid_minutes' end
    if #text < 3 then return false, 'invalid_reason' end
    local player = QBCore.Functions.GetPlayerByCitizenId(target)
    if not player then return false, 'citizen_offline' end
    local ok, result = pcall(function()
        return exports['custom-justice']:Imprison(target, mins, { text })
    end)
    if not ok or result ~= true then
        -- Fallback: metadata + qb-prison, still audited.
        pcall(function()
            player.Functions.SetMetaData('injail', mins)
            TriggerClientEvent('prison:client:Enter', player.PlayerData.source, mins)
        end)
    end
    MySQL.insert.await([[
        INSERT INTO police_arrests (citizenid, officer_citizenid, charges) VALUES (?, ?, ?)
    ]], { target, ('agent:%s'):format(tostring(actorId):sub(1, 40)), text })
    audit(actorId, 'arrest.register', target, ('%d min: %s'):format(mins, text))
    return { citizenid = target, minutes = mins, status = 'jailed' }
end

-- ---------------------------------------------------------------------------
-- P1 arrest submit: the single trusted entry point for an arrest.
-- No database transaction is used here on purpose: this repo's oxmysql backend
-- (resources/[standalone]/oxmysql/dist/build.js) exports only scalar/single/
-- query/insert/update/prepare/rawExecute and has NO `transaction` export, so
-- MySQL.transaction.await would call a nil export and fail at runtime. A real
-- transaction should replace the compensating rollback below as soon as the
-- backend implements one. Until then the report is written first and every
-- later failure deletes what was already written. The client never supplies
-- minutes or the fine: both are derived here from the shared charge catalogue,
-- and the citation amount is clamped to +/-20% of the catalogue base.
-- ---------------------------------------------------------------------------
local MIN_MINUTES = 1
local MAX_MINUTES = 120
local CITATION_LOW = 0.8
local CITATION_HIGH = 1.2

local function fail(error)
    return { ok = false, error = error }
end

local function auditPlayer(cid, action, target, detail)
    return pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, "player", ?, ?, ?)',
            { cid, action, target, detail and utf8Sub(tostring(detail), 500) or nil })
    end)
end

local function insertRow(sql, values)
    local ok, result = pcall(function() return MySQL.insert.await(sql, values) end)
    if not ok then return nil end
    local id = InsertId(result)
    return (id and id > 0) and id or nil
end

local function updateRow(sql, values)
    return pcall(function() return MySQL.update.await(sql, values) end)
end

--- Best-effort notification for the citation created by an arrest. The arrest
--- is already committed when this runs, so a failing notification is only
--- logged and never rolls the arrest back.
local function notifyCitation(citizenid, citationId, amount, reason, source)
    local title = '你收到一张罚单'
    local content = utf8Sub(
        ('你收到一张罚单 #%d，金额 $%d，罪名 %s'):format(citationId, amount, reason), 500)
    local ok, err = pcall(function()
        local result = MySQL.insert.await(
            'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)',
            { citizenid, title, content, 'banking' })
        local notificationId = InsertId(result)
        local src = tonumber(source)
        if not src or src <= 0 then return end
        TriggerClientEvent('phone:client:newNotification', src, {
            id = notificationId, title = title, content = content,
            timestamp = os.date('%Y-%m-%d %H:%M:%S'), is_read = false, app_id = 'banking',
        })
    end)
    if not ok then
        print(('[custom-police] citation notification failed for %s (citation #%s): %s'):format(
            tostring(citizenid), tostring(citationId), tostring(err)))
    end
end

local function encodeCharges(ids)
    local rows = {}
    for i, id in ipairs(ids) do
        local charge = PoliceCharges.Get(id)
        rows[i] = {
            id = id, label = charge.label,
            minutes = charge.baseMinutes, fine = charge.fine,
        }
    end
    local ok, encoded = pcall(json.encode, rows)
    if ok and type(encoded) == 'string' and encoded ~= '' then return encoded end
    return '[]'
end

local function deriveCitationAmount(base, requested)
    local low = math.ceil(base * CITATION_LOW)
    local high = math.floor(base * CITATION_HIGH)
    if high < low then high = low end
    local value
    if requested == nil then
        value = base
    else
        value = tonumber(requested)
        if not value then return nil, 'invalid_amount' end
        value = math.floor(value)
    end
    if value < low then value = low end
    if value > high then value = high end
    return value
end

--- Submit one arrest as a report: report + optional citation/evidence/case,
--- audited, then sentenced. Returns a table; the phone app wraps it into its
--- own { success, data } envelope.
---@param source number
---@param params table
---@return table { ok=true, report_id, minutes, fine, citation_id?, evidence_id?, case_id?, justice_case_id?, jailed=true }
function ArrestSubmit(source, params)
    local actorPlayer = QBCore.Functions.GetPlayer(tonumber(source) or 0)
    local actor = actorPlayer and actorPlayer.PlayerData
    local allowed, reason = PolicePolicy.Can(actor, 'arrest.create')
    if not allowed then return fail(reason or 'forbidden') end
    if type(params) ~= 'table' then return fail('invalid_params') end

    local target = trim(params.citizenid):sub(1, 50)
    if target == '' then return fail('invalid_citizen') end
    local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(target)
    if not targetPlayer then return fail('citizen_offline') end

    -- Physical preconditions: both peds must exist, the suspect must already be
    -- restrained (or down), the officer must be within arm's reach, and the
    -- suspect must not already be serving a sentence. The phone is not trusted
    -- for any of this.
    local targetData = targetPlayer.PlayerData or {}
    local targetSrc = tonumber(targetData.source)
    local actorPed = GetPlayerPed(tonumber(source) or 0)
    local targetPed = (targetSrc and targetSrc > 0) and GetPlayerPed(targetSrc) or 0
    if not actorPed or actorPed == 0 or not targetPed or targetPed == 0 then
        return fail('target_unavailable')
    end
    local metadata = type(targetData.metadata) == 'table' and targetData.metadata or {}
    if (tonumber(metadata.injail) or 0) > 0 then return fail('already_jailed') end
    if not (metadata.ishandcuffed == true or metadata.isdead == true or metadata.inlaststand == true) then
        return fail('target_not_cuffed')
    end
    if #(GetEntityCoords(actorPed) - GetEntityCoords(targetPed)) > 5.0 then
        return fail('too_far')
    end

    local rawIds = params.charge_ids
    if type(rawIds) ~= 'table' or #rawIds < 1 or #rawIds > PoliceCharges.MAX_CHARGES then
        return fail('invalid_charges')
    end
    local ids = {}
    for i = 1, #rawIds do
        local id = trim(rawIds[i])
        if id == '' then return fail('invalid_charge') end
        ids[i] = id
    end
    local sum, chargeError = PoliceCharges.Sum(ids)
    if not sum then return fail(chargeError or 'invalid_charges') end
    local minutes = math.max(MIN_MINUTES, math.min(MAX_MINUTES, math.floor(sum.minutes)))
    local details = utf8Sub(trim(params.details), 1000)

    local incidentId = tonumber(params.incident_id)
    if params.incident_id ~= nil and not incidentId then return fail('invalid_incident') end
    if incidentId then
        local incident = MySQL.single.await(
            'SELECT id FROM police_incidents WHERE id = ? LIMIT 1', { incidentId })
        if not incident then return fail('incident_not_found') end
    end

    local caseId = tonumber(params.case_id)
    if params.case_id ~= nil and not caseId then return fail('invalid_case') end
    if caseId and params.create_case == true then return fail('invalid_case_combination') end
    if caseId then
        local caseRow = MySQL.single.await(
            'SELECT id FROM police_cases WHERE id = ? LIMIT 1', { caseId })
        if not caseRow then return fail('case_not_found') end
    end
    local createCase = params.create_case == true
    if createCase then
        local canCase = PolicePolicy.Can(actor, 'case.create')
        if not canCase then return fail('case_forbidden') end
    end
    local openCase = params.open_case == true

    local bolo = params.bolo == true
    local boloKind, boloTarget = nil, nil
    if bolo then
        -- Filing a BOLO is a higher rank than filing the arrest report.
        local canBolo = PolicePolicy.Can(actor, 'bolo.create')
        if not canBolo then return fail('bolo_forbidden') end
        boloKind = trim(params.bolo_kind)
        if boloKind == '' then boloKind = 'person' end
        if boloKind ~= 'person' and boloKind ~= 'vehicle' then return fail('invalid_bolo_kind') end
        boloTarget = utf8Sub(trim(params.bolo_target), 50)
        if boloTarget == '' and boloKind == 'person' then boloTarget = target end
        if boloTarget == '' then return fail('invalid_bolo_target') end
    end

    local location = utf8Sub(trim(params.location), 120)
    if location == '' then location = nil end

    -- Default true (the phone always sends it explicitly), but `false` from the
    -- client is honoured.
    local createCitation = params.create_citation ~= false
    local fine = sum.fine
    local amount
    if createCitation then
        local amountError
        amount, amountError = deriveCitationAmount(sum.fine, params.citation_amount)
        if not amount then return fail(amountError or 'invalid_amount') end
        fine = amount
    end

    local createEvidence = params.create_evidence == true
    local evidenceLabel = utf8Sub(trim(params.evidence_label), 120)
    if createEvidence and #evidenceLabel < 3 then
        evidenceLabel = utf8Sub(('逮捕物证：%s'):format(table.concat(sum.labels, '、')), 120)
    end

    local title = utf8Sub(('逮捕 — %s'):format(table.concat(sum.labels, '、')), 160)
    local body = details
    if body == '' then
        body = utf8Sub(('罪名: %s；刑期: %d 分钟'):format(
            table.concat(sum.labels, '、'), minutes), 1000)
    end

    local reportId = insertRow([[
        INSERT INTO police_reports
            (incident_id, case_id, author_citizenid, title, body, status, kind, charges,
             is_bolo, bolo_kind, bolo_target, location, officer_citizenid, subject_citizenid)
        VALUES (?, ?, ?, ?, ?, 'submitted', 'arrest', ?, ?, ?, ?, ?, ?, ?)
    ]], { incidentId, caseId, actor.citizenid, title, body, encodeCharges(ids),
          bolo and 1 or 0, boloKind, boloTarget, location, actor.citizenid, target })
    if not reportId then return fail('db_error') end

    local created = { report = reportId, case = nil, citation = nil, evidence = nil }
    local function rollback()
        if created.evidence then
            pcall(function()
                MySQL.update.await(
                    'DELETE FROM police_evidence_chain WHERE evidence_id = ?', { created.evidence })
                MySQL.update.await(
                    'DELETE FROM police_evidence WHERE id = ?', { created.evidence })
            end)
        end
        if created.citation then
            pcall(function()
                MySQL.update.await(
                    'DELETE FROM police_citations WHERE id = ?', { created.citation })
            end)
        end
        if created.case then
            pcall(function()
                MySQL.update.await('DELETE FROM police_cases WHERE id = ?', { created.case })
            end)
        end
        pcall(function()
            MySQL.update.await('DELETE FROM police_reports WHERE id = ?', { reportId })
        end)
    end

    if createCase then
        local caseTitle = utf8Sub(('逮捕案件 — %s'):format(table.concat(sum.labels, '、')), 160)
        local summary = utf8Sub(('%s 因 %s 被捕（%d 分钟），主办警员 %s。'):format(
            target, table.concat(sum.labels, '、'), minutes, actor.citizenid), 2000)
        -- The lead is the officer who made the arrest; the suspect goes in the
        -- summary so case lists never show the arrested person as the owner.
        local newCaseId = insertRow(
            'INSERT INTO police_cases (title, summary, lead_citizenid, created_by) VALUES (?, ?, ?, ?)',
            { caseTitle, summary, actor.citizenid, actor.citizenid })
        if not newCaseId then
            rollback()
            return fail('case_create_failed')
        end
        created.case = newCaseId
        local caseNo = ('CASE-%s-%06d'):format(os.date('%Y'), newCaseId)
        if not updateRow('UPDATE police_cases SET case_no = ? WHERE id = ?', { caseNo, newCaseId }) then
            rollback()
            return fail('db_error')
        end
        created.caseNo = caseNo
        created.caseTitle = caseTitle
        caseId = newCaseId
    end

    if caseId then
        local linked = updateRow(
            'UPDATE police_reports SET case_id = ? WHERE id = ?', { caseId, reportId })
        if not linked then
            rollback()
            return fail('db_error')
        end
    end

    if createCitation then
        local citationReason = utf8Sub(table.concat(sum.labels, '、'), 240)
        local chargeId = table.concat(ids, ',')
        if #chargeId > 32 then chargeId = ids[1] end
        local citationId = insertRow([[
            INSERT INTO police_citations
                (citizenid, officer_citizenid, amount, reason, incident_id,
                 charge_id, base_amount, report_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ]], { target, actor.citizenid, amount, citationReason, incidentId,
              chargeId, sum.fine, reportId })
        if not citationId then
            rollback()
            return fail('db_error')
        end
        created.citation = citationId
        created.citationReason = citationReason
    end

    if createEvidence then
        local evidenceId = insertRow([[
            INSERT INTO police_evidence
                (exhibit_no, incident_id, report_id, case_id, label, description, location, collected_by)
            VALUES (NULL, ?, ?, ?, ?, ?, ?, ?)
        ]], { incidentId, reportId, caseId, evidenceLabel, details, location, actor.citizenid })
        if not evidenceId then
            rollback()
            return fail('db_error')
        end
        created.evidence = evidenceId
        local exhibitNo = ('EX-%06d'):format(evidenceId)
        local marked = updateRow(
            'UPDATE police_evidence SET exhibit_no = ? WHERE id = ?', { exhibitNo, evidenceId })
        local chained = marked and pcall(function()
            MySQL.insert.await(
                'INSERT INTO police_evidence_chain (evidence_id, action, actor_citizenid, note) VALUES (?, ?, ?, ?)',
                { evidenceId, 'collected', actor.citizenid, evidenceLabel })
        end)
        if not chained then
            rollback()
            return fail('db_error')
        end
    end

    -- Optional justice case link (open_case). Created after the report and its
    -- children exist and before the sentence: the justice case lives in
    -- custom-justice memory and has no rollback hook, so it must be the last
    -- write before the jail attempt (see the jail_failed branch below).
    if openCase then
        local opened, justiceCaseId = pcall(function()
            return exports['custom-justice']:OpenCase(target, source, ids)
        end)
        if not opened or not justiceCaseId or justiceCaseId == false then
            rollback()
            return fail('open_case_failed')
        end
        created.justiceCaseId = tostring(justiceCaseId)
        if not updateRow('UPDATE police_reports SET justice_case_id = ? WHERE id = ?',
                { created.justiceCaseId, reportId }) then
            rollback()
            return fail('db_error')
        end
    end

    -- Write the justice link back onto the report when it has no police case.
    -- police_reports.case_id is BIGINT UNSIGNED (it indexes police_cases) while
    -- justice case ids are strings ("CASE-0001"), so writing the string would
    -- fail on strict MariaDB or silently store 0 and corrupt the case join.
    -- Only a numeric id is written; the string id is still returned to the
    -- caller and recorded in the arrest audit below.
    if created.justiceCaseId and not caseId then
        local numericJusticeId = tonumber(created.justiceCaseId)
        if numericJusticeId then
            if not updateRow('UPDATE police_reports SET case_id = ? WHERE id = ?',
                    { numericJusticeId, reportId }) then
                rollback()
                return fail('db_error')
            end
        end
    end

    local auditDetail = ('%s | %d 分钟'):format(table.concat(sum.labels, '、'), minutes)
    if created.justiceCaseId then
        auditDetail = ('%s | justice:%s'):format(auditDetail, created.justiceCaseId)
    end
    local applied = false
    -- custom-justice keys its crime table by charge id, so pass the ids (not
    -- the display labels) and let it resolve the labels for its own logging.
    local justiceOk, justiceResult = pcall(function()
        return exports['custom-justice']:Imprison(target, minutes, ids)
    end)
    if justiceOk and justiceResult == true then
        applied = true
    else
        applied = pcall(function()
            targetPlayer.Functions.SetMetaData('injail', minutes)
            TriggerClientEvent('prison:client:Enter', targetPlayer.PlayerData.source, minutes)
        end)
    end
    if not applied then
        -- Nothing has been audited yet: drop every row this submit created and
        -- report the failed sentence, leaving no half-written arrest behind.
        -- A justice case opened above lives in custom-justice memory and cannot
        -- be rolled back from here; the caller gets jail_failed and the orphan
        -- case can be closed by a judge.
        rollback()
        return fail('jail_failed')
    end

    -- The sentence is applied and the citation row exists: tell the suspect.
    -- Kept after the rollback point so a failed arrest never notifies anyone,
    -- and inside a pcall so a phone/DB hiccup cannot undo the arrest.
    if created.citation then
        notifyCitation(target, created.citation, amount, created.citationReason, targetSrc)
    end

    -- Audit only once the sentence is actually applied. If an audit write fails
    -- we cannot roll back a sentence the suspect is already serving, so the
    -- caller gets audited=false semantics via error + jailed=true.
    local auditsOk = true
    if bolo then
        if not auditPlayer(actor.citizenid, 'bolo.create', boloTarget, boloKind .. boloTarget) then
            auditsOk = false
        end
    end
    if created.caseNo then
        if not auditPlayer(actor.citizenid, 'case.create', created.caseNo, created.caseTitle) then
            auditsOk = false
        end
    end
    if not auditPlayer(actor.citizenid, 'arrest.register', target, auditDetail) then
        auditsOk = false
    end
    if not auditsOk then
        return { ok = false, error = 'audit_unavailable', report_id = reportId, jailed = true }
    end

    local result = {
        ok = true, report_id = reportId, minutes = minutes,
        fine = fine, jailed = true, subject_citizenid = target,
    }
    if created.citation then result.citation_id = created.citation end
    if created.evidence then result.evidence_id = created.evidence end
    if created.justiceCaseId then result.justice_case_id = created.justiceCaseId end
    if caseId then result.case_id = caseId end
    return result
end

--- Submit a written report (P3): body + optional evidence + optional BOLO tag.
--- The report is the anchor row: evidence/BOLO preconditions are validated
--- before the insert where possible, but any failure after the insert rolls the
--- report (and its evidence) back. The bundled oxmysql has no transaction
--- export (see the note above ArrestSubmit), hence the compensating deletes.
---@param source number
---@param params table
---@return table { ok=true, report_id, evidence_id?, bolo=boolean } | { ok=false, error }
function ReportSubmit(source, params)
    local actorPlayer = QBCore.Functions.GetPlayer(tonumber(source) or 0)
    local actor = actorPlayer and actorPlayer.PlayerData
    local allowed, reason = PolicePolicy.Can(actor, 'report.create')
    if not allowed then return fail(reason or 'forbidden') end
    if type(params) ~= 'table' then return fail('invalid_params') end

    local title = utf8Sub(trim(params.title), 160)
    if #title < 3 then return fail('invalid_title') end
    local body = utf8Sub(trim(params.body), 4000)
    if #body < 10 then return fail('invalid_body') end

    local subject = trim(params.citizenid)
    if subject ~= '' then subject = utf8Sub(subject, 50) else subject = nil end

    local incidentId = tonumber(params.incident_id)
    if params.incident_id ~= nil and not incidentId then return fail('invalid_incident') end
    if incidentId then
        local incident = MySQL.single.await(
            'SELECT id FROM police_incidents WHERE id = ? LIMIT 1', { incidentId })
        if not incident then return fail('incident_not_found') end
    end

    local caseId = tonumber(params.case_id)
    if params.case_id ~= nil and not caseId then return fail('invalid_case') end
    if caseId then
        local caseRow = MySQL.single.await(
            'SELECT id FROM police_cases WHERE id = ? LIMIT 1', { caseId })
        if not caseRow then return fail('case_not_found') end
    end

    local location = utf8Sub(trim(params.location), 120)
    if location == '' then location = nil end

    local createEvidence = params.evidence == true
    local evidenceLabel = utf8Sub(trim(params.evidence_label), 120)
    if createEvidence and params.evidence_label ~= nil and #evidenceLabel < 3 then
        return fail('invalid_evidence_label')
    end
    if createEvidence and evidenceLabel == '' then
        evidenceLabel = utf8Sub(('报告证据：%s'):format(title), 120)
    end
    local evidenceDescription = utf8Sub(trim(params.evidence_description), 1000)
    if createEvidence and evidenceDescription == '' then evidenceDescription = body end

    local bolo = params.bolo == true
    local boloKind, boloTarget, boloReason
    if bolo then
        -- Tagging a BOLO is a higher rank than filing the report itself.
        local canBolo = PolicePolicy.Can(actor, 'bolo.create')
        if not canBolo then return fail('bolo_forbidden') end
        boloKind = trim(params.bolo_kind)
        if boloKind == '' then boloKind = 'person' end
        if boloKind ~= 'person' and boloKind ~= 'vehicle' then return fail('invalid_bolo_kind') end
        boloTarget = utf8Sub(trim(params.bolo_target), 50)
        if boloTarget == '' and boloKind == 'person' and subject then boloTarget = subject end
        if boloTarget == '' then return fail('invalid_bolo_target') end
        boloReason = utf8Sub(trim(params.bolo_reason), 500)
        if boloReason == '' then boloReason = title end
    end

    local reportId = insertRow([[
        INSERT INTO police_reports
            (kind, incident_id, case_id, subject_citizenid, author_citizenid, title, body,
             location, officer_citizenid, is_bolo, bolo_kind, bolo_target)
        VALUES ('report', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], { incidentId, caseId, subject, actor.citizenid, title, body, location,
          actor.citizenid, bolo and 1 or 0, boloKind, boloTarget })
    if not reportId then return fail('db_error') end

    local evidenceId, exhibitNo
    local function rollback()
        if evidenceId then
            pcall(function()
                MySQL.update.await(
                    'DELETE FROM police_evidence_chain WHERE evidence_id = ?', { evidenceId })
                MySQL.update.await('DELETE FROM police_evidence WHERE id = ?', { evidenceId })
            end)
        end
        pcall(function()
            MySQL.update.await('DELETE FROM police_reports WHERE id = ?', { reportId })
        end)
    end

    if createEvidence then
        evidenceId = insertRow([[
            INSERT INTO police_evidence
                (exhibit_no, report_id, case_id, incident_id, label, description, location, collected_by)
            VALUES (NULL, ?, ?, ?, ?, ?, ?, ?)
        ]], { reportId, caseId, incidentId, evidenceLabel, evidenceDescription, location,
              actor.citizenid })
        if not evidenceId then
            rollback()
            return fail('db_error')
        end
        exhibitNo = ('EX-%06d'):format(evidenceId)
        local marked = updateRow(
            'UPDATE police_evidence SET exhibit_no = ? WHERE id = ?', { exhibitNo, evidenceId })
        local chained = marked and pcall(function()
            MySQL.insert.await(
                'INSERT INTO police_evidence_chain (evidence_id, action, actor_citizenid, note) VALUES (?, ?, ?, ?)',
                { evidenceId, 'collected', actor.citizenid, evidenceLabel })
        end)
        if not chained then
            rollback()
            return fail('db_error')
        end
    end

    local auditsOk = true
    if not auditPlayer(actor.citizenid, 'report.create', tostring(reportId), title) then
        auditsOk = false
    end
    if evidenceId and not auditPlayer(actor.citizenid, 'evidence.register', exhibitNo, evidenceLabel) then
        auditsOk = false
    end
    if bolo and not auditPlayer(actor.citizenid, 'bolo.create', boloTarget, boloKind .. ':' .. boloReason) then
        auditsOk = false
    end
    if not auditsOk then
        rollback()
        return fail('audit_unavailable')
    end

    return { ok = true, report_id = reportId, evidence_id = evidenceId, bolo = bolo }
end

exports('CreateIncidentSystem', Sys.CreateIncident)
exports('AssignUnitSystem', Sys.AssignUnit)
exports('JailSystem', Sys.Jail)
exports('ArrestSubmit', ArrestSubmit)
exports('ReportSubmit', ReportSubmit)
exports('GetCharges', function()
    local charges = {}
    for i, charge in ipairs(PoliceCharges.List()) do
        charges[i] = {
            id = charge.id, label = charge.label,
            minutes = charge.baseMinutes, fine = charge.fine,
        }
    end
    return { charges = charges }
end)
print('[custom-police] P4 system entry points + arrest submit loaded')


-- Ops command: release a jailed player and optionally restore their job.
-- Console (source 0) or an ACE-allowed admin only.
RegisterCommand('police_release', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'police.release') then return end
    local target = tonumber(args and args[1])
    if not target then return print('usage: police_release <serverId> [job] [grade]') end
    local player = QBCore.Functions.GetPlayer(target)
    if not player then return print('player not found') end
    player.Functions.SetMetaData('injail', 0)
    TriggerClientEvent('prison:client:UnjailPerson', target)
    local job = args[2]
    if job and job ~= '' then
        local okJob, errJob
        if Bus and Bus.JobService and type(Bus.JobService.SetJob) == 'function' then
            okJob, errJob = Bus.JobService.SetJob(target, job, args[3] or '0', 'police_release')
        else
            okJob, errJob = player.Functions.SetJob(job, args[3] or '0')
        end
        print(('[custom-police] SetJob(%s,%s) -> %s %s'):format(job, tostring(args[3]), tostring(okJob), tostring(errJob)))
    end
    print(('[custom-police] released %s%s'):format(target, job and (' -> ' .. job) or ''))
end, true)


-- Ops: force-save one player (console/ACE admin), e.g. after setjob so a
-- reconnect does not load a stale job from the database.
RegisterCommand('force_save', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'police.release') then return end
    local target = tonumber(args and args[1])
    local player = target and QBCore.Functions.GetPlayer(target)
    if not player then return print('usage: force_save <serverId>') end
    player.Functions.Save(true)
    print(('[custom-police] saved player %s'):format(target))
end, true)
