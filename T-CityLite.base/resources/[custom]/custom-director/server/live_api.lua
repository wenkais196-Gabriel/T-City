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

local function convarString(name, default)
    if type(GetConvar) == 'function' then
        local value = GetConvar(name, default)
        if type(value) == 'string' then return value end
    end
    return default
end

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

    local token = trim(convarString('agent_live_token', ''))
    if token == '' and type(cfg) == 'table' and type(cfg.token) == 'string' then
        -- Backwards-compatible fallback: live may share the actions token.
        token = trim(cfg.token)
    end

    local rawPrecision = trim(convarString('agent_live_precision', '25')):lower()
    local precision = LiveRules.DEFAULT_PRECISION_M
    if rawPrecision == 'fine' then
        precision = 0
    else
        local value = tonumber(rawPrecision)
        if value and value > 0 and value == value then precision = math.floor(value) end
    end

    return { enabled = enabled, token = token, precision = precision }
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

local function playersTable()
    local qb = _G.QBCore
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

local function samplePlayer(player, precision)
    local data = playerData(player)
    if not data then return nil end

    local source = tonumber(data.source)
    local sampled = { precision = precision, now_ms = LiveRules.now_ms() }

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

    local exists = false
    if ped and ped ~= 0 then
        exists = true
        if doesExist then
            local ok, value = pcall(doesExist, ped)
            exists = ok and value == true
        end
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
    for _, player in pairs(sourceTable) do
        local data = playerData(player)
        if data then
            local job = type(data.job) == 'table' and data.job.name or nil
            if not jobFilter or job == jobFilter then
                local projected = samplePlayer(player, precision)
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
    local qb = _G.QBCore
    local getter = type(qb) == 'table' and type(qb.Functions) == 'table'
        and qb.Functions.GetPlayerByCitizenId or nil
    if type(getter) == 'function' then
        local ok, player = pcall(getter, citizenid)
        if ok and player then return player end
    end

    local sourceTable = playersTable()
    if not sourceTable then return nil end
    for _, player in pairs(sourceTable) do
        local data = playerData(player)
        if data and data.citizenid == citizenid then return player end
    end
    return nil
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
    local player = findPlayer(citizenid)
    if not player then
        return failure(404, 'player_not_found', 'player not found')
    end
    local projected = samplePlayer(player, live.precision)
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

    local method = tostring(request.method or ''):upper()
    if method ~= 'GET' then
        return failure(405, 'method_not_allowed', 'method not allowed', { ['Allow'] = 'GET' })
    end

    local path = parseQuery(request)
    if path == PLAYERS_PATH then return handlePlayers(request, live) end
    if path == EVENTS_PATH then return handleEvents(request) end

    local citizenid = path:match('^' .. PLAYERS_PATH .. '/([^/]+)$')
    if citizenid and citizenid ~= '' then
        return handlePlayer(request, live, citizenid)
    end

    return failure(404, 'not_found', 'not found')
end

return LiveApi
