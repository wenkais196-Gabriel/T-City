-- server/main.lua — custom-agent-ops.
--
-- Read-only observability for the agent stack:
--   * a 500-entry in-memory event ring fed by police_audit + table counters;
--   * a cached status snapshot and a live health probe;
--   * four server exports for custom-director / custom-agent-client;
--   * console-only `/agent ...` commands guarded by source 0 or `agent.ops`.
--
-- This resource never writes to a police/justice table. It only SELECTs. The
-- single file it may write is its own JSONL log, and every field is sanitised
-- and truncated before it reaches the ring or the file.
--
-- No client script, no net event and no NUI surface is registered here.

local RESOURCE = GetCurrentResourceName()
local CONFIG = AgentOpsConfig or {}

local RING_CAPACITY = 500
local EVENT_SCHEMA_VERSION = 1
local BOOT_ID = ('%d:%d'):format(os.time(), math.floor((os.clock() or 0) * 1000) % 1000)

local REQUIRED_RESOURCES = { 'qb-core', 'oxmysql', 'custom-police' }
local OPTIONAL_RESOURCES = { 'custom-director', 'custom-agent-client', 'custom-testing' }
local CRITICAL_TYPES = {
    duty = true,
    incident = true,
    arrest = true,
    sentence = true,
    npc = true,
    backup = true,
    outbox = true,
    resource = true,
    test = true,
    security = true,
}
local ACTION_TYPES = {
    ['duty.set'] = 'duty',
    ['unit.status'] = 'duty',
    ['unit.drop'] = 'duty',
    ['unit.stale'] = 'duty',
    ['incident.create'] = 'incident',
    ['incident.view'] = 'incident',
    ['incident.assign'] = 'incident',
    ['incident.unassign'] = 'incident',
    ['incident.close'] = 'incident',
    ['incident.status'] = 'incident',
    ['incident.stale'] = 'incident',
    ['incident.update'] = 'incident',
    ['arrest.create'] = 'arrest',
    ['arrest.register'] = 'arrest',
    ['arrest.view'] = 'arrest',
    ['justice.verdict'] = 'sentence',
    ['sentence.create'] = 'sentence',
    ['sentence.release'] = 'sentence',
    ['npc.spawn'] = 'npc',
    ['npc.despawn'] = 'npc',
    ['npc.stale'] = 'npc',
    ['npc.callout.create'] = 'npc',
    ['npc.callout.resolve'] = 'npc',
    ['backup.request'] = 'backup',
    ['outbox.failed'] = 'outbox',
    ['outbox.backlog'] = 'outbox',
    ['outbox.stale'] = 'outbox',
}
local REDACT_KEYS = {
    password = true,
    passwd = true,
    token = true,
    secret = true,
    authorization = true,
    apikey = true,
    license = true,
    licensekey = true,
    credential = true,
    credentials = true,
}

local AgentOps = _G.AgentOps or {}
_G.AgentOps = AgentOps
AgentOps.VERSION = 1
AgentOps.RING_CAPACITY = RING_CAPACITY
AgentOps.EVENT_SCHEMA_VERSION = EVENT_SCHEMA_VERSION

-- ---------------------------------------------------------------------------
-- Small helpers (pure, exercised by tests/architecture/test_agent_ops.py)
-- ---------------------------------------------------------------------------

local function cfg(name, default)
    local value = CONFIG[name]
    if value == nil then return default end
    return value
end

local function clampInt(value, minimum, maximum, default)
    local number = tonumber(value)
    if not number or number ~= number then number = default end
    number = math.floor(number)
    if number < minimum then number = minimum end
    if number > maximum then number = maximum end
    return number
end

local function nowMs()
    local seconds = os.time() or 0
    local timer = 0
    if type(GetGameTimer) == 'function' then
        local ok, value = pcall(GetGameTimer)
        if ok and type(value) == 'number' then timer = value end
    end
    return seconds * 1000 + (timer % 1000)
end

local ARRAY_MT = { __jsontype = 'array' }

--- Mark a list as a JSON array so an empty result is `[]`, not `{}`.
function AgentOps.Array(list)
    return setmetatable(list or {}, ARRAY_MT)
end

--- UTF-8-safe head slice; `limit` counts characters, not bytes, and control
--- characters are blanked so a value cannot forge a log line.
function AgentOps.Truncate(value, limit)
    if value == nil then return nil end
    local kind = type(value)
    if kind ~= 'string' and kind ~= 'number' then return nil end

    local text = tostring(value):gsub('%c', ' ')
    local maxChars = math.floor(tonumber(limit) or 0)
    if maxChars < 1 then return '' end
    if #text <= maxChars then return text end

    if utf8 and utf8.len and utf8.offset then
        local ok, length = pcall(utf8.len, text)
        if ok and length then
            if length <= maxChars then return text end
            local offsetOk, byteEnd = pcall(utf8.offset, text, maxChars + 1)
            if offsetOk and byteEnd then return text:sub(1, byteEnd - 1) end
            return text
        end
    end
    return text:sub(1, maxChars)
end

local function normaliseKey(key)
    if type(key) ~= 'string' then return nil end
    return key:lower():gsub('[^%w]', '')
end

local function redactText(text)
    -- `password=...`, `token: ...`, `authorization: Bearer ...` etc. The
    -- replacement keeps the key so an agent still sees that a field existed,
    -- but never the value.
    return (text:gsub('([%a_][%w_]*)(%s*[=:]%s*)([^\r\n]+)', function(key, separator, value)
        local name = normaliseKey(key)
        if name and REDACT_KEYS[name] then
            return key .. separator .. '[redacted]'
        end
        return key .. separator .. value
    end))
end

--- Return a deep copy of `value` with sensitive keys removed, control characters
--- stripped, strings truncated and depth/key count bounded.
function AgentOps.Sanitize(value, depth, seen)
    local valueType = type(value)
    if valueType == 'string' then
        return AgentOps.Truncate(
            redactText(value),
            clampInt(cfg('event_text_limit', 160), 16, 1000, 160))
    end
    if valueType == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        return value
    end
    if valueType == 'boolean' then return value end
    if valueType ~= 'table' then return nil end

    depth = depth or 0
    if depth >= clampInt(cfg('event_max_depth', 3), 1, 8, 3) then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true

    local out = {}
    local written = 0
    local maxKeys = clampInt(cfg('event_max_keys', 20), 1, 100, 20)
    for key, item in pairs(value) do
        if written >= maxKeys then break end
        local name = normaliseKey(key)
        if not (name and REDACT_KEYS[name]) then
            local clean = AgentOps.Sanitize(item, depth + 1, seen)
            if clean ~= nil and (type(key) == 'string' or type(key) == 'number') then
                out[key] = clean
                written = written + 1
            end
        end
    end
    seen[value] = nil
    return out
end

function AgentOps.ActionType(action)
    if type(action) ~= 'string' then return 'audit' end
    local known = ACTION_TYPES[action]
    if known then return known end
    local prefix = action:match('^([%a][%w_]*)%.')
    if prefix then return prefix end
    return 'audit'
end

--- A view/detail/chain/lookup action can carry names, descriptions or a
--- citizenid in its audit detail. Keep the fact that it happened, drop the
--- payload.
local function isSensitiveAction(action)
    if type(action) ~= 'string' then return false end
    if action:match('^lookup%.') then return true end
    if action == 'audit.view' then return true end
    return action:match('%.view$') ~= nil
        or action:match('%.detail$') ~= nil
        or action:match('%.chain$') ~= nil
end

function AgentOps.IsCritical(eventType)
    return CRITICAL_TYPES[eventType] == true
end

-- ---------------------------------------------------------------------------
-- Ring buffer
-- ---------------------------------------------------------------------------

function AgentOps.NewRing(capacity)
    local size = clampInt(capacity, 1, RING_CAPACITY, RING_CAPACITY)
    return {
        capacity = size,
        items = {},
        dropped = 0,
        last_id = 0,
    }
end

--- Push one event, evicting the oldest row once the ring is full.
function AgentOps.Push(ring, event)
    if type(ring) ~= 'table' or type(ring.items) ~= 'table' then return nil end

    ring.last_id = (tonumber(ring.last_id) or 0) + 1
    local item = event or {}
    item.id = ring.last_id
    item.ts = tonumber(item.ts) or nowMs()
    item.type = AgentOps.Truncate(item.type or 'audit', 48) or 'audit'
    item.source = tonumber(item.source) or 0
    if item.citizenid ~= nil then
        item.citizenid = AgentOps.Truncate(item.citizenid, 50)
    end
    item.data = AgentOps.Sanitize(item.data or {}) or {}

    if #ring.items >= ring.capacity then
        table.remove(ring.items, 1)
        ring.dropped = (tonumber(ring.dropped) or 0) + 1
    end
    ring.items[#ring.items + 1] = item
    return item
end

local function copyValue(value, depth)
    if type(value) ~= 'table' then return value end
    if depth > 4 then return nil end
    local out = {}
    for key, item in pairs(value) do
        out[key] = copyValue(item, depth + 1)
    end
    return out
end

function AgentOps.Recent(ring, count)
    local limit = clampInt(count, 1, 200, 20)
    local list = AgentOps.Array({})
    local items = type(ring) == 'table' and ring.items or {}
    local first = math.max(1, #items - limit + 1)
    for index = first, #items do
        list[#list + 1] = items[index]
    end
    return list
end

-- ---------------------------------------------------------------------------
-- File log (rotation keeps the resource directory bounded)
-- ---------------------------------------------------------------------------

local state -- assigned after the log helpers it is read from

local logState = {
    enabled = (function()
        local enabled = cfg('file_log', true)
        return not (enabled == false or enabled == 0 or enabled == 'false')
    end)(),
    mode = 'uninitialized',
    path = nil,
    relative = nil,
    writes = 0,
    failures = 0,
    rotations = 0,
}

--- Pure threshold check, exported so the cleanup rule is testable.
function AgentOps.ShouldRotate(size, maxBytes)
    size = tonumber(size) or 0
    maxBytes = tonumber(maxBytes) or 0
    return maxBytes > 0 and size > maxBytes
end

--- Keep `keep` archives (`path.1` newest). Returns true when the live file was
--- moved. Removal of the oldest archive is the cleanup step.
function AgentOps.RotateFile(path, keep)
    if type(path) ~= 'string' or path == '' then return false end
    local count = clampInt(keep, 1, 10, 1)

    os.remove(path .. '.' .. tostring(count))
    for index = count - 1, 1, -1 do
        os.rename(path .. '.' .. tostring(index), path .. '.' .. tostring(index + 1))
    end
    local renamed = os.rename(path, path .. '.1')
    return renamed ~= nil
end

local function fileSize(path)
    local file = io.open(path, 'rb')
    if not file then return 0 end
    local size = file:seek('end') or 0
    file:close()
    return size
end

local function openAppend(path)
    local file = io.open(path, 'a')
    if not file then return false end
    file:close()
    return true
end

local function resourcePathPrefix()
    if type(GetResourcePath) ~= 'function' then return nil end
    local ok, path = pcall(GetResourcePath, RESOURCE)
    if not ok or type(path) ~= 'string' or path == '' then return nil end
    if path:sub(-1) ~= '/' then path = path .. '/' end
    return path
end

local function resolveLog()
    if not logState.enabled then
        logState.mode = 'disabled'
        return
    end
    if logState.mode == 'io' then return end

    local relative = tostring(cfg('file_log_path', 'logs/agent-events.jsonl'))
    local candidates = {}
    local prefix = resourcePathPrefix()
    if prefix then
        candidates[#candidates + 1] = prefix .. relative
    end
    -- Same fallback custom-logs uses: the server-root logs/ directory.
    candidates[#candidates + 1] = 'logs/custom-agent-ops-events.jsonl'

    for _, path in ipairs(candidates) do
        if openAppend(path) then
            logState.mode = 'io'
            logState.path = path
            return
        end
    end

    -- Read-only checkout: SaveResourceFile still writes inside the resource.
    logState.mode = 'resource_file'
    logState.relative = relative
    logState.path = relative
    print(('[custom-agent-ops] file log via SaveResourceFile (%s)'):format(relative))
end

local function appendLog(event)
    if not logState.enabled or not state or not state.started then return end
    if logState.mode == 'uninitialized' then resolveLog() end
    if logState.mode == 'disabled' then return end

    local encodedOk, line = pcall(json.encode, event)
    if not encodedOk or type(line) ~= 'string' then
        logState.failures = logState.failures + 1
        return
    end
    line = line .. '\n'
    local maxBytes = clampInt(cfg('file_log_max_bytes', 2 * 1024 * 1024), 1024, 64 * 1024 * 1024, 2 * 1024 * 1024)
    local keep = clampInt(cfg('file_log_keep', 1), 1, 5, 1)

    if logState.mode == 'io' then
        if AgentOps.ShouldRotate(fileSize(logState.path), maxBytes) then
            if AgentOps.RotateFile(logState.path, keep) then
                logState.rotations = logState.rotations + 1
            end
        end
        local file = io.open(logState.path, 'a')
        if not file then
            logState.failures = logState.failures + 1
            if logState.failures <= 3 then
                print(('[custom-agent-ops] file log open failed: %s'):format(tostring(logState.path)))
            end
            return
        end
        local wrote = file:write(line)
        file:close()
        if wrote then logState.writes = logState.writes + 1 end
        return
    end

    -- SaveResourceFile fallback: rewrite the tail so a read-only deployment
    -- still has a bounded log.
    local existing = LoadResourceFile(RESOURCE, logState.relative) or ''
    if AgentOps.ShouldRotate(#existing, maxBytes) then
        pcall(SaveResourceFile, RESOURCE, logState.relative .. '.1', existing, -1)
        existing = ''
        logState.rotations = logState.rotations + 1
    end
    local saved = pcall(SaveResourceFile, RESOURCE, logState.relative, existing .. line, -1)
    if saved then
        logState.writes = logState.writes + 1
    else
        logState.failures = logState.failures + 1
    end
end

function AgentOps.LogInfo()
    return {
        enabled = logState.enabled,
        mode = logState.mode,
        path = logState.path,
        writes = logState.writes,
        failures = logState.failures,
        rotations = logState.rotations,
    }
end

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------

state = {
    started = false,
    ring = AgentOps.NewRing(RING_CAPACITY),
    snapshotReady = false,
    lastAuditId = 0,
    auditCursorReady = false,
    lastBacklogAt = 0,
    pushBucket = {
        tokens = clampInt(cfg('external_push_per_second', 20), 0, 1000, 20),
        at = nowMs(),
    },
    snapshot = {
        schema_version = EVENT_SCHEMA_VERSION,
        sampled_at = 0,
        players = 0,
        police_on_duty = 0,
        incidents_open = 0,
        sentences_active = 0,
        outbox = { pending = 0, failed = 0, stale_pending = 0 },
        npc_budget = { used = 0, max = 0 },
        resources = {},
        missing = AgentOps.Array({}),
        optional_down = AgentOps.Array({}),
        db = { ok = false, latency_ms = nil },
    },
}
AgentOps.State = state

local function emit(eventType, source, citizenid, data)
    local event = AgentOps.Push(state.ring, {
        type = eventType,
        source = source,
        citizenid = citizenid,
        data = data or {},
    })
    if event and state.started and AgentOps.IsCritical(event.type) then
        appendLog(event)
    end
    return event
end

-- ---------------------------------------------------------------------------
-- Read-only queries (parameterised, bounded, explicit projections)
-- ---------------------------------------------------------------------------

local function queryCount(sql, params)
    local ok, row = pcall(function() return MySQL.single.await(sql, params or {}) end)
    if not ok then return nil end
    if type(row) == 'number' then return row end
    if type(row) ~= 'table' then return nil end
    local value = row.n
    if value == nil then value = row.count end
    return tonumber(value)
end

local function probeDb()
    local startedAt = 0
    if type(GetGameTimer) == 'function' then
        local ok, value = pcall(GetGameTimer)
        if ok then startedAt = value end
    end
    local ok, err = pcall(function() return MySQL.scalar.await('SELECT 1') end)
    local latency = nil
    if type(GetGameTimer) == 'function' then
        local readOk, value = pcall(GetGameTimer)
        if readOk then latency = math.max(0, value - startedAt) end
    end
    return {
        ok = ok,
        latency_ms = ok and latency or nil,
        error = (not ok) and tostring(err) or nil,
    }
end

local function outboxCounts()
    local staleMinutes = clampInt(cfg('outbox_stale_minutes', 10), 1, 1440, 10)
    return {
        pending = queryCount("SELECT COUNT(*) AS n FROM police_outbox WHERE status = 'pending'"),
        failed = queryCount("SELECT COUNT(*) AS n FROM police_outbox WHERE status = 'failed'"),
        stale_pending = queryCount(
            "SELECT COUNT(*) AS n FROM police_outbox WHERE status = 'pending' AND created_at < DATE_SUB(NOW(), INTERVAL ? MINUTE)",
            { staleMinutes }),
        stale_minutes = staleMinutes,
    }
end

local function readNpcBudget()
    if type(GetResourceState) ~= 'function' then return nil end
    local stateOk, resourceState = pcall(GetResourceState, 'custom-police')
    if not stateOk or resourceState ~= 'started' then return nil end
    local ok, result = pcall(function() return exports['custom-police']:GetNpcBudget() end)
    if not ok or type(result) ~= 'table' then return nil end
    return {
        used = tonumber(result.used) or 0,
        max = tonumber(result.max) or 0,
    }
end

local function resourceStates()
    local states = {}
    for _, name in ipairs(REQUIRED_RESOURCES) do
        local ok, value = pcall(GetResourceState, name)
        states[name] = ok and tostring(value) or 'unknown'
    end
    for _, name in ipairs(OPTIONAL_RESOURCES) do
        local ok, value = pcall(GetResourceState, name)
        states[name] = ok and tostring(value) or 'unknown'
    end
    return states
end

local function collectMissing(states, names)
    local list = AgentOps.Array({})
    for _, name in ipairs(names) do
        if states[name] ~= 'started' then list[#list + 1] = name end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Snapshot + health
-- ---------------------------------------------------------------------------

--- Refresh the cached counters and emit an event when a counter changes.
function AgentOps.RefreshSnapshot()
    local snapshot = state.snapshot
    local previous = {
        players = snapshot.players,
        police_on_duty = snapshot.police_on_duty,
        incidents_open = snapshot.incidents_open,
        sentences_active = snapshot.sentences_active,
        outbox = {
            pending = snapshot.outbox.pending,
            failed = snapshot.outbox.failed,
            stale_pending = snapshot.outbox.stale_pending,
        },
        resources = snapshot.resources,
    }

    local players = 0
    if type(GetPlayers) == 'function' then
        local ok, list = pcall(GetPlayers)
        if ok and type(list) == 'table' then players = #list end
    end

    local onDuty = queryCount("SELECT COUNT(*) AS n FROM police_units WHERE status <> 'off_duty'")
    local openIncidents = queryCount(
        "SELECT COUNT(*) AS n FROM police_incidents WHERE status IN ('open','assigned','enroute','on_scene')")
    local activeSentences = queryCount(
        "SELECT COUNT(*) AS n FROM justice_sentences WHERE status = 'active'")
    local outbox = outboxCounts()
    local npc = readNpcBudget()
    local resources = resourceStates()

    snapshot.players = players
    if onDuty ~= nil then snapshot.police_on_duty = onDuty end
    if openIncidents ~= nil then snapshot.incidents_open = openIncidents end
    if activeSentences ~= nil then snapshot.sentences_active = activeSentences end
    if outbox.pending ~= nil then snapshot.outbox.pending = outbox.pending end
    if outbox.failed ~= nil then snapshot.outbox.failed = outbox.failed end
    if outbox.stale_pending ~= nil then snapshot.outbox.stale_pending = outbox.stale_pending end
    if npc then snapshot.npc_budget = npc end
    snapshot.resources = resources
    snapshot.missing = collectMissing(resources, REQUIRED_RESOURCES)
    snapshot.optional_down = collectMissing(resources, OPTIONAL_RESOURCES)
    snapshot.db = probeDb()
    snapshot.sampled_at = nowMs()

    if state.snapshotReady then
        if previous.incidents_open ~= snapshot.incidents_open then
            emit('incident', 0, nil, {
                open = snapshot.incidents_open,
                delta = snapshot.incidents_open - previous.incidents_open,
            })
        end
        if previous.sentences_active ~= snapshot.sentences_active then
            emit('sentence', 0, nil, {
                active = snapshot.sentences_active,
                delta = snapshot.sentences_active - previous.sentences_active,
            })
        end
        if previous.police_on_duty ~= snapshot.police_on_duty then
            emit('duty', 0, nil, {
                on_duty = snapshot.police_on_duty,
                delta = snapshot.police_on_duty - previous.police_on_duty,
            })
        end
        if previous.players ~= snapshot.players then
            emit('player', 0, nil, {
                online = snapshot.players,
                delta = snapshot.players - previous.players,
            })
        end

        local warn = clampInt(cfg('outbox_pending_warn', 20), 1, 10000, 20)
        if snapshot.outbox.failed > previous.outbox.failed then
            emit('outbox', 0, nil, {
                status = 'failed',
                count = snapshot.outbox.failed,
                delta = snapshot.outbox.failed - previous.outbox.failed,
            })
        end
        if snapshot.outbox.stale_pending > previous.outbox.stale_pending then
            emit('outbox', 0, nil, {
                status = 'stale',
                count = snapshot.outbox.stale_pending,
                minutes = outbox.stale_minutes,
            })
        end
        local current = nowMs()
        if snapshot.outbox.pending >= warn
            and (previous.outbox.pending < warn or current - state.lastBacklogAt > 60000) then
            emit('outbox', 0, nil, {
                status = 'backlog',
                pending = snapshot.outbox.pending,
                threshold = warn,
            })
            state.lastBacklogAt = current
        end

        local previousResources = previous.resources or {}
        for name, resourceState in pairs(resources) do
            if previousResources[name] ~= resourceState then
                emit('resource', 0, nil, { name = name, state = resourceState })
            end
        end
    end

    state.snapshotReady = true
    return snapshot
end

--- Cached status, safe to call at any time. No SQL on the read path.
function AgentOps.GetSnapshot()
    local snapshot = state.snapshot
    return {
        schema_version = EVENT_SCHEMA_VERSION,
        ok = true,
        boot_id = BOOT_ID,
        sampled_at = snapshot.sampled_at,
        resources = snapshot.resources or {},
        missing_resources = snapshot.missing or AgentOps.Array({}),
        optional_down = snapshot.optional_down or AgentOps.Array({}),
        players = snapshot.players or 0,
        police_on_duty = snapshot.police_on_duty or 0,
        incidents_open = snapshot.incidents_open or 0,
        sentences_active = snapshot.sentences_active or 0,
        outbox = snapshot.outbox or { pending = 0, failed = 0, stale_pending = 0 },
        npc_budget = snapshot.npc_budget or { used = 0, max = 0 },
        db = snapshot.db or { ok = false },
        ring = {
            capacity = state.ring.capacity,
            count = #state.ring.items,
            last_id = state.ring.last_id,
            dropped = state.ring.dropped,
        },
        file_log = AgentOps.LogInfo(),
    }
end

--- Events newer than `sinceId`, oldest first, capped at 200. `reset` is true
--- when the cursor belongs to a previous resource lifetime.
function AgentOps.GetEvents(sinceId, limit)
    local count = clampInt(limit, 1, 200, 50)
    local since = tonumber(sinceId) or 0
    local items = state.ring.items
    local lastId = state.ring.last_id
    local reset = since > lastId
    local list = AgentOps.Array({})
    local selected = {}

    if reset then
        local first = math.max(1, #items - count + 1)
        for index = first, #items do selected[#selected + 1] = items[index] end
    else
        for index = 1, #items do
            if items[index].id > since then selected[#selected + 1] = items[index] end
        end
        local first = math.max(1, #selected - count + 1)
        if first > 1 then
            local tail = {}
            for index = first, #selected do tail[#tail + 1] = selected[index] end
            selected = tail
        end
    end

    for _, event in ipairs(selected) do
        list[#list + 1] = copyValue(event, 0)
    end

    return {
        schema_version = EVENT_SCHEMA_VERSION,
        ok = true,
        boot_id = BOOT_ID,
        events = list,
        count = #list,
        next_id = lastId,
        dropped = state.ring.dropped,
        reset = reset,
    }
end

--- Live health probe: DB latency, missing resources, outbox backlog, old
--- pending rows and the file-log state.
function AgentOps.Health()
    local db = probeDb()
    local resources = resourceStates()
    local missing = collectMissing(resources, REQUIRED_RESOURCES)
    local optionalDown = collectMissing(resources, OPTIONAL_RESOURCES)
    local outbox = outboxCounts()
    local snapshot = state.snapshot

    local pending = outbox.pending
    if pending == nil then pending = snapshot.outbox.pending end
    local failed = outbox.failed
    if failed == nil then failed = snapshot.outbox.failed end
    local stale = outbox.stale_pending
    if stale == nil then stale = snapshot.outbox.stale_pending end

    local warn = clampInt(cfg('outbox_pending_warn', 20), 1, 10000, 20)
    local healthy = db.ok == true and #missing == 0 and (failed or 0) == 0

    return {
        schema_version = EVENT_SCHEMA_VERSION,
        ok = true,
        boot_id = BOOT_ID,
        sampled_at = nowMs(),
        healthy = healthy,
        db = {
            ok = db.ok == true,
            latency_ms = db.ok and db.latency_ms or nil,
            error = (not db.ok) and AgentOps.Truncate(tostring(db.error or 'db_error'), 120) or nil,
        },
        resources = {
            states = resources,
            required = AgentOps.Array({ 'qb-core', 'oxmysql', 'custom-police' }),
            missing = missing,
            optional_down = optionalDown,
        },
        outbox = {
            pending = pending or 0,
            failed = failed or 0,
            stale_pending = stale or 0,
            threshold = warn,
        },
        old_pending = stale or 0,
        ring = {
            capacity = state.ring.capacity,
            count = #state.ring.items,
            last_id = state.ring.last_id,
            dropped = state.ring.dropped,
        },
        file_log = AgentOps.LogInfo(),
    }
end

-- ---------------------------------------------------------------------------
-- police_audit poller
-- ---------------------------------------------------------------------------

local AUDIT_BATCH = clampInt(cfg('audit_batch', 100), 1, 100, 100)
local TEXT_LIMIT = clampInt(cfg('event_text_limit', 160), 16, 1000, 160)
local TARGET_LIMIT = clampInt(cfg('event_target_limit', 64), 8, 200, 64)

--- Anchor the cursor at MAX(id) so a restart does not replay old audit rows.
function AgentOps.PollAudit()
    if not state.auditCursorReady then
        local ok, row = pcall(function()
            return MySQL.single.await('SELECT MAX(id) AS id FROM police_audit')
        end)
        if not ok then return false end
        state.lastAuditId = tonumber(row and row.id) or 0
        state.auditCursorReady = true
        return true
    end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT id, actor_citizenid, actor_kind, action, target, detail, created_at '
                .. 'FROM police_audit WHERE id > ? ORDER BY id ASC LIMIT ?',
            { state.lastAuditId, AUDIT_BATCH })
    end)
    if not ok or type(rows) ~= 'table' then return false end

    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        if id and id > state.lastAuditId then
            state.lastAuditId = id
            local action = tostring(row.action or '')
            local kind = AgentOps.ActionType(action)
            local data = {
                audit_id = id,
                action = AgentOps.Truncate(action, 48),
                actor_kind = AgentOps.Truncate(row.actor_kind, 16),
            }
            if isSensitiveAction(action) then
                data.redacted = true
            else
                data.target = AgentOps.Truncate(row.target, TARGET_LIMIT)
                data.detail = AgentOps.Truncate(row.detail, TEXT_LIMIT)
            end
            emit(kind, 0, row.actor_citizenid, data)
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Commands (console source 0 or ACE agent.ops; never a net surface)
-- ---------------------------------------------------------------------------

local USAGE = 'usage: /agent status | events [n] | tail [n] | health | test <suite>'

--- Console (0) or a player holding `agent.ops`. A console command invoked by
--- another resource is rejected: only the real FXServer console may run it.
function AgentOps.CanRun(source)
    source = tonumber(source)
    if source == 0 then
        if type(GetInvokingResource) == 'function' then
            local ok, invoking = pcall(GetInvokingResource)
            if ok and invoking ~= nil then
                return false, 'resource_invoked'
            end
        end
        return true
    end
    if not source or source < 1 then return false, 'invalid_source' end
    if type(IsPlayerAceAllowed) ~= 'function' then return false, 'ace_unavailable' end
    local ok, allowed = pcall(function() return IsPlayerAceAllowed(source, 'agent.ops') end)
    if not ok then return false, 'ace_error' end
    if allowed ~= true then return false, 'ace_denied' end
    return true
end

local COMMANDS = {}

function COMMANDS.status()
    if (state.snapshot.sampled_at or 0) == 0 then AgentOps.RefreshSnapshot() end
    print(json.encode(AgentOps.GetSnapshot()))
end

function COMMANDS.events(_, args)
    local count = clampInt(args and args[2] or 20, 1, 100, 20)
    local result = AgentOps.GetEvents(nil, count)
    if #result.events == 0 then
        print(json.encode({ ok = true, count = 0, next_id = result.next_id }))
        return
    end
    for _, event in ipairs(result.events) do
        print(json.encode(event))
    end
end

function COMMANDS.tail(_, args)
    local count = clampInt(args and args[2] or 20, 1, 50, 20)
    local printed = 0

    local auditOk, auditRows = pcall(function()
        return MySQL.query.await(
            'SELECT id, actor_citizenid, actor_kind, action, target, detail, created_at '
                .. 'FROM police_audit ORDER BY id DESC LIMIT ?',
            { count })
    end)
    if auditOk and type(auditRows) == 'table' then
        for index = #auditRows, 1, -1 do
            local row = auditRows[index]
            print(json.encode({
                table = 'police_audit',
                id = tonumber(row.id),
                actor = AgentOps.Truncate(row.actor_citizenid, 50),
                actor_kind = AgentOps.Truncate(row.actor_kind, 16),
                action = AgentOps.Truncate(row.action, 48),
                target = AgentOps.Truncate(row.target, TARGET_LIMIT),
                detail = AgentOps.Truncate(row.detail, TEXT_LIMIT),
                created_at = AgentOps.Truncate(row.created_at, 32),
            }))
            printed = printed + 1
        end
    else
        print(json.encode({ ok = false, table = 'police_audit', error = 'query_failed' }))
    end

    local outboxOk, outboxRows = pcall(function()
        return MySQL.query.await(
            'SELECT id, topic, status, attempts, next_attempt_at, created_at '
                .. 'FROM police_outbox ORDER BY id DESC LIMIT ?',
            { count })
    end)
    if outboxOk and type(outboxRows) == 'table' then
        for index = #outboxRows, 1, -1 do
            local row = outboxRows[index]
            print(json.encode({
                table = 'police_outbox',
                id = tonumber(row.id),
                topic = AgentOps.Truncate(row.topic, 32),
                status = AgentOps.Truncate(row.status, 16),
                attempts = tonumber(row.attempts),
                next_attempt_at = AgentOps.Truncate(row.next_attempt_at, 32),
                created_at = AgentOps.Truncate(row.created_at, 32),
            }))
            printed = printed + 1
        end
    else
        print(json.encode({ ok = false, table = 'police_outbox', error = 'query_failed' }))
    end

    if printed == 0 then print(json.encode({ ok = true, rows = 0 })) end
end

function COMMANDS.health()
    print(json.encode(AgentOps.Health()))
end

function COMMANDS.test(source, args)
    local suite = tostring(args and args[2] or '')
    if not suite:match('^[%w_%-]+$') then
        print(json.encode({ ok = false, error = 'invalid_suite' }))
        return
    end
    if type(GetResourceState) ~= 'function' then
        print(json.encode({ ok = false, error = 'resource_state_unavailable' }))
        return
    end
    local stateOk, resourceState = pcall(GetResourceState, 'custom-testing')
    if not stateOk or resourceState ~= 'started' then
        print(json.encode({ ok = false, error = 'custom_testing_not_running', state = tostring(resourceState) }))
        return
    end

    local ok, err
    -- In this repo each resource has its own Lua state, so _G.Test is only
    -- populated when a test harness loads this file in-process. The normal
    -- path dispatches the existing `/test run` command, which calls
    -- Test.run(suite) inside custom-testing.
    local Test = _G.Test
    if type(Test) == 'table' and type(Test.run) == 'function' then
        ok, err = pcall(function() Test.run(suite, source) end)
    elseif type(ExecuteCommand) == 'function' then
        ok, err = pcall(function() ExecuteCommand(('test run %s'):format(suite)) end)
    else
        ok, err = false, 'execute_command_unavailable'
    end

    emit('test', source, nil, { suite = suite, ok = ok })
    print(json.encode({
        ok = ok == true,
        suite = suite,
        error = (not ok) and AgentOps.Truncate(err, 160) or nil,
    }))
end

function COMMANDS.help()
    print(USAGE)
end

RegisterCommand('agent', function(source, args, rawCommand)
    local sub = tostring(args and args[1] or 'help'):lower()
    local allowed, reason = AgentOps.CanRun(source)
    if not allowed then
        print(('[custom-agent-ops] denied source=%s command=%s reason=%s'):format(
            tostring(source), sub, tostring(reason)))
        emit('security', source, nil, { command = sub, reason = reason })
        return
    end

    local handler = COMMANDS[sub]
    if not handler then
        print(USAGE)
        return
    end

    local ok, err = pcall(handler, source, args or {}, rawCommand)
    if not ok then
        print(json.encode({
            ok = false,
            error = 'command_failed',
            command = sub,
            detail = AgentOps.Truncate(err, 160),
        }))
    end
end, false)

-- ---------------------------------------------------------------------------
-- Server exports (called by custom-director / custom-agent-client)
-- ---------------------------------------------------------------------------

local function invoker()
    if type(GetInvokingResource) ~= 'function' then return nil, false end
    local ok, name = pcall(GetInvokingResource)
    if not ok then return nil, true end
    return name, true
end

--- Only a server export call may push: an in-process caller has no invoking
--- resource, so it is rejected instead of being able to spoof agent events.
function AgentOps.PushExternal(eventType, data, callingResource)
    if type(eventType) ~= 'string' then return false, 'invalid_type' end
    eventType = eventType:lower()
    if #eventType < 1 or #eventType > 48 or not eventType:match('^[a-z][a-z0-9_.%-]*$') then
        return false, 'invalid_type'
    end
    if data ~= nil and type(data) ~= 'table' then return false, 'invalid_data' end

    local limit = clampInt(cfg('external_push_per_second', 20), 0, 1000, 20)
    if limit > 0 then
        local now = nowMs()
        local bucket = state.pushBucket
        local elapsed = math.max(0, now - bucket.at)
        bucket.tokens = math.min(limit, bucket.tokens + elapsed * (limit / 1000))
        bucket.at = now
        if bucket.tokens < 1 then return false, 'rate_limited' end
        bucket.tokens = bucket.tokens - 1
    end

    local payload = {}
    if type(data) == 'table' then
        for key, value in pairs(data) do payload[key] = value end
    end
    if callingResource then
        payload.invoker = AgentOps.Truncate(callingResource, 64)
    end

    local citizenid = nil
    if type(payload.citizenid) == 'string' then
        citizenid = payload.citizenid
        payload.citizenid = nil
    end

    local event = emit(eventType, 0, citizenid, payload)
    if not event then return false, 'ring_unavailable' end
    return event.id
end

exports('GetAgentSnapshot', function()
    return AgentOps.GetSnapshot()
end)

exports('GetAgentEvents', function(sinceId, limit)
    return AgentOps.GetEvents(sinceId, limit)
end)

exports('PushAgentEvent', function(eventType, data)
    local callingResource, hasApi = invoker()
    if hasApi and callingResource == nil then
        return false, 'not_export'
    end
    return AgentOps.PushExternal(eventType, data, callingResource)
end)

exports('HealthSnapshot', function()
    return AgentOps.Health()
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AgentOps.Start()
    if state.started then return end
    state.started = true

    resolveLog()
    local resources = resourceStates()
    state.snapshot.resources = resources
    state.snapshot.missing = collectMissing(resources, REQUIRED_RESOURCES)
    state.snapshot.optional_down = collectMissing(resources, OPTIONAL_RESOURCES)

    emit('resource', 0, nil, {
        resource = RESOURCE,
        state = 'started',
        version = AgentOps.VERSION,
    })
    print(('[custom-agent-ops] started (ring=%d, audit=%dms, snapshot=%dms, file_log=%s)'):format(
        RING_CAPACITY,
        clampInt(cfg('poll_audit_ms', 2000), 500, 60000, 2000),
        clampInt(cfg('poll_snapshot_ms', 5000), 1000, 60000, 5000),
        logState.mode))

    AgentOps.RefreshSnapshot()

    local auditInterval = clampInt(cfg('poll_audit_ms', 2000), 500, 60000, 2000)
    CreateThread(function()
        while state.started do
            Wait(auditInterval)
            if state.started then AgentOps.PollAudit() end
        end
    end)

    local snapshotInterval = clampInt(cfg('poll_snapshot_ms', 5000), 1000, 60000, 5000)
    CreateThread(function()
        while state.started do
            Wait(snapshotInterval)
            if state.started then AgentOps.RefreshSnapshot() end
        end
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == RESOURCE then AgentOps.Start() end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == RESOURCE then
        state.started = false
        print(('[custom-agent-ops] stopped (ring=%d, dropped=%d)'):format(
            #state.ring.items, state.ring.dropped))
    end
end)

-- `onResourceStart` fires after scripts load; this bootstrap also covers a
-- reload where the event was missed. Start() is idempotent.
CreateThread(function()
    Wait(0)
    if type(GetResourceState) == 'function' then
        local ok, resourceState = pcall(GetResourceState, RESOURCE)
        if ok and resourceState == 'started' then AgentOps.Start() end
    end
end)
