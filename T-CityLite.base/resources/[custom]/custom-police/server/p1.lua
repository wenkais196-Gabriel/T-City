-- server/p1.lua — citations and reports (P1).
local QBCore = exports['qb-core']:GetCoreObject()
local P1 = {}

local function pd(source)
    local p = QBCore.Functions.GetPlayer(source)
    return p and p.PlayerData or nil
end

local function trim(v)
    return type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
end

--- The bundled oxmysql build returns `{ affectedRows = n }` for update; stock
--- builds return a number. Normalise both so the conditional claim below can
--- tell "this caller transitioned the row" from "somebody else already did".
local function affectedRows(result)
    if type(result) == 'number' then return result end
    if type(result) == 'table' then return math.floor(tonumber(result.affectedRows) or 0) end
    return 0
end

local function audit(cid, action, target, detail)
    return pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, "player", ?, ?, ?)',
            { cid, action, target, detail and tostring(detail):sub(1, 500) or nil })
    end)
end

local function notifyCitizen(citizenid, title, content, appId)
    local result = MySQL.insert.await(
        'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)',
        { citizenid, title:sub(1, 200), content:sub(1, 500), appId })
    local notificationId = InsertId(result)
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local d = pd(src)
        if d and d.citizenid == citizenid then
            TriggerClientEvent('phone:client:newNotification', src, {
                id = notificationId, title = title:sub(1, 200), content = content:sub(1, 500),
                timestamp = os.date('%Y-%m-%d %H:%M:%S'), is_read = false, app_id = appId,
            })
        end
    end
end

function P1.IssueCitation(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'citation.issue')
    if not allowed then return false, reason end
    local target = tostring(params and params.citizenid or ''):sub(1, 50)
    local amount = tonumber(params and params.amount)
    local text = trim(params and params.reason):sub(1, 240)
    if target == '' then return false, 'invalid_citizen' end
    if not amount or amount < 1 or amount > 50000 then return false, 'invalid_amount' end
    if #text < 3 then return false, 'invalid_reason' end
    local exists = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ? LIMIT 1', { target })
    if not exists then return false, 'citizen_not_found' end
    local plate = trim(params and params.plate):upper():sub(1, 12)
    local id = MySQL.insert.await([[
        INSERT INTO police_citations (citizenid, officer_citizenid, plate, amount, reason, incident_id)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { target, actor.citizenid, plate ~= '' and plate or nil, math.floor(amount), text,
          tonumber(params and params.incident_id) })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    if not audit(actor.citizenid, 'citation.issue', target, ('$%d %s'):format(amount, text)) then
        print(('[custom-police] citation.issue audit failed for #%s'):format(tostring(id)))
    end
    notifyCitizen(target, '你收到一张罚单',
        ('$%d — %s（罚单 #%d，警官 %s）'):format(
            math.floor(amount), text, tonumber(id), actor.citizenid),
        'banking')
    return { id = tonumber(id), amount = math.floor(amount), status = 'unpaid' }
end

--- Citizen-side read: any online player may list their own citations. There is
--- deliberately no police capability check here; ownership is the caller's
--- citizenid, so a player can never read somebody else's tickets.
function P1.GetMyCitations(source)
    local actor = pd(source)
    if not actor or not actor.citizenid then return { rows = {}, count = 0 } end
    local rows = MySQL.query.await(
        'SELECT id, amount, reason, status, plate, incident_id, created_at FROM police_citations WHERE citizenid = ? ORDER BY id DESC LIMIT 50',
        { actor.citizenid })
    rows = rows or {}
    return { rows = rows, count = #rows }
end

function P1.GetCitations(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'citation.view')
    if not allowed then return false, reason end
    local target = params and params.citizenid and params.citizenid ~= ''
        and tostring(params.citizenid):sub(1, 50) or nil
    -- FIT-05: citations are a sensitive read, so the forensic row is written
    -- before the query. If audit is unavailable the read is refused rather than
    -- silently unaudited.
    if not audit(actor.citizenid, 'citation.view', target or 'all', nil) then
        return false, 'audit_unavailable'
    end
    local rows
    if target then
        rows = MySQL.query.await(
            'SELECT id, citizenid, officer_citizenid, plate, amount, charge_id, base_amount, reason, status, incident_id, report_id, created_at, paid_at FROM police_citations WHERE citizenid = ? ORDER BY id DESC LIMIT 50',
            { target })
    else
        rows = MySQL.query.await(
            'SELECT id, citizenid, officer_citizenid, plate, amount, charge_id, base_amount, reason, status, incident_id, report_id, created_at, paid_at FROM police_citations ORDER BY id DESC LIMIT 50')
    end
    return { rows = rows or {}, count = #(rows or {}) }
end

function P1.CreateReport(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'report.create')
    if not allowed then return false, reason end
    local title = trim(params and params.title):sub(1, 160)
    local body = trim(params and params.body):sub(1, 4000)
    if #title < 3 then return false, 'invalid_title' end
    if #body < 10 then return false, 'invalid_body' end
    local caseId = tonumber(params and params.case_id)
    if caseId then
        local caseRow = MySQL.single.await('SELECT id FROM police_cases WHERE id = ? LIMIT 1', { caseId })
        if not caseRow then return false, 'case_not_found' end
    end
    local id = MySQL.insert.await(
        'INSERT INTO police_reports (incident_id, case_id, author_citizenid, title, body) VALUES (?, ?, ?, ?, ?)',
        { tonumber(params and params.incident_id), caseId, actor.citizenid, title, body })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    if not audit(actor.citizenid, 'report.create', tostring(id), title) then
        print(('[custom-police] report.create audit failed for #%s'):format(tostring(id)))
    end
    return { id = tonumber(id), status = 'submitted' }
end

function P1.GetReports(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'report.view')
    if not allowed then return false, reason end
    local byCase = params and params.case_id
    local byIncident = params and params.incident_id
    local target = 'all'
    if byCase then
        target = ('case:%s'):format(tostring(byCase))
    elseif byIncident then
        target = ('incident:%s'):format(tostring(byIncident))
    end
    -- FIT-05: same fail-closed contract as GetCitations.
    if not audit(actor.citizenid, 'report.view', target:sub(1, 64), nil) then
        return false, 'audit_unavailable'
    end
    local rows
    if byCase then
        rows = MySQL.query.await(
            'SELECT id, incident_id, case_id, kind, subject_citizenid, author_citizenid, officer_citizenid, title, status, charges, is_bolo, bolo_kind, bolo_target, location, justice_case_id, justice_verdict, justice_status, created_at, updated_at FROM police_reports WHERE case_id = ? ORDER BY id DESC LIMIT 50',
            { tonumber(byCase) })
    elseif byIncident then
        rows = MySQL.query.await(
            'SELECT id, incident_id, case_id, kind, subject_citizenid, author_citizenid, officer_citizenid, title, status, charges, is_bolo, bolo_kind, bolo_target, location, justice_case_id, justice_verdict, justice_status, created_at, updated_at FROM police_reports WHERE incident_id = ? ORDER BY id DESC LIMIT 50',
            { tonumber(byIncident) })
    else
        rows = MySQL.query.await(
            'SELECT id, incident_id, case_id, kind, subject_citizenid, author_citizenid, officer_citizenid, title, status, charges, is_bolo, bolo_kind, bolo_target, location, justice_case_id, justice_verdict, justice_status, created_at, updated_at FROM police_reports ORDER BY id DESC LIMIT 50')
    end
    return { rows = rows or {}, count = #(rows or {}) }
end

--- Pay one's own citation from the bank account. No police capability: this
--- is the citizen side, and ownership is checked against the citation row.
function P1.PayCitation(source, citationId)
    local player = QBCore.Functions.GetPlayer(source)
    local actor = player and player.PlayerData
    if not actor then return false, 'player_not_found' end
    local id = tonumber(citationId)
    if not id then return false, 'invalid_citation' end
    local row = MySQL.single.await(
        'SELECT id, citizenid, amount, status FROM police_citations WHERE id = ? LIMIT 1', { id })
    if not row then return false, 'not_found' end
    if row.citizenid ~= actor.citizenid then return false, 'not_owner' end
    if row.status ~= 'unpaid' then return false, 'already_' .. tostring(row.status) end
    local amount = tonumber(row.amount) or 0

    -- Claim the row before moving money. Two concurrent payers can both pass
    -- the SELECT above, but only one conditional UPDATE matches `unpaid`; the
    -- loser never reaches RemoveMoney, so a double tap cannot double-charge.
    local claimOk, claim = pcall(function()
        return MySQL.update.await(
            "UPDATE police_citations SET status = 'paid', paid_at = NOW() WHERE id = ? AND citizenid = ? AND status = 'unpaid'",
            { id, actor.citizenid })
    end)
    if not claimOk or affectedRows(claim) == 0 then
        -- Re-read to tell "gone", "not yours" and "already paid/void" apart.
        local current = MySQL.single.await(
            'SELECT id, citizenid, status FROM police_citations WHERE id = ? LIMIT 1', { id })
        if not current then return false, 'not_found' end
        if current.citizenid ~= actor.citizenid then return false, 'not_owner' end
        if current.status ~= 'unpaid' then return false, 'already_' .. tostring(current.status) end
        return false, claimOk and 'not_found' or 'db_error'
    end

    local ok, removed = pcall(function()
        return player.Functions.RemoveMoney('bank', amount, 'police-citation')
    end)
    if not ok or not removed then
        -- The claim did not charge anyone yet: put the citation back so the
        -- owner can retry after topping up the bank account.
        pcall(function()
            MySQL.update.await(
                "UPDATE police_citations SET status = 'unpaid', paid_at = NULL WHERE id = ? AND status = 'paid'",
                { id })
        end)
        return false, 'insufficient_funds'
    end
    if not audit(actor.citizenid, 'citation.pay', tostring(id), ('$%d'):format(amount)) then
        -- The money already moved; a missing audit row is logged, not rolled back.
        print(('[custom-police] citation.pay audit failed for #%d'):format(id))
    end
    return { id = id, amount = amount, status = 'paid' }
end

exports('IssueCitation', P1.IssueCitation)
exports('PayCitation', P1.PayCitation)
exports('GetCitations', P1.GetCitations)
exports('GetMyCitations', P1.GetMyCitations)
exports('CreateReport', P1.CreateReport)
exports('GetReports', P1.GetReports)
print('[custom-police] P1 citations/reports loaded')
