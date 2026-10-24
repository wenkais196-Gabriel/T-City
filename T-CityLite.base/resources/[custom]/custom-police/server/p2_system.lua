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

-- ---------------------------------------------------------------------------
-- Outbox (v3.12 police_outbox). Notifications belong to custom-phone (FIT-02),
-- so police never writes `phone_notifications` directly any more. Enqueue is the
-- durable part; a worker delivers it with exponential backoff, so a phone
-- restart or a transient export failure does not silently drop a dispatch or a
-- citation notification. This backend has no transaction export, so the outbox
-- is the compensation (see docs/police/architecture/09-outbox.md).
-- ---------------------------------------------------------------------------
local OUTBOX_TOPIC_NOTIFICATION = 'notification'
local OUTBOX_INTERVAL_MS = 30000
local OUTBOX_MAX_ATTEMPTS = 5
local OUTBOX_BACKOFF_SECONDS = { 30, 120, 600 }
local OUTBOX_TOPICS = { [OUTBOX_TOPIC_NOTIFICATION] = true }

Outbox = Outbox or {}
local outboxKickRunning = false

local function outboxEncode(payload)
    local ok, encoded = pcall(json.encode, payload)
    if ok and type(encoded) == 'string' then return encoded end
    return nil
end

local function outboxFail(row, attempts, reason)
    local id = tonumber(row and row.id)
    if not id then return false end
    local nextAttempts = attempts + 1
    if nextAttempts >= OUTBOX_MAX_ATTEMPTS then
        pcall(function()
            MySQL.update.await(
                "UPDATE police_outbox SET status = 'failed', attempts = ?, next_attempt_at = NULL WHERE id = ?",
                { nextAttempts, id })
        end)
        print(('[custom-police] outbox #%d failed permanently after %d attempts: %s'):format(
            id, nextAttempts, tostring(reason)))
        return false
    end
    -- 30s / 2m / 10m; the table only holds numbers from this list, so the
    -- parameter never originates from a client.
    local delay = OUTBOX_BACKOFF_SECONDS[nextAttempts]
        or OUTBOX_BACKOFF_SECONDS[#OUTBOX_BACKOFF_SECONDS]
    pcall(function()
        MySQL.update.await(
            "UPDATE police_outbox SET status = 'pending', attempts = ?, next_attempt_at = DATE_ADD(NOW(), INTERVAL ? SECOND) WHERE id = ?",
            { nextAttempts, delay, id })
    end)
    return false
end

--- Delete old delivered/given-up rows; the worker also calls this before each
--- batch so the table cannot grow without bound.
function Outbox.Cleanup()
    pcall(function()
        MySQL.update.await(
            "DELETE FROM police_outbox WHERE status IN ('done', 'failed') AND updated_at < NOW() - INTERVAL 7 DAY LIMIT 200")
    end)
end

--- Queue one durable delivery. Returns false when the row could not be written;
--- the caller decides whether that is fatal (notifications are best-effort).
---@param topic string
---@param payload table
---@return boolean ok, number|nil id
function Outbox.Enqueue(topic, payload)
    if type(topic) ~= 'string' or not OUTBOX_TOPICS[topic] then return false end
    if type(payload) ~= 'table' then return false end
    local encoded = outboxEncode(payload)
    if not encoded then return false end

    local enqueued, result = pcall(function()
        return MySQL.insert.await(
            "INSERT INTO police_outbox (topic, payload, status, attempts, next_attempt_at) VALUES (?, ?, 'pending', 0, NOW())",
            { topic, encoded })
    end)
    if not enqueued then
        print(('[custom-police] outbox enqueue failed (%s): %s'):format(topic, tostring(result)))
        return false
    end
    Outbox.Kick()
    return true, InsertId(result)
end

--- Deliver one row and persist its new state. A short lease prevents an
--- overlapping worker from pushing the same row twice: if this process dies
--- mid-delivery, the row becomes eligible again after 60 seconds.
---@param row table
---@return boolean delivered
function Outbox.Deliver(row)
    local id = tonumber(row and row.id)
    if not id then return false end
    local attempts = math.floor(tonumber(row.attempts) or 0)
    local topic = tostring(row.topic or '')

    local decoded, payload = pcall(json.decode, tostring(row.payload or ''))
    if not decoded or type(payload) ~= 'table' then
        return outboxFail(row, attempts, 'invalid_payload')
    end
    if not OUTBOX_TOPICS[topic] then
        return outboxFail(row, attempts, 'unknown_topic')
    end

    pcall(function()
        MySQL.update.await(
            'UPDATE police_outbox SET next_attempt_at = DATE_ADD(NOW(), INTERVAL 60 SECOND) WHERE id = ?',
            { id })
    end)

    -- `source` is intentionally not trusted from the stored payload: a stale
    -- server id can be reassigned, so the owner resolves the citizen again.
    local called, delivered = pcall(function()
        return exports['custom-phone']:Notify(
            payload.citizenid, payload.title, payload.content, payload.app_id)
    end)
    if not called or not delivered then
        return outboxFail(row, attempts, called and 'notify_rejected' or tostring(delivered))
    end

    pcall(function()
        MySQL.update.await(
            "UPDATE police_outbox SET status = 'done', attempts = ?, next_attempt_at = NULL WHERE id = ?",
            { attempts + 1, id })
    end)
    return true
end

--- Drain up to 50 due rows. Safe to call from the loop, the export or a test;
--- the busy flag keeps overlapping callers from double-processing.
---@return number processed
function Outbox.Work()
    if Outbox.busy then return 0 end
    Outbox.busy = true
    local processed = 0
    local ok, err = pcall(function()
        Outbox.Cleanup()
        local rows = MySQL.query.await([[
            SELECT id, topic, payload, attempts
              FROM police_outbox
             WHERE status = 'pending'
               AND (next_attempt_at IS NULL OR next_attempt_at <= NOW())
             ORDER BY id ASC
             LIMIT 50
        ]])
        for _, row in ipairs(rows or {}) do
            processed = processed + 1
            Outbox.Deliver(row)
        end
    end)
    Outbox.busy = false
    if not ok then
        print(('[custom-police] outbox worker failed: %s'):format(tostring(err)))
    end
    return processed
end

--- Run the worker once as soon as possible after an enqueue, so a notification
--- is still near-instant; the 30s loop is only the retry safety net.
function Outbox.Kick()
    Outbox.kicked = true
    if outboxKickRunning then return end
    outboxKickRunning = true
    CreateThread(function()
        while Outbox.kicked do
            Outbox.kicked = false
            Outbox.Work()
        end
        outboxKickRunning = false
        -- An enqueue that landed while the loop was exiting must still wake a
        -- worker; otherwise it would wait for the 30s tick.
        if Outbox.kicked then Outbox.Kick() end
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(5000)
        while true do
            Outbox.Work()
            Wait(OUTBOX_INTERVAL_MS)
        end
    end)
end)

local function broadcast(title, content)
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if d and type(d.job) == 'table' and d.job.name == 'police' and d.job.onduty == true then
            Outbox.Enqueue(OUTBOX_TOPIC_NOTIFICATION, {
                citizenid = d.citizenid,
                title = utf8Sub(title, 200),
                content = utf8Sub(content, 500),
                app_id = 'police_mdt',
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
    if not audit(actorId, 'arrest.register', target, ('%d min: %s'):format(mins, text)) then
        -- The arrest row is already written; the missing audit row is reported,
        -- never silently dropped (FIT-05: best-effort writes must be logged).
        print(('[custom-police] arrest.register audit failed for %s'):format(tostring(target)))
    end
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

-- ---------------------------------------------------------------------------
-- Idempotency ledger (v3.9 police_write_intents + v3.12 TTL). ArrestSubmit and
-- ReportSubmit are multi-table writes and the bundled oxmysql has no transaction
-- export, so a retry after a timeout or a double tap can otherwise write a
-- second report and citation. The phone sends an `idempotency_key`; the key is
-- claimed before any row is touched, `done` replays the cached result, and a
-- failed submit frees the key so a corrected retry can reuse it.
--
-- v3.12 TTL semantics:
--   * a `done` result is valid for 7 days (`expires_at`); after that the row is
--     swept and the key may be claimed again, so a stale replay cannot resurrect
--     a week-old result;
--   * a `pending` row older than 10 minutes is treated as a crashed submit and
--     deleted (the submit's own rollback already ran or is unrecoverable), which
--     frees the key instead of blocking it forever;
--   * `failed` rows are swept immediately.
-- The sweep runs on resource start and on every claim, limited to 200 rows so it
-- stays a cheap indexed delete.
-- ---------------------------------------------------------------------------
local INTENT_KEY_MIN = 8
local INTENT_KEY_MAX = 128
-- Client keys are opaque; the contract is ^[A-Za-z0-9_-]{8,128}$. Lua patterns
-- have no {n,m}, so the length is checked separately from the character set.
local INTENT_KEY_PATTERN = '^[A-Za-z0-9_%-]+$'

local function validIntentKey(key)
    return type(key) == 'string'
        and #key >= INTENT_KEY_MIN and #key <= INTENT_KEY_MAX
        and key:match(INTENT_KEY_PATTERN) ~= nil
end

local function deleteIntent(key)
    pcall(function()
        MySQL.update.await('DELETE FROM police_write_intents WHERE idem_key = ?', { key })
    end)
end

--- Delete expired done rows, stale pending rows and failed rows. Called on
--- start and before every claim; the LIMIT keeps it cheap on a large table.
local function sweepIntents()
    pcall(function()
        MySQL.update.await([[
            DELETE FROM police_write_intents
             WHERE (status = 'done'
                    AND COALESCE(expires_at, created_at + INTERVAL 7 DAY) < NOW())
                OR (status = 'pending' AND created_at < NOW() - INTERVAL 10 MINUTE)
                OR status = 'failed'
             LIMIT 200
        ]])
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    sweepIntents()
end)

local function decodeIntentResult(row)
    if type(row) ~= 'table' or type(row.result_json) ~= 'string' then return nil end
    local ok, decoded = pcall(json.decode, row.result_json)
    if ok and type(decoded) == 'table' then return decoded end
    return nil
end

--- oxmysql returns TINYINT expressions as numbers; stock builds may return a
--- boolean/string. Normalise so the branches below read the same.
local function dbFlag(value)
    return value == true or value == 1 or value == '1'
end

--- Run `fn` at most once per client-supplied key.
--- Without a key the call is unchanged (backward compatible). With a key:
---   * invalid format → `invalid_idempotency_key`;
---   * a live `done` row replays its cached result (7-day TTL);
---   * a `pending` row is a concurrent/submitted duplicate → `in_progress`,
---     unless it is older than 10 minutes (crash) → swept and reclaimed;
---   * a `failed` row is deleted and claimed again;
---   * `ok=false` or an exception deletes the row (no caching of failures).
---@param action string
---@param actorCid string
---@param key string|nil
---@param fn function
---@return table
local function withIntent(action, actorCid, key, fn)
    if key == nil or key == '' then return fn() end
    if not validIntentKey(key) then return fail('invalid_idempotency_key') end
    actorCid = tostring(actorCid or ''):sub(1, 50)

    sweepIntents()

    for _ = 1, 2 do
        -- Claim first: a duplicate INSERT raises, which is the concurrency guard.
        local claimed = pcall(function()
            MySQL.insert.await(
                'INSERT INTO police_write_intents (idem_key, action, actor_citizenid) VALUES (?, ?, ?)',
                { key, action, actorCid })
        end)
        if claimed then
            local ok, result = pcall(fn)
            if not ok then
                -- The write may have been partial; free the key so a retry can
                -- run the submit's own compensating rollback again.
                deleteIntent(key)
                print(('[custom-police] %s intent %s failed: %s'):format(
                    tostring(action), tostring(key), tostring(result)))
                return fail('db_error')
            end
            if type(result) ~= 'table' or result.ok ~= true then
                -- Validation/business failure: the submit rolled its own rows
                -- back, so the key must not block a corrected retry.
                deleteIntent(key)
                return result
            end
            local encodedOk, encoded = pcall(json.encode, result)
            if not encodedOk or type(encoded) ~= 'string' then
                -- The business write is committed; dropping the row would
                -- duplicate it on retry, so keep it done without a result.
                pcall(function()
                    MySQL.update.await(
                        "UPDATE police_write_intents SET status = 'done', completed_at = NOW(), expires_at = NOW() + INTERVAL 7 DAY WHERE idem_key = ?",
                        { key })
                end)
                return result
            end
            pcall(function()
                MySQL.update.await(
                    "UPDATE police_write_intents SET status = 'done', result_json = ?, completed_at = NOW(), expires_at = NOW() + INTERVAL 7 DAY WHERE idem_key = ?",
                    { encoded, key })
            end)
            return result
        end

        local selectOk, existing = pcall(function()
            return MySQL.single.await([[
                SELECT idem_key, status, result_json,
                       (status = 'pending' AND created_at < NOW() - INTERVAL 10 MINUTE) AS stale_pending,
                       (status = 'done'
                        AND COALESCE(expires_at, created_at + INTERVAL 7 DAY) < NOW()) AS expired
                  FROM police_write_intents
                 WHERE idem_key = ?
                 LIMIT 1
            ]], { key })
        end)
        if not selectOk then return fail('db_error') end
        if not existing then
            -- The row vanished between INSERT and SELECT (TTL sweep or a
            -- concurrent failure); try to claim it again.
        elseif existing.status == 'done' then
            if dbFlag(existing.expired) then
                -- 7-day TTL elapsed: drop the stale result and let this call
                -- claim the key again (the sweep may have been truncated).
                deleteIntent(key)
            else
                local cached = decodeIntentResult(existing)
                if cached then return cached end
                -- A done row without a decodable result cannot be replayed
                -- without duplicating the committed write.
                return fail('db_error')
            end
        elseif existing.status == 'pending' then
            if dbFlag(existing.stale_pending) then
                -- The claiming process died mid-submit. Its compensating
                -- rollback may have run; holding the key forever would make
                -- every retry `in_progress`, so free it and reclaim.
                deleteIntent(key)
            else
                return fail('in_progress')
            end
        else
            -- failed: drop the old row and claim again.
            deleteIntent(key)
        end
    end
    return fail('in_progress')
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

-- ---------------------------------------------------------------------------
-- NPC backup support ("请求支援"). The server is the authority for who may
-- request, how often, how many units may exist per officer, and the audit
-- trail. The requesting client only spawns/animates the car and officers.
-- Each request is one car + two NPC officers, charged as one slot of the
-- FIT-07 NPC budget (server/npc_budget.lua): the budget enforces the global
-- 6-slot cap and the per-citizen 2-slot cap that used to live in this file.
-- ---------------------------------------------------------------------------
local BACKUP_COOLDOWN = 60
local backupCooldown = {} -- [citizenid] = os.time() of the last accepted request
local backupSource = {}   -- [source] = citizenid, kept while any slot remains
local backupSeq = 0

--- Live backup budget entries owned by `citizenid` (at most two).
local function backupSlots(citizenid)
    local owned = {}
    for _, entry in ipairs(GetNpcBudget().entries) do
        if entry.kind == 'backup' and entry.citizenid == citizenid then
            owned[#owned + 1] = entry
        end
    end
    return owned
end

--- Release every backup slot for a session; used when the client drops and
--- can no longer send `backupEnded`.
local function releaseBackupSlots(citizenid, reason)
    for _, entry in ipairs(backupSlots(citizenid)) do
        NPCBudget.Release(entry.id, reason)
    end
end

--- Ask for one NPC backup unit. Returns the request id the client must send
--- back through `police:server:backupEnded` when it cleans the unit up.
---@param source number
---@return table { ok=true, request_id } | { ok=false, error }
function RequestBackup(source)
    local src = tonumber(source) or 0
    local actorPlayer = QBCore.Functions.GetPlayer(src)
    local actor = actorPlayer and actorPlayer.PlayerData
    -- Permission failures are reported as not_police so the MDT has one
    -- stable code for "you are not an on-duty officer of sufficient rank".
    if not PolicePolicy.Can(actor, 'incident.update') then return fail('not_police') end
    local cid = type(actor.citizenid) == 'string' and actor.citizenid or ''
    if cid == '' then return fail('not_police') end

    local now = os.time()
    local last = tonumber(backupCooldown[cid]) or 0
    if now - last < BACKUP_COOLDOWN then return fail('cooldown') end

    backupSeq = backupSeq + 1
    local requestId = ('BU-%d-%d-%d'):format(src, now, backupSeq)

    -- Reserve the budget slot before the yielding audit insert: the budget
    -- itself is the reservation, so two requests in the same tick cannot both
    -- pass the limit check. A global refusal is propagated as global_limit;
    -- the per-officer refusal keeps the MDT's historical `limit` code.
    local admitted, budgetError = NPCBudget.Acquire('backup', requestId, cid)
    if not admitted then
        if budgetError == 'player_limit' then return fail('limit') end
        return fail(budgetError or 'limit')
    end
    backupSource[src] = cid
    local previousCooldown = backupCooldown[cid]
    backupCooldown[cid] = now

    if not auditPlayer(cid, 'backup.request', cid, requestId) then
        NPCBudget.Release(requestId, 'audit_unavailable')
        backupSource[src] = nil
        backupCooldown[cid] = previousCooldown
        return fail('audit_unavailable')
    end

    -- The audit insert yields; do not spawn for a player who left meanwhile
    -- (or whose server id was reused by someone else in the meantime).
    local stillThere = QBCore.Functions.GetPlayer(src)
    if not stillThere or stillThere.PlayerData.citizenid ~= cid then
        NPCBudget.Release(requestId, 'player_left')
        backupSource[src] = nil
        backupCooldown[cid] = previousCooldown
        return fail('not_police')
    end

    TriggerClientEvent('police:client:SpawnBackup', src, requestId)
    return { ok = true, request_id = requestId }
end

--- Client finished (or failed) a backup unit: release exactly that unit.
--- Unknown / foreign request ids are ignored so a client cannot free another
--- officer's slot. The source is captured locally so the ownership check is
--- bound to the caller's session, never to a client-supplied citizenid.
RegisterNetEvent('police:server:backupEnded', function(requestId)
    local targetSrc = tonumber(source) or 0
    local player = QBCore.Functions.GetPlayer(targetSrc)
    local actor = player and player.PlayerData
    local cid = actor and actor.citizenid
    if type(cid) ~= 'string' or cid == '' then return end
    if type(requestId) ~= 'string' or #requestId < 1 or #requestId > 64 then return end

    local owned = false
    for _, entry in ipairs(backupSlots(cid)) do
        if entry.id == requestId then
            owned = true
            break
        end
    end
    if not owned then return end

    NPCBudget.Release(requestId, 'backup_ended')
    -- Keep the session -> citizenid binding until the last unit ends, otherwise
    -- a later playerDropped would not know which slots still need releasing.
    if #backupSlots(cid) == 0 and backupSource[targetSrc] == cid then
        backupSource[targetSrc] = nil
    end
end)

-- A dropped client never gets to send backupEnded; release every pending unit
-- for that session so the global/per-officer caps cannot stay locked forever.
AddEventHandler('playerDropped', function()
    local src = tonumber(source) or 0
    local cid = backupSource[src]
    if not cid then return end
    backupSource[src] = nil
    releaseBackupSlots(cid, 'player_dropped')
end)

--- Best-effort notification for the citation created by an arrest. The arrest
--- is already committed when this runs, so a failing enqueue is only logged and
--- never rolls the arrest back; the outbox retries delivery in the background.
local function notifyCitation(citizenid, citationId, amount, reason, source)
    local title = '你收到一张罚单'
    local content = utf8Sub(
        ('你收到一张罚单 #%d，金额 $%d，罪名 %s'):format(citationId, amount, reason), 500)
    local ok, err = pcall(function()
        return Outbox.Enqueue(OUTBOX_TOPIC_NOTIFICATION, {
            citizenid = citizenid,
            title = title,
            content = content,
            app_id = 'banking',
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

    -- The whole write below is one idempotent unit: the key is claimed before
    -- any row is touched, and a retry with the same key replays the cached
    -- result instead of creating a second report/citation.
    return withIntent('arrest', actor.citizenid, params.idempotency_key, function()
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
        if openCase then
            -- Opening a justice case carries the same rank gate as creating a
            -- police case: the UI says Sergeant+, but the phone is never trusted.
            local canOpenCase = PolicePolicy.Can(actor, 'case.create')
            if not canOpenCase then return fail('case_forbidden') end
        end

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
            created.exhibitNo = exhibitNo
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
        if created.citation then
            if not auditPlayer(actor.citizenid, 'citation.issue', tostring(created.citation),
                    ('$%d'):format(amount)) then
                auditsOk = false
            end
        end
        if created.evidence then
            if not auditPlayer(actor.citizenid, 'evidence.register', created.exhibitNo,
                    evidenceLabel) then
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
    end)
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

    -- Same idempotent unit as ArrestSubmit: report + optional evidence replay
    -- by key instead of writing a duplicate on retry.
    return withIntent('report', actor.citizenid, params.idempotency_key, function()
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
    end)
end

exports('CreateIncidentSystem', Sys.CreateIncident)
exports('AssignUnitSystem', Sys.AssignUnit)
exports('JailSystem', Sys.Jail)
exports('ArrestSubmit', ArrestSubmit)
exports('ReportSubmit', ReportSubmit)
exports('RequestBackup', RequestBackup)
-- Outbox entry point for other police modules and the Lua harness. The caller
-- gets false when the durable row could not be written; delivery itself is the
-- worker's job (immediate Kick + 30s retry loop).
exports('EnqueueOutbox', function(topic, payload)
    return Outbox.Enqueue(topic, payload)
end)
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
    pcall(function()
        return exports['custom-justice']:ReleaseSentence(
            player.PlayerData.citizenid, 'admin_release')
    end)
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
