-- server/live_api.lua — GET /agent/v1/live/* in-memory read endpoints (M1).
--
-- Contract (frozen for the Python side):
--   GET /agent/v1/live/players?limit=1..48&job=<optional>
--       {"schema_version":1,"players":[...],"count":N,"sampled_at":ms,"precision_m":25}
--   GET /agent/v1/live/players/{citizenid}
--       {"schema_version":1,"player":{...}}
--   GET /agent/v1/live/events?since=<epoch:seq>&limit=1..200
--       {"schema_version":1,"events":[...],"next_cursor":"epoch:seq","dropped":0}
--   errors: {"error":"...","code":"..."}
--
-- Deliberately no `ok` / `data` envelope so a live response cannot be confused
-- with a director action response.
--
-- The request path is sampled directly from QBCore.Players + server natives.
-- There is no SQL, no Wait and no outbound request on this path.

local LiveApi = {}
_G.LiveApi = LiveApi

LiveApi.VERSION = 1

local LIVE_PREFIX = '/agent/v1/live/'
local PLAYERS_PATH = '/agent/v1/live/players'
local EVENTS_PATH = '/agent/v1/live/events'
local CLIENTS_PATH = '/agent/v1/live/clients'
local SERVER_PATH = '/agent/v1/live/server'
local POLICE_BOARD_PATH = '/agent/v1/live/police/board'

-- 统一走 core-framework 的公共实现（原先这里有一份相同的解析）：
-- 用函数包一层，导出在调用时解析；资源启动顺序由 fxmanifest 的 dependencies 保证。
local convarString = function(...) return exports['core-framework']:ConvarString(...) end

local function trim(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function native(name)
    local fn = _G[name]
    if type(fn) == 'function' then return fn end
    return nil
end

local function store()
    local LiveStore = _G.LiveStore
    if not LiveStore then return nil end
    return LiveStore.Default()
end

local function failure(status, code, message, headers)
    return {
        status = status,
        body = { error = message, code = code },
        headers = headers,
    }
end

-- FXServer's json.encode (lua-rapidjson) serialises an empty table as `{}`
-- unless the table is tagged as an array.  players/events must stay JSON arrays
-- even when empty so the Python side can always iterate them.
local ARRAY_METATABLE = { __jsontype = 'array' }

local function jsonArray(list)
    return setmetatable(list, ARRAY_METATABLE)
end

-- ---------------------------------------------------------------------------
-- Configuration (read per request so the kill switch is live)
-- ---------------------------------------------------------------------------

local function liveConfig(cfg)
    local enabled = convarString('agent_live_enabled', '0') == '1'

    -- Deliberately no fallback to the actions token: the whole point of the
    -- live credential is that a read-only agent cannot hold a write-capable
    -- one. A deployment that does not set agent_live_token simply has no live
    -- channel (503 live_token_not_configured).
    local token = trim(convarString('agent_live_token', ''))

    local rawPrecision = trim(convarString('agent_live_precision', '25')):lower()
    local precision = LiveRules.DEFAULT_PRECISION_M
    if rawPrecision == 'fine' then
        precision = 0
    else
        local value = tonumber(rawPrecision)
        -- Only whole metres above zero are meaningful. "0.5" used to floor to
        -- 0, which silently meant "fine" (exact coordinates).
        if value and value >= 1 and value == math.floor(value) then precision = value end
    end

    local function clampInt(name, default, minimum, maximum)
        local value = tonumber(trim(convarString(name, tostring(default))))
        if not value or value ~= value then value = default end
        value = math.floor(value)
        if value < minimum then value = minimum end
        if value > maximum then value = maximum end
        return value
    end

    return {
        enabled = enabled,
        token = token,
        precision = precision,
        rate_per_min = clampInt('agent_live_rate_per_min', 120, 0, 6000),
        burst = clampInt('agent_live_burst', 40, 1, 1000),
    }
end

-- Token bucket per live credential. The key is a cheap hash so the secret is
-- not used as a table key. agent_live_rate_per_min=0 disables the limit.
local liveBuckets = {}

local function liveKey(token)
    local hash = 5381
    for i = 1, #token do
        hash = (hash * 33 + token:byte(i)) % 4294967296
    end
    return ('%08x'):format(hash)
end

local function rateGate(live)
    if live.rate_per_min <= 0 then return nil end
    local key = liveKey(live.token)
    local now = GetGameTimer()
    local bucket = liveBuckets[key]
    if not bucket then
        bucket = { tokens = live.burst, updatedAt = now }
        liveBuckets[key] = bucket
    end
    local elapsed = math.max(0, now - bucket.updatedAt)
    if elapsed > 0 then
        bucket.tokens = math.min(live.burst, bucket.tokens + elapsed * (live.rate_per_min / 60000))
        bucket.updatedAt = now
    end
    if bucket.tokens < 1 then
        local retryMs = math.ceil((1 - bucket.tokens) / (live.rate_per_min / 60000))
        return failure(429, 'rate_limited', 'too many live requests', {
            ['Retry-After'] = tostring(math.max(1, math.ceil(retryMs / 1000))),
        })
    end
    bucket.tokens = bucket.tokens - 1
    return nil
end

local function authorized(request, token)
    local AgentHttp = _G.AgentHttp
    if not AgentHttp or type(AgentHttp.GetHeader) ~= 'function' then return false end

    local authorization = AgentHttp.GetHeader(request.headers, 'authorization')
    if type(authorization) ~= 'string' then return false end
    local presented = authorization:match('^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$')
    if not presented then return false end
    presented = trim(presented)
    if presented == '' then return false end

    if type(AgentHttp.SecureEquals) == 'function' then
        return AgentHttp.SecureEquals(presented, token)
    end
    return presented == token
end

-- ---------------------------------------------------------------------------
-- Player sampling (natives only, no PlayerData copy)
-- ---------------------------------------------------------------------------

-- live_api is loaded before main.lua, so the resource-local QBCore upvalue in
-- main is not visible here. Resolve it from the qb-core export on first use and
-- cache it on _G: relying on a global that nothing sets made the roster
-- silently return zero players on a real server (the harness set it, so tests
-- never caught it).
local function qbCore()
    -- Resolve from the export on every call. Caching the object on _G was how
    -- live_api ended up sampling a stale QBCore: whichever table it saw first
    -- was frozen, so players who joined after that call stayed invisible until
    -- the resource was restarted (count=0 with a live roster of 1, observed on
    -- a real server). The global is still refreshed for live_events.lua, but it
    -- is only a fallback for when qb-core is stopped mid-request.
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(core) == 'table' then
        _G.QBCore = core
        return core
    end
    local cached = _G.QBCore
    if type(cached) == 'table' then return cached end
    return nil
end

local function playersTable()
    local qb = qbCore()
    if type(qb) == 'table' and type(qb.Players) == 'table' then return qb.Players end
    return nil
end

local function playerData(player)
    if type(player) ~= 'table' then return nil end
    if type(player.PlayerData) == 'table' then return player.PlayerData end
    return player
end

local function coordinate(coords, axis, index)
    if coords == nil then return nil end
    local value = coords[axis]
    if type(value) == 'number' then return value end
    value = coords[index]
    if type(value) == 'number' then return value end
    return nil
end

local function sampleVehicle(getVehicle, getModel, getPlate, getSeat, ped)
    local vehicle = getVehicle(ped, false)
    if type(vehicle) ~= 'number' or vehicle == 0 then return nil end

    local model = getModel and getModel(vehicle) or nil
    local plate = getPlate and getPlate(vehicle) or nil
    local seat = -1
    if getSeat then
        local ok, driver = pcall(getSeat, vehicle, -1)
        if not ok or driver ~= ped then seat = 0 end
    end
    return { model = model, plate = plate, seat = seat }
end

local function samplePlayer(player, precision, opts, sourceHint)
    local data = playerData(player)
    if not data then return nil end

    -- PlayerData does not reliably carry the source; the roster key does.
    local source = tonumber(sourceHint) or tonumber(opts and opts.source) or tonumber(data.source)
    local sampled = {
        precision = precision,
        now_ms = LiveRules.now_ms(),
        include_money = opts and opts.include_money,
    }
    sampled.source = source

    local getPed = native('GetPlayerPed')
    local doesExist = native('DoesEntityExist')
    local getCoords = native('GetEntityCoords')
    local getHeading = native('GetEntityHeading')
    local getHealth = native('GetEntityHealth')
    local getArmor = native('GetPedArmour')
    local getVehicle = native('GetVehiclePedIsIn')
    local getModel = native('GetEntityModel')
    local getPlate = native('GetVehicleNumberPlateText')
    local getSeat = native('GetPedInVehicleSeat')
    local getBucket = native('GetPlayerRoutingBucket')
    local getPing = native('GetPlayerPing')

    local ped = nil
    if getPed and source then
        local ok, value = pcall(getPed, source)
        if ok then ped = value end
    end

    -- DoesEntityExist is unreliable on the server for remote players (it can
    -- return false for a ped that GetEntityCoords happily resolves), so it is
    -- advisory only: a non-zero ped is enough to attempt the reads.
    local exists = ped ~= nil and ped ~= 0
    if exists and doesExist then
        local ok, value = pcall(doesExist, ped)
        if ok and value == false then exists = true end
    end

    if exists then
        if getCoords then
            local ok, coords = pcall(getCoords, ped, false)
            if ok and coords then
                local x = coordinate(coords, 'x', 1)
                local y = coordinate(coords, 'y', 2)
                local z = coordinate(coords, 'z', 3)
                if x and y and z then sampled.position = { x = x, y = y, z = z } end
            end
        end
        if getHeading then
            local ok, heading = pcall(getHeading, ped)
            if ok and type(heading) == 'number' then sampled.heading = heading end
        end
        if getHealth then
            local ok, health = pcall(getHealth, ped)
            if ok and type(health) == 'number' then sampled.health = health end
        end
        if getArmor then
            local ok, armor = pcall(getArmor, ped)
            if ok and type(armor) == 'number' then sampled.armor = armor end
        end
        if getVehicle then
            local ok, vehicle = pcall(sampleVehicle, getVehicle, getModel, getPlate, getSeat, ped)
            if ok then sampled.vehicle = vehicle end
        end
    end

    if getBucket and source then
        local ok, bucket = pcall(getBucket, source)
        if ok and type(bucket) == 'number' then sampled.bucket = bucket end
    end
    if getPing and source then
        local ok, ping = pcall(getPing, source)
        if ok and type(ping) == 'number' and ping ~= 0 then sampled.ping = ping end
    end

    return LiveRules.sanitize_player(player, sampled)
end

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------

local function parseQuery(request)
    local AgentHttp = _G.AgentHttp
    local path, queryText = '/', ''
    if AgentHttp and type(AgentHttp.SplitPath) == 'function' then
        path, queryText = AgentHttp.SplitPath(tostring(request.path or '/'))
    end
    if AgentHttp and type(AgentHttp.ParseQuery) == 'function' then
        return path, AgentHttp.ParseQuery(queryText)
    end
    return path, {}
end

local function listPlayers(query, precision)
    local sourceTable = playersTable()
    if not sourceTable then return {} end

    local jobFilter = type(query.job) == 'string' and trim(query.job) or ''
    if jobFilter == '' then jobFilter = nil end

    local collected = {}
    local count = 0
    -- QBCore.Players is keyed by source (sparse), so pairs() is required to
    -- enumerate it.  The projected array is filled by index instead of
    -- table.insert and sorted once, keeping a 48-player snapshot allocation
    -- light (no per-player json.encode).
    for sourceKey, player in pairs(sourceTable) do
        local data = playerData(player)
        if data then
            local job = type(data.job) == 'table' and data.job.name or nil
            if not jobFilter or job == jobFilter then
                local projected = samplePlayer(player, precision, {
                    include_money = false,
                    source = sourceKey,
                })
                if projected then
                    count = count + 1
                    collected[count] = projected
                end
            end
        end
    end

    table.sort(collected, function(a, b) return a.citizenid < b.citizenid end)
    return collected
end

local function findPlayer(citizenid)
    local qb = qbCore()
    local getter = type(qb) == 'table' and type(qb.Functions) == 'table'
        and qb.Functions.GetPlayerByCitizenId or nil
    local sourceTable = playersTable()
    if type(getter) == 'function' then
        local ok, player = pcall(getter, citizenid)
        if ok and player then
            local data = playerData(player)
            local resolved = data and tonumber(data.source) or nil
            if not resolved and sourceTable then
                -- The getter does not expose the roster key; match it back.
                for key, candidate in pairs(sourceTable) do
                    local candidateData = playerData(candidate)
                    if candidate == player or (candidateData and data
                        and candidateData.citizenid == data.citizenid) then
                        resolved = tonumber(key)
                        break
                    end
                end
            end
            return player, resolved
        end
    end

    local sourceTable = playersTable()
    if not sourceTable then return nil end
    for sourceKey, player in pairs(sourceTable) do
        local data = playerData(player)
        if data and data.citizenid == citizenid then
            return player, tonumber(data.source) or tonumber(sourceKey)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Client / server state probes (read-only)
--
-- The snapshot starts on the client (custom-agent-client pushes it when it
-- changes) and is only ever a self-report: never a permission or policy input.
-- age_ms is stamped here, so a consumer can tell "now" from "stale".
-- ---------------------------------------------------------------------------

local CLIENT_EXECUTOR_RESOURCE = 'custom-agent-client'

local function clientSnapshot(source)
    if GetResourceState(CLIENT_EXECUTOR_RESOURCE) ~= 'started' then
        return nil, 'probe_unavailable'
    end
    local ok, data, errCode, age = pcall(function()
        return exports[CLIENT_EXECUTOR_RESOURCE]:ClientState(source)
    end)
    if not ok or type(data) ~= 'table' then
        return nil, type(errCode) == 'string' and errCode or 'client_state_unavailable'
    end
    return data, nil, tonumber(age) or 0
end

local function handleClients()
    local sourceTable = playersTable() or {}
    local collected = {}
    local count = 0
    for sourceKey, player in pairs(sourceTable) do
        local data = playerData(player)
        local citizenid = data and type(data.citizenid) == 'string' and data.citizenid or nil
        if citizenid and citizenid ~= '' then
            local snapshot, _, age = clientSnapshot(tonumber(sourceKey) or 0)
            if snapshot then
                count = count + 1
                collected[count] = {
                    citizenid = LiveRules.sanitize_text(citizenid, 32),
                    source = tonumber(sourceKey) or 0,
                    age_ms = age,
                    state = snapshot,
                }
            end
        end
    end
    table.sort(collected, function(a, b) return a.citizenid < b.citizenid end)
    return {
        status = 200,
        body = {
            schema_version = 1,
            sampled_at = LiveRules.now_ms(),
            count = count,
            clients = jsonArray(collected),
        },
    }
end

local function handleClient(citizenid)
    local player, source = findPlayer(citizenid)
    if not player or not source then
        return failure(404, 'player_not_found', 'player_not_found')
    end
    local snapshot, errCode, age = clientSnapshot(source)
    if not snapshot then
        return failure(404, errCode or 'client_state_unavailable', 'client state is unavailable')
    end
    local data = playerData(player)
    return {
        status = 200,
        body = {
            schema_version = 1,
            sampled_at = LiveRules.now_ms(),
            client = {
                citizenid = LiveRules.sanitize_text(tostring(data and data.citizenid or citizenid), 32),
                source = source,
                age_ms = age,
                state = snapshot,
            },
        },
    }
end

-- 未启动资源最多报这么多条：一个 117 资源的服务器全挂时，把 117 个名字塞进响应
-- 既没用又会被限流器当成大包。名字本身也是玩家可控之外的常量，但仍然过一遍消毒。
local NOT_STARTED_LIMIT = 40

local function handleServerState()
    local total, started = 0, 0
    local notStarted, stopped = {}, 0
    if type(GetNumResources) == 'function' then
        total = GetNumResources() or 0
        for index = 0, total - 1 do
            local name = GetResourceByFindIndex(index)
            if name then
                -- "started" 之外还有 stopping/stopped/uninitialized/missing，
                -- 对排查来说它们是同一件事：这个资源现在没在跑。
                if GetResourceState(name) == 'started' then
                    started = started + 1
                else
                    stopped = stopped + 1
                    if #notStarted < NOT_STARTED_LIMIT then
                        notStarted[#notStarted + 1] = LiveRules.sanitize_text(name, 64)
                    end
                end
            end
        end
    end
    local players = 0
    for _ in pairs(playersTable() or {}) do players = players + 1 end
    local weather = nil
    if GetResourceState('qb-weathersync') == 'started' then
        local ok, value = pcall(function() return exports['qb-weathersync']:getWeatherState() end)
        if ok and type(value) == 'string' then weather = LiveRules.sanitize_text(value, 32) end
    end
    return {
        status = 200,
        body = {
            schema_version = 1,
            sampled_at = LiveRules.now_ms(),
            uptime_s = math.floor((tonumber(GetGameTimer()) or 0) / 1000),
            players = players,
            resources = {
                started = started,
                total = total,
                -- 名单比数字有用："83/117" 不告诉你是哪 34 个没起。
                not_started = notStarted,
                not_started_truncated = stopped > NOT_STARTED_LIMIT,
            },
            weather = weather,
        },
    }
end


local function handlePlayers(request, live)
    local _, query = parseQuery(request)
    local limit = LiveRules.clamp_limit(query.limit, LiveRules.DEFAULT_LIST_LIMIT, 1, LiveRules.MAX_LIST_LIMIT)
    local players = listPlayers(query, live.precision)
    if #players > limit then
        local limited = {}
        for index = 1, limit do limited[index] = players[index] end
        players = limited
    end

    return {
        status = 200,
        body = {
            schema_version = 1,
            players = jsonArray(players),
            count = #players,
            sampled_at = LiveRules.now_ms(),
            precision_m = live.precision,
        },
    }
end

local function handlePlayer(request, live, citizenid)
    -- Compare with the same normalisation the list projection uses, otherwise
    -- a citizenid that the list sanitises would 404 on the detail route.
    local wanted = LiveRules.sanitize_text(citizenid, 32)
    local player, sourceKey
    if wanted then player, sourceKey = findPlayer(wanted) end
    if not player then
        return failure(404, 'player_not_found', 'player not found')
    end
    local projected = samplePlayer(player, live.precision, nil, sourceKey)
    if not projected then
        return failure(404, 'player_not_found', 'player not found')
    end
    return { status = 200, body = { schema_version = 1, player = projected } }
end

local function handleEvents(request)
    local buffer = store()
    if not buffer then
        return failure(503, 'live_store_unavailable', 'live store unavailable')
    end

    local _, query = parseQuery(request)
    local limit = LiveRules.clamp_limit(query.limit, LiveRules.DEFAULT_EVENT_LIMIT, 1, LiveRules.MAX_EVENT_LIMIT)

    local since = nil
    if query.since ~= nil and query.since ~= '' then
        local cursor, cursorError = buffer:ParseCursor(query.since)
        if not cursor then
            return failure(400, 'invalid_cursor', cursorError or 'invalid cursor')
        end
        since = cursor
    end

    local events, meta = buffer:List(since, limit)
    if not events then
        if meta and meta.code == 'cursor_epoch_mismatch' then
            return failure(409, 'cursor_epoch_mismatch', 'cursor epoch does not match', {
                ['X-Agent-Live-Epoch'] = buffer.epoch,
            })
        end
        if meta and meta.code == 'cursor_expired' then
            return failure(410, 'cursor_expired', 'cursor is older than the ring window')
        end
        return failure(400, 'invalid_cursor', 'invalid cursor')
    end

    return {
        status = 200,
        body = {
            schema_version = 1,
            events = jsonArray(events),
            next_cursor = meta.next_cursor,
            dropped = meta.dropped,
        },
        headers = {
            ['X-Agent-Live-Epoch'] = meta.epoch,
            ['X-Agent-Live-Seq'] = tostring(meta.newest_seq),
        },
    }
end

-- ---------------------------------------------------------------------------
-- Entry point (called at the top of AgentHttp.Handle)
-- ---------------------------------------------------------------------------

-- Returns nil for non-live paths so the existing director routes are untouched.
-- Test hook: drop the rate-limit buckets (not a FiveM export).
function LiveApi._ResetRateLimit()
    liveBuckets = {}
end

-- GET /agent/v1/live/police/board — dispatch board without PII: callsign,
-- department and status only for on-duty units; incident id/code/title/
-- priority/status only. No citizenid, names, positions or narratives.
local function handlePoliceBoard()
    local units = MySQL.query.await([[
        SELECT callsign, dept, status FROM police_units
        WHERE status <> 'off_duty' AND status <> 'unavailable'
        ORDER BY callsign ASC LIMIT 100
    ]]) or {}
    local incidents = MySQL.query.await([[
        SELECT id, code, title, priority, status, created_at FROM police_incidents
        WHERE status NOT IN ('closed') ORDER BY priority ASC, id DESC LIMIT 50
    ]]) or {}
    return {
        status = 200,
        body = {
            schema_version = 1,
            units = jsonArray(units),
            incidents = jsonArray(incidents),
            generated_at = os.time(),
        },
    }
end

function LiveApi.TryHandle(request, cfg)
    if type(request) ~= 'table' then return nil end
    local rawPath = tostring(request.path or '/')
    if rawPath:sub(1, #LIVE_PREFIX) ~= LIVE_PREFIX then return nil end

    local live = liveConfig(cfg)
    if not live.enabled then
        return failure(503, 'live_disabled', 'live perception is disabled')
    end
    if live.token == '' then
        return failure(503, 'live_token_not_configured', 'live token is not configured')
    end
    if not authorized(request, live.token) then
        return failure(401, 'unauthorized', 'unauthorized', { ['WWW-Authenticate'] = 'Bearer' })
    end
    local limited = rateGate(live)
    if limited then return limited end

    local method = tostring(request.method or ''):upper()
    if method ~= 'GET' then
        return failure(405, 'method_not_allowed', 'method not allowed', { ['Allow'] = 'GET' })
    end

    local path = parseQuery(request)
    if path == PLAYERS_PATH then return handlePlayers(request, live) end
    if path == CLIENTS_PATH then return handleClients() end
    if path == SERVER_PATH then return handleServerState() end

    local clientCitizenid = path:match('^' .. CLIENTS_PATH .. '/([^/]+)$')
    if clientCitizenid and clientCitizenid ~= '' then
        return handleClient(clientCitizenid)
    end

    if path == EVENTS_PATH then return handleEvents(request) end
    if path == POLICE_BOARD_PATH then return handlePoliceBoard() end

    local citizenid = path:match('^' .. PLAYERS_PATH .. '/([^/]+)$')
    if citizenid and citizenid ~= '' then
        return handlePlayer(request, live, citizenid)
    end

    return failure(404, 'not_found', 'not found')
end

return LiveApi
