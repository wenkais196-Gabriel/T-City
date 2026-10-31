-- server/p2_system.lua — system (agent) entry points for the police board.
-- These have no player source: the actor is an agent id and every write is
-- audited with actor_kind='agent'. Authorization/approval happens in
-- custom-director (L1-L3); this layer only validates data and state.
local QBCore = exports['qb-core']:GetCoreObject()
local Sys = {}


--- BOLO 发布后推给所有在勤警察（P3-4）。
--- 以前 BOLO 只是 reports 表上的一个标记：发布完，街上没别人知道。
--- 走 custom-phone 的 outbox（FIT-02：通知的唯一所有者），不在时才直连 export。
local function broadcastBolo(actorCid, boloKind, boloTarget, title, location)
    local body = ('%s · %s'):format(
        boloKind == 'vehicle' and '车辆' or '人员', tostring(boloTarget or ''))
    if location and location ~= '' then body = body .. ' · ' .. tostring(location) end
    local sent = 0
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(src)
        local data = Player and Player.PlayerData
        if data and data.job and data.job.name == 'police'
            and data.job.onduty == true and data.citizenid ~= actorCid then
            local payload = {
                citizenid = data.citizenid,
                title = ('BOLO · %s'):format(tostring(title or '通缉')),
                content = body:sub(1, 200),
                app_id = 'police_mdt',
            }
            local ok = pcall(function()
                if type(Outbox) == 'table' and type(Outbox.Enqueue) == 'function' then
                    Outbox.Enqueue('notification', payload)
                else
                    exports['custom-phone']:Notify(payload.citizenid, payload.title, payload.content, payload.app_id)
                end
            end)
            if ok then sent = sent + 1 end
        end
    end
    return sent
end

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
    -- 唯一写者见 server/audit.lua（这里只保留同名包装，调用点不用改）
    return PoliceAudit.WriteAgent(actorId, action, target, detail)
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
---@return boolean ok, number|string|nil id_or_error
function Outbox.Enqueue(topic, payload)
    if type(topic) ~= 'string' or not OUTBOX_TOPICS[topic] then
        return false, 'invalid_topic'
    end
    if type(payload) ~= 'table' then return false, 'invalid_payload' end
    local encoded = outboxEncode(payload)
    if not encoded then return false, 'encode_failed' end

    local enqueued, result = pcall(function()
        return MySQL.insert.await(
            "INSERT INTO police_outbox (topic, payload, status, attempts, next_attempt_at) VALUES (?, ?, 'pending', 0, NOW())",
            { topic, encoded })
    end)
    if not enqueued then
        print(('[custom-police] outbox enqueue failed (%s): %s'):format(topic, tostring(result)))
        return false, 'db_error'
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
    -- agent 路径要求 fail-closed：审计写不进去就不许建单（玩家 911 不这么做——
    -- 不能因为审计失败就让报警失效）。所以这里预审计，然后让写者跳过它自己那条。
    if not audit(actorId, 'incident.create', nil, title) then return false, 'audit_unavailable' end

    local createdBy = ('agent:%s'):format(utf8Sub(tostring(actorId), 40))
    local result, reason = PoliceIncidents.InsertRow(createdBy, data, { audit = false })
    if not result then return false, reason end

    broadcast(('%s: %s'):format(result.code, result.title),
              utf8Sub(trim(data.details or data.description), 1000))
    return { id = result.id, status = result.status }
end

--- L2: assign a unit to an incident as an agent.
function Sys.AssignUnit(actorId, incidentId, citizenid)
    -- FIT-11: delegate to the p0 state-machine helper instead of writing
    -- police_units/police_incidents directly. Agent callers have no player
    -- source, so this uses the system path and records the actor citizenid.
    local ok, result, reason = pcall(function()
        return exports['custom-police']:AssignUnitSystemForAgent(
            incidentId, citizenid, actorId)
    end)
    if not ok then return false, 'assign_failed' end
    if result == false then return false, reason or 'assign_failed' end
    return result
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
    -- 逮捕记录由唯一写者写；没有 incident/case 时那两列根本不出现
    PoliceRecords.InsertArrest(('agent:%s'):format(tostring(actorId):sub(1, 40)),
        { citizenid = target, charges = text })
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
    -- 唯一写者见 server/audit.lua
    return PoliceAudit.Write(cid, action, target, detail)
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
local BACKUP_MAX_UNITS = 2 -- 每人两个槽；一次响应最多两辆车
local BACKUP_COOLDOWN = 60
local backupCooldown = {} -- [citizenid] = os.time() of the last accepted request
local backupSource = {}   -- [source] = citizenid, kept while any slot remains
local backupSeq = 0
-- 阶段表（S2）：[requestId] = { phase, cid, source, at, spawnedAt, enrouteAt,
-- onsceneAt, engagedAt, entityCount, rejectedAt, rejectedCount }
-- 名额仍然在 NPCBudget 的 entries 里 —— 阶段是"客户端到了哪一步"，预算条目是
-- "还占不占名额"，两者生命周期不同（S3 的 sweep 会先收单位再放名额），塞在一起
-- 会让释放顺序无从表达。
local backupPhases = {}
-- ack_rejected 的采样窗口：同一条单 10 秒内最多记一条，避免伪造包把审计打爆。
local ACK_REJECT_SAMPLE_MS = 10000

-- 时间语义（S3）：服务端是唯一权威时钟 —— 客户端不再自己算寿命，只按
-- `police:client:BackupEnd` 收尾。两套旧计时（客户端 5 分钟 / 预算 10 分钟）
-- 互相不知道，是"名额被占着但没人管"的根源。
local BACKUP_TTL_SECONDS = 300
local BACKUP_ACK_TIMEOUT = { requested = 10, spawning = 15 } -- phase -> 秒
local BACKUP_END_GRACE = 5
local BACKUP_SWEEP_MS = 10000

--- v2 开关（回滚用）：`setr police_backup_v2 0` 后 sweep 立即停手，客户端寿命照旧。
local function backupV2Enabled()
    return GetConvar('police_backup_v2', '1') == '1'
end

--- 寿命。`police_backup_ttl` 是**测试专用**覆盖（验收标准 4 要 20s 级别），
--- 只接受 10–3600 的整数，其余一律回落到 300s —— 免得一条写错的 convar
--- 把生产环境变成 1 秒回收。
local function backupTtlSeconds()
    local override = tonumber(GetConvar('police_backup_ttl', ''))
    if override and override >= 10 and override <= 3600 then return math.floor(override) end
    return BACKUP_TTL_SECONDS
end

--- 到场后的停留上限（蓝图 §6.3 #3：「到场 120 秒无人类警员接管 → 自动撤退」）。
---
--- 我们的世界里请求者本身就是人类警员，所以"接管"只能解释成"进入了交战/处置"：
--- 一旦客户端上报 `engaged`，这条上限就作废（战斗中不该有倒计时）。
--- 默认 120 秒（蓝图口径），`setr police_backup_onscene_ttl 0` 关掉，退化成 300s 总寿命。
local function backupOnsceneTtl()
    local raw = tonumber(GetConvar('police_backup_onscene_ttl', '120'))
    if not raw then return 120 end
    if raw <= 0 then return 0 end
    if raw > 3600 then return 3600 end
    return math.floor(raw)
end


--- 读一个玩家的实例号（routing bucket）；取不到就当 0（主世界/共享桶）。
local function playerBucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if ok and type(bucket) == 'number' then return bucket end
    return 0
end

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

--- True when `requestId` is one of `citizenid`'s live budget slots. Ownership is
--- always derived from the budget, never from a client-supplied id alone.
local function ownsBackupUnit(citizenid, requestId)
    for _, entry in ipairs(backupSlots(citizenid)) do
        if entry.id == requestId then return true end
    end
    return false
end

--- 记一条"ack 被拒"，按单号采样：同一 requestId 10 秒内只写一条。
--- 不可达/未知的单号没有 entry 可挂计数器，退化成按调用者采样一次。
local function recordAckRejected(cid, requestId, phase, why)
    local now = GetGameTimer()
    local entry = backupPhases[requestId]
    if entry then
        if entry.rejectedAt and now - entry.rejectedAt < ACK_REJECT_SAMPLE_MS then
            entry.rejectedCount = (entry.rejectedCount or 0) + 1
            return
        end
        entry.rejectedAt = now
        entry.rejectedCount = (entry.rejectedCount or 0) + 1
    end
    -- best-effort：拒绝计数是遥测，失败只打日志，不能影响 ack 的丢弃语义。
    if not auditPlayer(cid, 'backup.ack_rejected', requestId,
        ('phase=%s;why=%s'):format(tostring(phase), tostring(why))) then
        print(('[custom-police] backup.ack_rejected audit failed: %s (%s)'):format(
            tostring(requestId), tostring(why)))
    end
end

--- Ask for one NPC backup unit. Returns the request id the client must send
--- back through `police:server:backupEnded` when it cleans the unit up.
---@param source number
---@return table { ok=true, request_id } | { ok=false, error }
--- 在勤的**其它**警官数量（不含请求者自己）。
--- 用来回答"真人有空的话还要不要 NPC 支援"（B4 滥用防护）。
local function countOtherOnDutyPolice(src)
    local count = 0
    for _, otherSrc in ipairs(QBCore.Functions.GetPlayers()) do
        if otherSrc ~= src then
            local other = QBCore.Functions.GetPlayer(otherSrc)
            local data = other and other.PlayerData
            if data and PolicePolicy.IsPolice(data) and data.job and data.job.onduty == true then
                count = count + 1
            end
        end
    end
    return count
end

local function distanceBetween(a, b)
    if not a or not b then return math.huge end
    local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
    local dy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
    local dz = (tonumber(a.z) or 0) - (tonumber(b.z) or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- 这单支援应该"跟着谁"（B3）。
---
--- 默认跟着请求者；但如果附近有另一个在勤警官更靠近现场，就跟最近的警官 ——
--- 真警联动时 NPC 跟上最先到场的那个人，而不是把请求者当唯一锚点。
--- 只在请求时算一次：位置会变，但"跟着谁"通常不会在 5 分钟内变化，
--- 每帧重算反而会在两人之间反复横跳。
---@param src number 请求者
---@return number, number escortSource, distance
function PickBackupEscort(src)
    local player = QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data then return src, 0 end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return src, 0 end
    local origin = GetEntityCoords(ped)

    local bestSource, bestDistance = src, 0
    for _, otherSrc in ipairs(QBCore.Functions.GetPlayers()) do
        if otherSrc ~= src then
            local other = QBCore.Functions.GetPlayer(otherSrc)
            local otherData = other and other.PlayerData
            if otherData and PolicePolicy.IsPolice(otherData) and otherData.job
                and otherData.job.onduty == true then
                local otherPed = GetPlayerPed(otherSrc)
                if otherPed and otherPed ~= 0 then
                    local distance = distanceBetween(GetEntityCoords(otherPed), origin)
                    if bestSource == src or distance < bestDistance then
                        bestSource, bestDistance = otherSrc, distance
                    end
                end
            end
        end
    end
    return bestSource, bestDistance
end

--- 呼号与播报的小门面：radio 模块没加载时静默降级（播报永远不是关键路径）。
local function radioCallsign(citizenid, metadata)
    if not PoliceRadioText then return nil end
    local ok, value = pcall(PoliceRadioText.Callsign, citizenid, metadata)
    return ok and value or nil
end

local function radioSay(kind, callsign)
    if not PoliceRadio or not callsign then return end
    pcall(PoliceRadio.Say, kind, callsign)
end

function RequestBackup(source, tier)
    local src = tonumber(source) or 0
    local actorPlayer = QBCore.Functions.GetPlayer(src)
    local actor = actorPlayer and actorPlayer.PlayerData
    -- Permission failures are reported as not_police so the MDT has one
    -- stable code for "you are not an on-duty officer of sufficient rank".
    if not PolicePolicy.Can(actor, 'incident.update') then return fail('not_police') end
    local cid = type(actor.citizenid) == 'string' and actor.citizenid or ''
    if cid == '' then return fail('not_police') end

    -- 滥用防护（B4）：真人警察够多时不让 NPC 顶班。默认 0 = 不限制。
    -- 计数不含请求者自己 —— 他本来就该算"在现场的那个人"。
    local minRealCops = tonumber(GetConvar('police_backup_min_real_cops', '0')) or 0
    if minRealCops > 0 then
        local others = countOtherOnDutyPolice(src)
        if others >= minRealCops then
            -- 拒绝也要留痕：否则"为什么今天没人叫到支援"无从解释。
            if not auditPlayer(cid, 'backup.denied', cid,
                ('reason=police_available;others=%d;threshold=%d'):format(others, minRealCops)) then
                print(('[custom-police] backup.denied audit failed for %s'):format(tostring(cid)))
            end
            return fail('police_available')
        end
    end

    local now = os.time()
    local last = tonumber(backupCooldown[cid]) or 0
    if now - last < BACKUP_COOLDOWN then return fail('cooldown') end

    -- 响应级别（B1）：1 = 一辆车两人；2 = 两辆车四人（正好用满每人的 2 个槽）。
    -- 调用方（MDT / agent）可以显式给 tier；没给就吃 convar 的默认值。
    -- 一次请求 = tier 个独立单位，各有自己的 requestId / 预算槽 / 阶段条目。
    local units = tonumber(tier) or tonumber(GetConvar('police_backup_default_tier', '1')) or 1
    units = math.floor(units)
    if units < 1 then units = 1 end
    if units > BACKUP_MAX_UNITS then units = BACKUP_MAX_UNITS end

    -- Reserve the budget slots before the yielding audit insert: the budget
    -- itself is the reservation, so two requests in the same tick cannot both
    -- pass the limit check. Bind the source first: playerDropped can run while
    -- the budget audit suspends, and it must be able to find this reservation.
    local previousSource = backupSource[src]
    local previousCooldown = backupCooldown[cid]
    backupSource[src] = cid

    local requestIds = {}
    -- 一次响应只认一个"跟着谁"，同一组里的两辆车跟同一个人。
    local escortSource = PickBackupEscort(src)

    --- 半支队伍比没有更糟：任何一个单位抢不到槽/写不进审计，就把已经拿到的全部退回去。
    local function rollback(errorCode)
        for _, id in ipairs(requestIds) do
            NPCBudget.Release(id, 'request_rollback')
            backupPhases[id] = nil
        end
        if backupSource[src] == cid then backupSource[src] = previousSource end
        backupCooldown[cid] = previousCooldown
        return fail(errorCode)
    end

    for index = 1, units do
        backupSeq = backupSeq + 1
        local requestId = ('BU-%d-%d-%d'):format(src, now, backupSeq)

        local admitted, budgetError = NPCBudget.Acquire('backup', requestId, cid)
        if not admitted then
            if budgetError == 'player_limit' then return rollback('limit') end
            return rollback(budgetError or 'limit')
        end
        requestIds[#requestIds + 1] = requestId

        if not auditPlayer(cid, 'backup.request', cid, requestId) then
            return rollback('audit_unavailable')
        end

        -- L0：无线电里先听到"某单位已出动"，比车出现在街角更重要。
        radioSay('dispatch', radioCallsign(cid, actor.metadata))

        -- The audit insert yields; do not spawn for a player who left meanwhile
        -- (or whose server id was reused by someone else in the meantime).
        local stillThere = QBCore.Functions.GetPlayer(src)
        if not stillThere or stillThere.PlayerData.citizenid ~= cid then
            return rollback('not_police')
        end

        -- Phase starts at `requested` on the server side before the client is
        -- even told to spawn: that is the anchor S3's sweep measures the 10s ack
        -- timeout against, and it must exist even if the client never answers.
        backupPhases[requestId] = {
            phase = 'requested',
            cid = cid,
            source = src,
            at = now,
            lastAck = now,
            expiresAt = now + backupTtlSeconds(),
            entityCount = 0,
            -- 请求者当时所在的实例（routing bucket）。bucket 是"实例化"工具而不是
            -- 可见性范围（官方 cookbook 原话），所以支援单位**不**做桶隔离：
            -- 请求者在 0 号桶时，警车对所有人在同一个世界里，这才是 RP 该有的样子；
            -- 请求者本身在私有桶里时，客户端建出来的实体天然只在那个桶里可见。
            -- 这里记下来是为了让运维/agent 能分辨"这单在哪个实例里"。
            bucket = playerBucket(src),
            tier = units,
            unit_index = index,
            escort_source = escortSource,
        }
    end

    backupCooldown[cid] = now
    -- 只发一次事件，把整组 id 与"跟着谁"交给客户端；客户端依次生成并错开停车位。
    TriggerClientEvent('police:client:SpawnBackup', src, requestIds[1], requestIds, escortSource)
    return { ok = true, request_id = requestIds[1], request_ids = requestIds, tier = units }
end
--- Client reports "how far I got" for one of its own units (S2).
---
--- Contract: only the caller's own live unit, only a phase from the contract's
--- CLIENT_PHASES, and only forward (a repeated phase is an idempotent refresh).
--- Everything else is dropped and sampled into `backup.ack_rejected` — a client
--- must never be able to move another officer's unit, nor rewind one to make the
--- 10s/15s ack timeouts look satisfied.
RegisterNetEvent('police:server:backupAck', function(requestId, phase, entityCount, clientTick)
    local targetSrc = tonumber(source) or 0
    local player = QBCore.Functions.GetPlayer(targetSrc)
    local actor = player and player.PlayerData
    local cid = actor and actor.citizenid
    if type(cid) ~= 'string' or cid == '' then return end
    if type(requestId) ~= 'string' or #requestId < 1 or #requestId > 64 then return end

    local normalized = type(BackupContract) == 'table'
        and BackupContract.NormalizePhase(phase) or nil
    if not normalized then
        recordAckRejected(cid, requestId, phase, 'bad_phase')
        return
    end

    -- Ownership comes from the budget, not from the phase table: a phase entry
    -- could outlive its slot by a tick, and the budget is what the caps enforce.
    if not ownsBackupUnit(cid, requestId) then
        recordAckRejected(cid, requestId, normalized, 'not_owned')
        return
    end

    local entry = backupPhases[requestId]
    if not entry then
        -- Slot exists but phases were lost (server restarted with slots kept?):
        -- re-seed instead of rejecting, otherwise a legit client can never ack.
        entry = { phase = 'requested', cid = cid, source = targetSrc, at = os.time(), entityCount = 0 }
        backupPhases[requestId] = entry
    end

    if entry.cid ~= cid or entry.source ~= targetSrc then
        recordAckRejected(cid, requestId, normalized, 'foreign_session')
        return
    end

    if not BackupContract.CanAdvance(entry.phase, normalized) then
        recordAckRejected(cid, requestId, normalized, 'backwards:' .. tostring(entry.phase))
        return
    end

    local count = math.floor(tonumber(entityCount) or 0)
    if count < 0 then count = 0 end
    if count > BackupContract.MAX_ENTITY_COUNT then count = BackupContract.MAX_ENTITY_COUNT end

    local advanced = BackupContract.PhaseRank(normalized) > BackupContract.PhaseRank(entry.phase)
    entry.phase = normalized
    entry.lastAck = os.time()
    entry.clientTick = tonumber(clientTick)

    if normalized == 'spawning' then
        if not entry.spawnedAt then entry.spawnedAt = os.time() end
    elseif normalized == 'enroute' then
        if not advanced then return end
        entry.enrouteAt = os.time()
        entry.entityCount = count
        -- 生成成功率的分子：只在第一次进 enroute 时写一条。
        if not entry.spawnedAudited then
            entry.spawnedAudited = true
            local took = entry.spawnedAt and (entry.enrouteAt - entry.spawnedAt) or nil
            if not auditPlayer(cid, 'backup.spawned', requestId,
                ('entities=%d;took=%s'):format(count, took and tostring(took) or '?')) then
                print(('[custom-police] backup.spawned audit failed: %s'):format(tostring(requestId)))
            end
        end
    elseif normalized == 'onscene' then
        if not advanced then return end
        entry.onsceneAt = os.time()
        local stay = backupOnsceneTtl()
        if stay > 0 then entry.onsceneExpiresAt = entry.onsceneAt + stay end
        local owner = QBCore.Functions.GetPlayerByCitizenId
            and QBCore.Functions.GetPlayerByCitizenId(entry.cid)
        radioSay('onscene', radioCallsign(entry.cid,
            owner and owner.PlayerData and owner.PlayerData.metadata))
    elseif normalized == 'engaged' then
        if not advanced then return end
        -- 打起来了就没有"到场没接管"这句话了（§6.3 #3 的撤销条件）。
        entry.onsceneExpiresAt = nil
        if not entry.engagedAudited then
            entry.engagedAudited = true
            if not auditPlayer(cid, 'backup.engaged', requestId, '') then
                print(('[custom-police] backup.engaged audit failed: %s'):format(tostring(requestId)))
            end
        end
    end
end)

--- 释放一个被 sweep 判过期的单位：放名额、写 backup.expired、清阶段。
--- 与 backupEnded 的区别是"谁发起的"：这里客户端可能已经卡死，所以审计里的
--- phase/why/live 全部由服务端记，客户端不上报任何东西。
local function expireBackupUnit(requestId, entry, why, now)
    local cid = entry.cid
    local phase = entry.phase
    local source = entry.source
    local live = now - (tonumber(entry.at) or now)

    NPCBudget.Release(requestId, 'backup_expired')
    backupPhases[requestId] = nil
    if type(cid) == 'string' and backupSource[source] == cid and #backupSlots(cid) == 0 then
        backupSource[source] = nil
    end

    if type(cid) ~= 'string' or cid == '' then return end
    local rbOwner = QBCore.Functions.GetPlayerByCitizenId
        and QBCore.Functions.GetPlayerByCitizenId(cid)
    radioSay('clear', radioCallsign(cid, rbOwner and rbOwner.PlayerData and rbOwner.PlayerData.metadata))
    if not auditPlayer(cid, 'backup.expired', requestId,
        ('phase=%s;why=%s;live=%d'):format(tostring(phase), tostring(why), live)) then
        print(('[custom-police] backup.expired audit failed: %s (%s)'):format(
            tostring(requestId), tostring(why)))
    end
end

--- 一次 sweep（S3）。服务端是唯一权威时钟：到点先发 `BackupEnd` 让客户端收实体，
--- 宽限 5 秒后再放名额 —— 这样"名额回收"不依赖客户端还活着，而"实体清理"
--- 仍然由客户端完成（服务端拿不到实体句柄）。
---
--- 判过期的两个条件，任一命中就进入收尾：
---   * `now >= expires_at`（寿命 300s，测试可用 `police_backup_ttl` 覆盖）
---   * 当前阶段停太久：`requested` 10s（没等到 spawning）/ `spawning` 15s（没等到 enroute）
---
--- `now` 可注入，golden 用例用它伪造时钟；生产由 10 秒循环驱动。
---@param now number|nil
---@return number released 本次真正释放的单位数
function BackupSweep(now)
    if not backupV2Enabled() then return 0 end
    now = tonumber(now) or os.time()
    local ttl = backupTtlSeconds()
    local released = 0

    for requestId, entry in pairs(backupPhases) do
        if entry.endingAt then
            if now - entry.endingAt >= BACKUP_END_GRACE then
                expireBackupUnit(requestId, entry, entry.expireWhy or 'expired', now)
                released = released + 1
            end
        else
            local expiresAt = tonumber(entry.expiresAt) or ((tonumber(entry.at) or now) + ttl)
            local why
            if now >= expiresAt then
                why = 'ttl'
            elseif entry.onsceneExpiresAt and now >= entry.onsceneExpiresAt then
                why = 'onscene_timeout'
            else
                local limit = BACKUP_ACK_TIMEOUT[entry.phase]
                if limit then
                    local since = tonumber(entry.lastAck) or tonumber(entry.at) or now
                    if now - since >= limit then
                        why = 'ack_timeout:' .. tostring(entry.phase)
                    end
                end
            end
            if why then
                entry.endingAt = now
                entry.expireWhy = why
                -- 先收再放：客户端收到 BackupEnd 才会删车删人。
                TriggerClientEvent('police:client:BackupEnd', entry.source, requestId, 'expired')
            end
        end
    end

    return released
end

--- 通缉目标（S7）：支援单位到场后该打谁。
---
--- 现在的客户端只看"关系组里的敌对 ped"，被通缉的**玩家**完全不在视野里 ——
--- 支援车开到场、下车、站着，因为找不到"敌人"。这里补上服务端权威的嫌疑人来源：
--- custom-main 把通缉星级写在 `PlayerData.metadata.wanted` 上，服务端直接读，
--- 不信客户端上报的任何东西。
---
--- 投影只给 `net_id / distance / stars`：给坐标等于把嫌疑人的位置广播给客户端，
--- 给 citizenid 会把身份带进日志。客户端拿 netId 自己 NetToPed 即可。
local BACKUP_TARGET_RADIUS = 120.0
local BACKUP_TARGET_LIMIT = 3
local BACKUP_TARGET_COOLDOWN_MS = 3000
local backupTargetAskedAt = {} -- [source] = GetGameTimer()

--- 是否允许 NPC 支援对通缉玩家开火。默认关：NPC 打玩家是最容易被投诉的一类改动，
--- 先让服主在真机上确认手感再打开（`setr police_backup_engage_wanted 1`）。
local function backupEngageWantedEnabled()
    return GetConvar('police_backup_engage_wanted', '0') == '1'
end


--- 请求者附近的高星嫌疑人（只读投影）。
---@param source number
---@return table { targets = {...}, truncated = boolean, radius = number }
function GetBackupTargets(source)
    local src = tonumber(source) or 0
    local empty = { targets = {}, truncated = false, radius = BACKUP_TARGET_RADIUS }

    local player = QBCore.Functions.GetPlayer(src)
    local actor = player and player.PlayerData
    if not actor or type(actor.citizenid) ~= 'string' or actor.citizenid == '' then return empty end

    -- 只有"手里真有一单活的支援"才给目标：否则这条通道会变成一个免费的通缉雷达。
    if #backupSlots(actor.citizenid) == 0 then return empty end

    local originPed = GetPlayerPed(src)
    if not originPed or originPed == 0 then return empty end
    local origin = GetEntityCoords(originPed)

    local targets = {}
    local truncated = false
    for _, otherSrc in ipairs(QBCore.Functions.GetPlayers()) do
        if otherSrc ~= src then
            local other = QBCore.Functions.GetPlayer(otherSrc)
            local data = other and other.PlayerData
            local stars = tonumber(data and data.metadata and data.metadata.wanted) or 0
            if stars >= 1 then
                local ped = GetPlayerPed(otherSrc)
                if ped and ped ~= 0 then
                    local coords = GetEntityCoords(ped)
                    local distance = distanceBetween(coords, origin)
                    if distance <= BACKUP_TARGET_RADIUS then
                        if #targets >= BACKUP_TARGET_LIMIT then
                            truncated = true
                        else
                            local netId = type(NetworkGetNetworkIdFromEntity) == 'function'
                                and NetworkGetNetworkIdFromEntity(ped) or 0
                            if netId and netId ~= 0 then
                                targets[#targets + 1] = {
                                    net_id = netId,
                                    distance = math.floor(distance),
                                    stars = math.floor(stars),
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(targets, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
    return { targets = targets, truncated = truncated, radius = BACKUP_TARGET_RADIUS }
end

--- 客户端问"有没有通缉目标"。session-bound + 3 秒限流 + 必须有自己的活单。
RegisterNetEvent('police:server:backupTargets', function()
    local targetSrc = tonumber(source) or 0
    if not backupEngageWantedEnabled() then return end

    local player = QBCore.Functions.GetPlayer(targetSrc)
    local actor = player and player.PlayerData
    local cid = actor and actor.citizenid
    if type(cid) ~= 'string' or cid == '' then return end
    if #backupSlots(cid) == 0 then return end

    local nowMs = GetGameTimer()
    -- last == 0 是"从没问过"的哨兵：服务器刚起来时 GetGameTimer() 还很小，
    -- 用 nowMs - last 会把第一次请求也当成限流窗口内。
    local last = backupTargetAskedAt[targetSrc] or 0
    if last ~= 0 and nowMs - last < BACKUP_TARGET_COOLDOWN_MS then return end
    backupTargetAskedAt[targetSrc] = nowMs

    TriggerClientEvent('police:client:BackupTargets', targetSrc, GetBackupTargets(targetSrc))
end)

--- Live view of every backup unit the server is tracking (S6).
--- 只给运维/agent 需要的东西：没有 citizenid、没有坐标。
--- （S7）额外带 `bucket`：请求者当时的实例。支援单位刻意**不做桶隔离**
--- —— 官方 cookbook 把 routing bucket 定为"实例化"工具而不是可见性范围；
--- 请求者在主世界时，警车就该对其他人在同一个世界里。
function GetBackupState()
    local now = os.time()
    local list = {}
    for requestId, entry in pairs(backupPhases) do
        list[#list + 1] = {
            request_id = requestId,
            phase = entry.phase,
            source = entry.source,
            age = now - (tonumber(entry.at) or now),
            phase_age = now - (tonumber(entry.lastAck) or tonumber(entry.at) or now),
            entity_count = tonumber(entry.entityCount) or 0,
            rejected = tonumber(entry.rejectedCount) or 0,
            ending = entry.endingAt ~= nil,
            bucket = tonumber(entry.bucket) or 0,
            escort_source = tonumber(entry.escort_source) or nil,
        }
    end
    table.sort(list, function(a, b) return (a.request_id or '') < (b.request_id or '') end)
    return list
end

--- Client finished (or failed) a backup unit: release exactly that unit.
--- Unknown / foreign request ids are ignored so a client cannot free another
--- officer's slot. The source is captured locally so the ownership check is
--- bound to the caller's session, never to a client-supplied citizenid.
RegisterNetEvent('police:server:backupEnded', function(requestId, reason)
    local targetSrc = tonumber(source) or 0
    local player = QBCore.Functions.GetPlayer(targetSrc)
    local actor = player and player.PlayerData
    local cid = actor and actor.citizenid
    if type(cid) ~= 'string' or cid == '' then return end
    if type(requestId) ~= 'string' or #requestId < 1 or #requestId > 64 then return end

    local owned = false
    local startedAt = nil
    for _, entry in ipairs(backupSlots(cid)) do
        if entry.id == requestId then
            owned = true
            startedAt = tonumber(entry.at)
            break
        end
    end
    -- 不属于调用者的 requestId 一律忽略：既不放名额，也不写审计
    -- （否则任何人都能伪造别人的单号往审计里写垃圾）。
    if not owned then return end

    NPCBudget.Release(requestId, 'backup_ended')
    backupPhases[requestId] = nil

    -- 结束原因由客户端上报、服务端归一：白名单外的一律记 unknown，
    -- 这样"为什么结束"可聚合，而不会被自由文本污染。
    local normalized = type(BackupContract) == 'table'
        and BackupContract.NormalizeReason(reason) or 'unknown'
    local live = startedAt and math.max(0, os.time() - startedAt) or nil
    -- 名额已经释放，这一步是 best-effort：审计失败不能把已经结束的单位再"复活"，
    -- 但也不能静默丢——FIT-05 要求显式处理返回值。
    if not auditPlayer(cid, 'backup.ended', requestId,
        ('reason=%s;live=%s'):format(normalized, live and tostring(live) or '?')) then
        print(('[custom-police] backup.ended audit failed: %s (%s)'):format(
            tostring(requestId), tostring(normalized)))
    end
    -- L0：玩家自己撤回/单位阵亡时也要在无线电里报一句"恢复可用"。
    -- `expired` 是服务端 sweep 发起的（那边已经播过），这里跳过以免重复。
    if normalized ~= 'expired' then
        radioSay('clear', radioCallsign(cid, actor.metadata))
    end

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
    backupTargetAskedAt[src] = nil
    -- 阶段表跟着名额一起清：留着会污染 GetBackupState()，也会挡住同 source 的
    -- 新单（阶段只允许向前，旧条目让新单从 requested 起步时被判"倒退"）。
    for requestId, entry in pairs(backupPhases) do
        if entry.cid == cid then backupPhases[requestId] = nil end
    end
end)

-- Sweep 循环（S3）：10 秒一轮，`police_backup_v2 0` 时立刻停手（回滚开关）。
-- 挂在 onResourceStart 上而不是加载期直接起：harness 会在加载后 Drain 线程，
-- 加载期就起的死循环会撞上 `Wait() is not supported in the harness`（p0 的
-- stale sweep 也是同样的写法）。
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(BACKUP_SWEEP_MS)
        while true do
            local ok, err = pcall(BackupSweep)
            if not ok then
                print(('[custom-police] backup sweep failed: %s'):format(tostring(err)))
            end
            Wait(BACKUP_SWEEP_MS)
        end
    end)
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
    -- 公式只有一份：server/citations.lua 的 PoliceCitations.PolicyAmount
    return PoliceCitations.PolicyAmount(base, requested)
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

        -- 报告行由唯一写者（server/records.lua）写：列集合按需拼接，caseId 为 nil 也不会留参数洞
        local reportId = PoliceRecords.InsertReport(actor.citizenid, {
            title = title,
            body = body,
            kind = 'arrest',
            status = 'submitted',
            incident_id = incidentId,
            case_id = caseId,
            charges = encodeCharges(ids),
            is_bolo = bolo and 1 or 0,
            bolo_kind = boloKind,
            bolo_target = boloTarget,
            location = location,
            subject_citizenid = target,
        })
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
            local newCaseId, caseNo = PoliceRecords.InsertCase(actor.citizenid, {
                title = caseTitle,
                summary = summary,
                lead_citizenid = actor.citizenid,
            })
            if not newCaseId then
                rollback()
                return fail('case_create_failed')
            end
            created.case = newCaseId
            created.caseNo = caseNo
            created.caseTitle = caseTitle
            caseId = newCaseId
        end

        if caseId then
            local linked = PoliceRecords.LinkReport(reportId, { case_id = caseId })
            if not linked then
                rollback()
                return fail('db_error')
            end
        end

        if createCitation then
            local citationReason = utf8Sub(table.concat(sum.labels, '、'), 240)
            local chargeId = table.concat(ids, ',')
            if #chargeId > 32 then chargeId = ids[1] end
            -- 罚单行由唯一写者（server/citations.lua）写入：金额政策、列集合、审计都在那边，
            -- 这里只负责把它纳入本次提交的回滚范围。
            local citationId, citationReason2, citationAudited = PoliceCitations.Insert(actor.citizenid, {
                citizenid = target,
                amount = amount,
                base_amount = sum.fine,
                reason = citationReason,
                incident_id = incidentId,
                charge_id = chargeId,
                report_id = reportId,
            })
            if not citationId then
                rollback()
                return fail(citationReason2 == 'invalid_amount' and 'invalid_amount' or 'db_error')
            end
            created.citation = citationId
            created.citationAudited = citationAudited
            created.citationReason = citationReason
        end

        if createEvidence then
            -- 证据行 + 展品号 + 链记录都由唯一写者完成（server/p2_evidence.lua）
            local evidenceRow = PoliceEvidenceWriter.Register(actor.citizenid, {
                label = evidenceLabel,
                description = details,
                location = location,
                incident_id = incidentId,
                report_id = reportId,
                case_id = caseId,
            })
            if not evidenceRow then
                rollback()
                return fail('db_error')
            end
            created.evidence = evidenceRow.id
            created.exhibitNo = evidenceRow.exhibit_no
            if evidenceRow.chain_ok == false then
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
            if not PoliceRecords.LinkReport(reportId, { justice_case_id = created.justiceCaseId }) then
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
                if not PoliceRecords.LinkReport(reportId, { case_id = numericJusticeId }) then
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
            -- 发布即通知：BOLO 的意义就是让别人知道
            broadcastBolo(actor.citizenid, boloKind, boloTarget, created.caseTitle, location)
        end
        if created.caseNo then
            if not auditPlayer(actor.citizenid, 'case.create', created.caseNo, created.caseTitle) then
                auditsOk = false
            end
        end
        -- 罚单的 citation.issue 审计由唯一写者写下（行插入时），这里只继承它的结果，
        -- 不再重复记一条；写失败仍然让整次提交报告 audit_unavailable。
        if created.citation and created.citationAudited == false then
            auditsOk = false
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

        local reportId = PoliceRecords.InsertReport(actor.citizenid, {
            title = title,
            body = body,
            kind = 'report',
            incident_id = incidentId,
            case_id = caseId,
            subject_citizenid = subject,
            location = location,
            is_bolo = bolo and 1 or 0,
            bolo_kind = boloKind,
            bolo_target = boloTarget,
        })
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
            local evidenceRow = PoliceEvidenceWriter.Register(actor.citizenid, {
                label = evidenceLabel,
                description = evidenceDescription,
                location = location,
                incident_id = incidentId,
                report_id = reportId,
                case_id = caseId,
            })
            if not evidenceRow then
                rollback()
                return fail('db_error')
            end
            evidenceId = evidenceRow.id
            exhibitNo = evidenceRow.exhibit_no
            if evidenceRow.chain_ok == false then
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

        -- 发布即通知（P3-4）：报告提交路径的 BOLO 同样要推给在勤警察
        if bolo then
            broadcastBolo(actor.citizenid, boloKind, boloTarget, title, location)
        end

        return { ok = true, report_id = reportId, evidence_id = evidenceId, bolo = bolo }
    end)
end


--- P6-2：agent 起草一份报告（**草稿**）。
--- 行由唯一写者 PoliceRecords.InsertReport 写（records.lua），本函数只做校验与语义约束：
--- status 固定 draft、kind 固定 report、不带 BOLO、不带罚款 —— 提交仍需人在 MDT 里做。
---@param actorCid string 'action:<id>'
---@param params table { title, body, citizenid?, incident_id?, case_id? }
---@return table|nil result { report_id, status }
---@return string|nil reason
function Sys.DraftReport(actorCid, params)
    if type(params) ~= 'table' then return nil, 'invalid_params' end
    local title = trim(params.title)
    local body = trim(params.body)
    if #title < 3 or #title > 160 then return nil, 'invalid_title' end
    if #body < 3 or #body > 4000 then return nil, 'invalid_body' end

    local id, why = PoliceRecords.InsertReport(tostring(actorCid or 'agent'), {
        title = title,
        body = body,
        status = 'draft',
        kind = 'report',
        subject_citizenid = trim(params.citizenid) ~= '' and trim(params.citizenid) or nil,
        incident_id = tonumber(params.incident_id),
        case_id = tonumber(params.case_id),
    })
    if not id then return nil, why or 'db_error' end

    if not PoliceAudit.Write(tostring(actorCid or 'agent'), 'report.draft', tostring(id),
            'draft', 'agent') then
        return nil, 'audit_unavailable'
    end
    return { report_id = id, status = 'draft' }
end

exports('DraftReportSystem', Sys.DraftReport)
exports('CreateIncidentSystem', Sys.CreateIncident)
exports('AssignUnitSystem', Sys.AssignUnit)
exports('JailSystem', Sys.Jail)
exports('ArrestSubmit', ArrestSubmit)
exports('ReportSubmit', ReportSubmit)
exports('RequestBackup', RequestBackup)
exports('GetBackupState', GetBackupState)

--- 控制台查看一次支援的状态（S6 的验收手段）。
--- 只允许控制台/RCON（source 0）：它是运维读数，不该成为玩家可触发的口子。
--- 开发期专用：直接从控制台叫一单支援（真机迭代用）。
---
--- 为什么需要它：手机上点「请求支援」是 NUI → app action 的路径，自动化要过三层
--- （开手机、直达 App、走到按钮、按 Enter），每一层都可能因为窗口焦点丢失而静默失败。
--- 这条命令把"叫一单"压缩成一行控制台输入，专门服务于真机回归（生成点、到场、撤离）。
---
--- 门控：`police_backup_dev_enabled` 默认 0；只接受控制台/RCON（source 0）；
--- 走的是同一个 RequestBackup，所以权限/冷却/预算/审计一条都不跳过。
RegisterCommand('police_backup_dev', function(source, args)
    if source ~= 0 then return end
    if GetConvar('police_backup_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_backup_dev 已关闭（setr police_backup_dev_enabled 1 打开）')
        return
    end
    local src = tonumber(args and args[1])
    local tier = tonumber(args and args[2]) or 1
    if not src then
        print('[custom-police] 用法: police_backup_dev <serverId> [tier 1..2]')
        return
    end
    local result = RequestBackup(src, tier)
    if type(result) ~= 'table' then
        print('[custom-police] police_backup_dev: 没有返回值')
        return
    end
    if result.ok then
        print(('[custom-police] police_backup_dev: ok tier=%s ids=%s'):format(
            tostring(result.tier), table.concat(result.request_ids or {}, ',')))
    else
        print(('[custom-police] police_backup_dev: failed %s'):format(tostring(result.error)))
    end
end, true)

RegisterCommand('police_backup_state', function(source)
    if source ~= 0 then return end
    local units = GetBackupState()
    if #units == 0 then
        print('[custom-police] backup: no live units')
        return
    end
    for _, unit in ipairs(units) do
        print(('[custom-police] backup %s phase=%s src=%s escort=%s bucket=%d age=%ss since_ack=%ss entities=%d rejected=%d%s'):format(
            tostring(unit.request_id), tostring(unit.phase), tostring(unit.source),
            tostring(unit.escort_source), tonumber(unit.bucket) or 0,
            tostring(unit.age), tostring(unit.phase_age), tostring(unit.entity_count),
            tostring(unit.rejected), unit.ending and ' ending=true' or ''))
    end
end, true)
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
