-- server/main.lua — server side of the agent effect channel.
--
-- Invariants (design 02 §6):
--   * only the server initiates work; `tcity:agent:ready` is the sole inbound
--     trigger and carries no execution intent
--   * `tcity:agent:ack` is telemetry: it settles a pending request and is
--     audited, but never changes game state
--   * every dispatch ends in exactly one audit line, including timeouts,
--     disconnects and resource stops

local Rules = _G.EffectRules

if not Rules then
    print('[custom-agent-client] shared/effect_rules.lua was not loaded; resource disabled')
    return
end

local sessions = {}   -- sessions[src] = { token = 16 hex, seq = number }
local pending = {}    -- pending[src][rid] = entry
local inflight = {}   -- inflight[src] = number
local droppedAcks = 0

-- ---------------------------------------------------------------------------
-- Configuration (read per call so the kill switch is live)
-- ---------------------------------------------------------------------------

-- 统一走 core-framework 的公共实现（原先这里有一份相同的解析）：
-- 用函数包一层，导出在调用时解析；资源启动顺序由 fxmanifest 的 dependencies 保证。
local convarString = function(...) return exports['core-framework']:ConvarString(...) end

-- 统一走 core-framework 的公共实现（Clamp 语义已包含在内）
local convarInt = function(...) return exports['core-framework']:ConvarInt(...) end

local function Config()
    return {
        enabled = convarString('agent_effect_enabled', '0') == '1',
        rate_per_min = convarInt('agent_effect_rate_per_min', 20, 1, 600),
        burst = convarInt('agent_effect_burst', 5, 1, 100),
        max_inflight = convarInt('agent_effect_max_inflight', 4, 1, 100),
        audit = convarString('agent_effect_audit', '1') ~= '0',
    }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function mkerr(code, message, detail)
    return { ok = false, code = code, message = message, detail = detail }
end

local function truncate(value, limit)
    local text = tostring(value or '')
    if #text > limit then return text:sub(1, limit) end
    return text
end

local function randomHex(length)
    local parts = {}
    for index = 1, length do
        parts[index] = ('%x'):format(math.random(0, 15))
    end
    return table.concat(parts)
end

-- Audit never contains notify text or open_text_ui body; payloads are only
-- summarised through the terminal status. custom-logs is optional: when the
-- export is unavailable the line falls back to console.
--
-- The DB audit (agent_effects) is metadata only: request id, caller, target
-- source, action, terminal status, a bounded error CODE and the measured
-- latency. Payload values (notify body, UI title/body, phone numbers, ...)
-- are never written to the database, mirroring the custom-logs line above.
local auditFailures = 0
local AUDIT_STATUS = {
    ok = true,
    rejected = true,
    failed = true,
    cancelled = true,
    timeout = true,
    player_offline = true,
    executor_stopped = true,
}

local function auditInsertFailed(reason)
    auditFailures = auditFailures + 1
    -- A missing table fails on every request: print the first failure, then
    -- only every tenth one, so a broken migration cannot flood the console
    -- with one error per effect.
    if auditFailures == 1 or auditFailures % 10 == 0 then
        print(('[custom-agent-client] agent_effects audit insert failed (%d): %s')
            :format(auditFailures, truncate(reason, 200)))
    end
end

local function auditToDb(entry, status, elapsed)
    if not Config().audit then return end
    local errorCode
    if type(entry.err) == 'table' and type(entry.err.code) == 'string' then
        -- Only a machine token may reach the column. The ack text is client
        -- controlled, so anything else collapses to client_error instead of
        -- storing arbitrary prose in a field documented as a code.
        errorCode = entry.err.code
        if not errorCode:match('^[a-z0-9_]+$') or #errorCode > 64 then
            errorCode = 'client_error'
        end
    end
    local ok, err = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO agent_effects
                (request_id, agent_id, target_source, action, status, error_code, latency_ms)
            VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), ?)
        ]], {
            truncate(entry.requestId, 80),
            truncate(entry.agentId or 'unknown', 64),
            math.floor(tonumber(entry.src) or 0),
            truncate(entry.action, 32),
            AUDIT_STATUS[status] and status or 'failed',
            truncate(errorCode or '', 64),
            math.max(0, math.floor(elapsed)),
        })
    end)
    if not ok then auditInsertFailed(err) end
    -- Best effort: the caller's result is settled before this runs and is
    -- never changed by an insert failure.
end

local function audit(entry, status)
    local elapsed = math.max(0, GetGameTimer() - (entry.startedAt or GetGameTimer()))
    local line = ('[agent-effect] agent=%s src=%s action=%s status=%s ms=%d'):format(
        tostring(entry.agentId or 'unknown'),
        tostring(entry.src),
        tostring(entry.action),
        tostring(status),
        elapsed)
    local logged = false
    if _G.GetResourceState and GetResourceState('custom-logs') == 'started' then
        logged = pcall(function()
            return exports['custom-logs']:LogGeneric('agent-effect', line)
        end)
    end
    if not logged then print(line) end
    auditToDb(entry, status, elapsed)
end

-- Idempotent: deletes the timer, releases the in-flight slot, resolves the
-- caller's promise and writes exactly one audit line.
local function settle(src, rid, status, result, err)
    local bySource = pending[src]
    local entry = bySource and bySource[rid]
    if not entry or entry.settled then return false end
    entry.settled = true
    bySource[rid] = nil
    inflight[src] = math.max(0, (inflight[src] or 1) - 1)
    if entry.timer then
        ClearTimeout(entry.timer)
        entry.timer = nil
    end
    entry.err = err
    entry.promise:resolve({ ok = status == 'ok', status = status, result = result, err = err })
    audit(entry, status)
    return true
end

local function rateGate(src, cfg)
    -- 走 core-framework 的限流 owner（原来这里自己维护 buckets 令牌桶）
    local allowed, retryAfter = exports['core-framework']:RateLimitTokenBucket(
        'agent:' .. tostring(src), cfg.rate_per_min, cfg.burst)
    if allowed then return nil end
    return mkerr('rate_limited', 'too many effects for this player',
        { retry_after_ms = retryAfter })
end

-- ---------------------------------------------------------------------------
-- Server API
-- ---------------------------------------------------------------------------

--- Dispatch one client effect to one player.
--- Must be called from a coroutine (HTTP handler, CreateThread, event handler).
---@param src number          resolved by the server, never from a payload
---@param action string
---@param payload table|nil
---@param timeoutMs number|table|nil  timeout in ms, or an opts table
---@param opts table|nil      { timeout_ms = number, agent_id = string }
---@return boolean ok, table|nil result, table|nil err
local function clientExec(src, action, payload, timeoutMs, opts)
    if not coroutine.isyieldable() then
        return false, nil, mkerr('not_yieldable', 'clientExec must run inside a coroutine')
    end
    -- Accept the design's export shape Execute(src, action, payload, opts) as
    -- well as the positional timeout used by this slice.
    if type(timeoutMs) == 'table' and opts == nil then
        opts = timeoutMs
        timeoutMs = opts.timeout_ms
    end
    opts = opts or {}

    local cfg = Config()
    if not cfg.enabled then
        return false, nil, mkerr('executor_disabled', 'agent effect channel is disabled')
    end
    if type(src) ~= 'number' or src <= 0 or GetPlayerPed(src) == 0 then
        return false, nil, mkerr('player_offline', 'player is not online')
    end

    local normalized, normalizeErr = Rules.Normalize(action, payload, cfg)
    if not normalized then return false, nil, normalizeErr end

    -- give_vehicle_keys is server-authoritative; this slice validates it but
    -- deliberately refuses to execute it instead of forwarding it to a client.
    if Rules.ExecutionSite(action) == 'server' then
        return false, nil, mkerr('server_action_unsupported',
            'give_vehicle_keys is not implemented in this slice')
    end

    if (inflight[src] or 0) >= cfg.max_inflight then
        return false, nil, mkerr('too_many_inflight', 'too many in-flight effects for this player')
    end
    local limited = rateGate(src, cfg)
    if limited then return false, nil, limited end

    local session = sessions[src]
    if not session then
        return false, nil, mkerr('handshake_missing', 'client has not sent tcity:agent:ready')
    end

    session.seq = session.seq + 1
    local rid = ('%s-%d-%04x'):format(session.token:sub(1, 8), session.seq, math.random(0, 0xffff))
    local timeout = tonumber(timeoutMs) or 4000

    pending[src] = pending[src] or {}
    local entry = {
        src = src,
        requestId = rid,
        action = action,
        payload = normalized,
        session = session.token,
        agentId = truncate(opts.agent_id or 'unknown', 64),
        startedAt = GetGameTimer(),
        promise = promise.new(),
    }
    pending[src][rid] = entry
    inflight[src] = (inflight[src] or 0) + 1

    entry.timer = SetTimeout(timeout, function()
        settle(src, rid, 'timeout', nil,
            mkerr('timeout', ('no ack within %dms'):format(timeout)))
    end)

    TriggerClientEvent('tcity:agent:exec', src, {
        v = 1,
        request_id = rid,
        session = session.token,
        action = action,
        timeout_ms = timeout,
        issued_at = os.time(),
        payload = normalized,
    })

    local awaited = Citizen.Await(entry.promise)
    return awaited.ok, awaited.result, awaited.err
end

local function dropAck()
    droppedAcks = droppedAcks + 1
end

local ACK_STATUS = { ok = true, rejected = true, failed = true, cancelled = true }

-- Telemetry only. An ack can settle a request, never write game state.
RegisterNetEvent('tcity:agent:ack', function(ack)
    local src = source
    if type(ack) ~= 'table' or ack.v ~= 1 then return dropAck() end
    local rid = ack.request_id
    if type(rid) ~= 'string' or rid == '' or #rid > 80 then return dropAck() end
    local entry = (pending[src] or {})[rid]
    if not entry or entry.session ~= ack.session then return dropAck() end
    if not ACK_STATUS[ack.status] then return dropAck() end
    if ack.detail ~= nil and type(ack.detail) ~= 'table' then return dropAck() end
    if entry.settled then return dropAck() end

    local detail = ack.detail
    if ack.status == 'ok' then
        return settle(src, rid, 'ok', detail, nil)
    end
    if ack.status == 'cancelled' then
        return settle(src, rid, 'cancelled', nil,
            mkerr('cancelled', 'client cancelled the effect', detail))
    end
    local fallback = ack.status == 'rejected' and 'client_rejected' or 'client_failed'
    -- The client is untrusted: strip control characters and bound both the
    -- code and the message before they can reach the agent's context.
    local function safeText(value, limit)
        if type(value) ~= 'string' then return nil end
        local text = value:gsub('%c', ' '):sub(1, limit)
        return text
    end
    local code = safeText(ack.error_code, 64) or fallback
    local message = safeText(detail and detail.message, 200) or fallback
    settle(src, rid, ack.status, nil, mkerr(code, message, { message = message }))
end)

RegisterNetEvent('tcity:agent:ready', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local session = sessions[src]
    if not session then
        session = { token = randomHex(16), seq = 0 }
        sessions[src] = session
    end
    TriggerClientEvent('tcity:agent:hello', src, { v = 1, session = session.token })
end)

---@return boolean accepted false = unknown rid, already settled or offline
local function cancel(src, rid)
    local entry = (pending[src] or {})[rid]
    if not entry or entry.settled then return false end
    TriggerClientEvent('tcity:agent:cancel', src, {
        v = 1,
        session = entry.session,
        request_id = rid,
    })
    settle(src, rid, 'cancelled', nil, mkerr('cancelled', 'cancelled by server'))
    return true
end

local function stats()
    local pendingCount, inflightCount, sessionCount = 0, 0, 0
    for _, bySource in pairs(pending) do
        for _ in pairs(bySource) do pendingCount = pendingCount + 1 end
    end
    for _, count in pairs(inflight) do inflightCount = inflightCount + count end
    for _ in pairs(sessions) do sessionCount = sessionCount + 1 end
    return {
        ok = true,
        pending = pendingCount,
        inflight = inflightCount,
        sessions = sessionCount,
        dropped_acks = droppedAcks,
        enabled = Config().enabled,
    }
end

-- ---------------------------------------------------------------------------
-- Client state probe (read-only)
--
-- The client pushes a snapshot when it changes; the server decides what may be
-- kept. Everything below is a whitelist: unknown keys never reach the cache, and
-- a value that is out of range is clamped instead of trusted. Snapshots expire,
-- so a stale one reports "unavailable" rather than looking like live truth.
-- ---------------------------------------------------------------------------

local STATE_TTL_MS = 15000
local STATE_MIN_INTERVAL_MS = 250 -- 4/s：事件推送常与 5s 心跳撞车，1s 窗口会把"刚按完"的那一份丢掉

local stateBySrc = {} -- [src] = { at = gameTimerMs, data = table, dropped = n }

local function clampInt(value, min, max, fallback)
    local number = tonumber(value)
    if not number then return fallback end
    number = math.floor(number)
    if number ~= number then return fallback end
    if number < min then return min end
    if number > max then return max end
    return number
end

local function flag(value)
    return value == true
end

local function enum(value, allowed)
    if type(value) ~= 'string' then return nil end
    for _, candidate in ipairs(allowed) do
        if value == candidate then return candidate end
    end
    return nil
end

local function shortToken(value)
    if type(value) ~= 'string' then return nil end
    if value == '' or #value > 16 or not value:match('^[a-z0-9_]+$') then return nil end
    return value
end

local function sanitizeState(raw)
    if type(raw) ~= 'table' then return nil end
    -- 版本守卫：没有 v=1 的报文一律不认。否则一个空表就能注册出"全默认"的快照，
    -- 让 /clients 报一个 logged_in=false 的假客户端。
    if tonumber(raw.v) ~= 1 then return nil end
    local phone = type(raw.phone) == 'table' and raw.phone or nil
    local ped = type(raw.ped) == 'table' and raw.ped or nil
    local screen = type(raw.screen) == 'table' and raw.screen or nil
    return {
        v = 1,
        logged_in = flag(raw.logged_in),
        phone = phone and {
            open = flag(phone.open),
            surface = enum(phone.surface, { 'phone', 'tablet' }),
            focused = flag(phone.focused),
            keep_input = flag(phone.keep_input),
            -- 引擎原生的原话，和上面的记账分开放：两者不一致正是"原生在撒谎"的证据。
            nui_focus_native = flag(phone.nui_focus_native),
            focus_owner = shortToken(phone.focus_owner),
        } or nil,
        ped = {
            in_vehicle = flag(ped and ped.in_vehicle),
            vehicle_class = clampInt(ped and ped.vehicle_class, 0, 23, 0),
            health = clampInt(ped and ped.health, 0, 1000, 0),
            dead = flag(ped and ped.dead),
        },
        -- 单 App 状态：只放行三个短 token，缺任何一个就整块丢掉。
        app = (function()
            local app = type(raw.app) == 'table' and raw.app or nil
            if not app then return nil end
            local id = shortToken(app.id)
            if not id then return nil end
            return { id = id, tab = shortToken(app.tab), selected = shortToken(app.selected) }
        end)(),
        screen = {
            w = clampInt(screen and screen.w, 320, 8192, 0),
            h = clampInt(screen and screen.h, 320, 8192, 0),
        },
    }
end

RegisterNetEvent('tcity:agent:state', function(raw)
    local src = source
    if not src or src <= 0 then return end
    local now = GetGameTimer() or 0
    local previous = stateBySrc[src]
    if previous and (now - previous.at) < STATE_MIN_INTERVAL_MS then
        previous.dropped = (previous.dropped or 0) + 1
        return
    end
    local clean = sanitizeState(raw)
    if not clean then return end
    stateBySrc[src] = { at = now, data = clean, dropped = previous and previous.dropped or 0 }
end)

--- Read one player's snapshot. Returns data, errCode, ageMs.
local function clientState(src)
    local entry = stateBySrc[src]
    if not entry then return nil, 'client_state_unavailable' end
    local now = GetGameTimer() or 0
    local age = now - entry.at
    if age > STATE_TTL_MS then
        return nil, 'client_state_unavailable', age
    end
    return entry.data, nil, age
end
exports('ClientState', clientState)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    for rid in pairs(pending[src] or {}) do
        settle(src, rid, 'player_offline', nil, mkerr('player_offline', 'player dropped'))
    end
    pending[src] = nil
    inflight[src] = nil
    sessions[src] = nil
    stateBySrc[src] = nil
    -- 这里原来还有一行 buckets[src] = nil：限流改成 core-framework 的令牌桶 owner 之后
    -- buckets 已经不存在了，那行就成了"每次玩家掉线报一次 attempt to index a nil value (global 'buckets')"。
    -- 令牌桶按 'agent:<src>' 键在 owner 里，过期自然清掉，不需要在这里回收。
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    stateBySrc = {}
    for src in pairs(pending) do
        for rid in pairs(pending[src]) do
            settle(src, rid, 'executor_stopped', nil,
                mkerr('executor_stopped', 'executor resource stopped'))
        end
    end
end)

exports('Execute', clientExec)
exports('Cancel', cancel)
exports('Stats', stats)

print(('[custom-agent-client] loaded (enabled=%s). Exports: Execute, Cancel, Stats, ClientState'):format(
    tostring(Config().enabled)))
