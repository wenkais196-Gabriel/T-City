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

local function audit(cid, action, target, detail)
    return pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, "player", ?, ?, ?)',
            { cid, action, target, detail and tostring(detail):sub(1, 500) or nil })
    end)
end

local function notifyCitizen(citizenid, title, content)
    MySQL.insert.await(
        'INSERT INTO phone_notifications (citizenid, title, content) VALUES (?, ?, ?)',
        { citizenid, title:sub(1, 200), content:sub(1, 500) })
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local d = pd(src)
        if d and d.citizenid == citizenid then
            TriggerClientEvent('phone:client:newNotification', src, {
                id = 0, title = title:sub(1, 200), content = content:sub(1, 500),
                timestamp = os.date('%Y-%m-%d %H:%M:%S'), is_read = false,
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
    if not id then return false, 'db_error' end
    audit(actor.citizenid, 'citation.issue', target, ('$%d %s'):format(amount, text))
    notifyCitizen(target, '你收到一张罚单', ('$%d — %s（警官 %s）'):format(amount, text, actor.citizenid))
    return { id = tonumber(id), amount = math.floor(amount), status = 'unpaid' }
end

function P1.GetCitations(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'citation.view')
    if not allowed then return false, reason end
    local rows
    if params and params.citizenid and params.citizenid ~= '' then
        rows = MySQL.query.await(
            'SELECT * FROM police_citations WHERE citizenid = ? ORDER BY id DESC LIMIT 50',
            { tostring(params.citizenid):sub(1, 50) })
    else
        rows = MySQL.query.await('SELECT * FROM police_citations ORDER BY id DESC LIMIT 50')
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
    if not id then return false, 'db_error' end
    audit(actor.citizenid, 'report.create', tostring(id), title)
    return { id = tonumber(id), status = 'submitted' }
end

function P1.GetReports(source, params)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'report.view')
    if not allowed then return false, reason end
    local rows
    if params and params.case_id then
        rows = MySQL.query.await(
            'SELECT * FROM police_reports WHERE case_id = ? ORDER BY id DESC LIMIT 50',
            { tonumber(params.case_id) })
    elseif params and params.incident_id then
        rows = MySQL.query.await(
            'SELECT * FROM police_reports WHERE incident_id = ? ORDER BY id DESC LIMIT 50',
            { tonumber(params.incident_id) })
    else
        rows = MySQL.query.await('SELECT * FROM police_reports ORDER BY id DESC LIMIT 50')
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
    local ok, removed = pcall(function()
        return player.Functions.RemoveMoney('bank', amount, 'police-citation')
    end)
    if not ok or not removed then return false, 'insufficient_funds' end
    MySQL.update.await("UPDATE police_citations SET status = 'paid', paid_at = NOW() WHERE id = ? AND status = 'unpaid'", { id })
    audit(actor.citizenid, 'citation.pay', tostring(id), ('$%d'):format(amount))
    return { id = id, amount = amount, status = 'paid' }
end

exports('IssueCitation', P1.IssueCitation)
exports('PayCitation', P1.PayCitation)
exports('GetCitations', P1.GetCitations)
exports('CreateReport', P1.CreateReport)
exports('GetReports', P1.GetReports)
print('[custom-police] P1 citations/reports loaded')
