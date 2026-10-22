-- server/live_rules.lua — pure projection rules for live perception (M1).
--
-- Deliberately has no FiveM, MySQL, QBCore or fs dependency: it can be loaded by
-- plain Lua 5.4 and unit-tested (tests/agent/lua/cases/live_rules.lua).
--
-- The only way player data can leave this module is sanitize_player(), which
-- builds a fresh table from an explicit allow-list.  Nothing here copies
-- PlayerData (or any nested table) wholesale, so license / ip / identifiers /
-- charinfo.phone / inventory can never leak through a live response.

local LiveRules = {}
_G.LiveRules = LiveRules

LiveRules.VERSION = 1
LiveRules.DEFAULT_PRECISION_M = 25
LiveRules.DEFAULT_LIST_LIMIT = 48
LiveRules.MAX_LIST_LIMIT = 48
LiveRules.DEFAULT_EVENT_LIMIT = 50
LiveRules.MAX_EVENT_LIMIT = 200

-- metadata keys that may appear in a live response.
LiveRules.METADATA_KEYS = {
    health = true,
    armor = true,
    hunger = true,
    thirst = true,
    stress = true,
    isdead = true,
    inlaststand = true,
    ishandcuffed = true,
}

local NUMERIC_METADATA = { 'health', 'armor', 'hunger', 'thirst', 'stress' }

local function tonumberOr(value, default)
    local number = tonumber(value)
    if number == nil or number ~= number then return default end
    return number
end

-- ---------------------------------------------------------------------------
-- Limits / time
-- ---------------------------------------------------------------------------

-- Clamps like AgentPolicy.NormalizeLimit: invalid input falls back to the
-- default, out-of-range values are clamped instead of rejected.
function LiveRules.clamp_limit(value, defaultLimit, minLimit, maxLimit)
    defaultLimit = defaultLimit or LiveRules.DEFAULT_LIST_LIMIT
    minLimit = minLimit or 1
    maxLimit = maxLimit or LiveRules.MAX_LIST_LIMIT

    local limit = tonumber(value)
    if not limit or limit ~= limit then limit = defaultLimit end
    limit = math.floor(limit)
    if limit < minLimit then limit = minLimit end
    if limit > maxLimit then limit = maxLimit end
    return limit
end

-- `clock` is injected so tests are deterministic; production uses os.time.
function LiveRules.now_ms(clock)
    if type(clock) == 'function' then
        local ok, value = pcall(clock)
        if ok and type(value) == 'number' and value == value then
            return math.floor(value)
        end
    end
    return os.time() * 1000
end

-- ---------------------------------------------------------------------------
-- Text / PII helpers
-- ---------------------------------------------------------------------------

-- Cut at a UTF-8 boundary. Byte-wise sub() can leave a dangling lead byte,
-- which makes json.encode produce invalid UTF-8 and breaks the whole response
-- for every player, not just the one with the long name.
local function utf8_truncate(text, maxBytes)
    if not maxBytes or #text <= maxBytes then return text end
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        local width = 1
        if byte >= 0xF0 then width = 4
        elseif byte >= 0xE0 then width = 3
        elseif byte >= 0xC0 then width = 2 end
        if index + width - 1 > maxBytes then return text:sub(1, index - 1) end
        index = index + width
    end
    return text
end

-- Zero-width, bidi and C1 controls can hide text from a human reviewer while
-- still reaching the model. Strip them before truncating.
local ZERO_WIDTH = '\226\128[\139-\143\170-\174]'
local BIDI_ISOLATES = '\226\129[\166-\169]'
local BOM = '\239\187\191'
local C1 = '\194[\128-\159]'

function LiveRules.sanitize_text(value, maxLength)
    if type(value) ~= 'string' then return nil end
    -- Bound the work before running any gsub: a 1 MB display name must not
    -- cost 16 ms per player. UTF-8 is at most 4 bytes per character.
    local text = value
    if maxLength and #text > maxLength * 4 then text = text:sub(1, maxLength * 4) end
    text = text:gsub('%c', ''):gsub(ZERO_WIDTH, ''):gsub(BIDI_ISOLATES, '')
        :gsub(BOM, ''):gsub(C1, '')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    return utf8_truncate(text, maxLength)
end

-- Plate is PII: keep the first and last two characters and mask the middle.
-- Short plates are masked entirely so a 2-4 character plate is not fully
-- recoverable from the response.
function LiveRules.mask_plate(plate)
    if type(plate) ~= 'string' then return nil end
    local text = LiveRules.sanitize_text(plate, 16)
    if not text or text == '' then return nil end
    if #text <= 4 then return string.rep('*', #text) end
    return text:sub(1, 2) .. string.rep('*', #text - 4) .. text:sub(-2)
end

-- ---------------------------------------------------------------------------
-- Position quantisation
-- ---------------------------------------------------------------------------

local function quantize(value, precision)
    return math.floor(value / precision + 0.5) * precision
end

-- precision <= 0 / nil means "fine": return the coordinates untouched.
function LiveRules.quantize_position(position, precision)
    if type(position) ~= 'table' then return nil end
    local x = tonumber(position.x)
    local y = tonumber(position.y)
    local z = tonumber(position.z)
    if not x or not y or not z then return nil end

    local meters = tonumber(precision)
    if not meters or meters <= 0 then
        return { x = x, y = y, z = z }
    end
    return {
        x = quantize(x, meters),
        y = quantize(y, meters),
        z = quantize(z, meters),
    }
end

-- ---------------------------------------------------------------------------
-- Metadata allow-list
-- ---------------------------------------------------------------------------

function LiveRules.sanitize_metadata(metadata)
    local result = {
        isdead = false,
        inlaststand = false,
        ishandcuffed = false,
    }
    if type(metadata) ~= 'table' then return result end

    for index = 1, #NUMERIC_METADATA do
        local key = NUMERIC_METADATA[index]
        local value = tonumber(metadata[key])
        if value then result[key] = value end
    end

    result.isdead = metadata.isdead == true
    result.inlaststand = metadata.inlaststand == true
    -- Repository uses both spellings depending on the qb-core version.
    result.ishandcuffed = metadata.ishandcuffed == true or metadata.handcuffed == true
    return result
end

-- ---------------------------------------------------------------------------
-- Player projection
-- ---------------------------------------------------------------------------

local function project_job(job)
    if type(job) ~= 'table' then
        return { name = 'unemployed', label = 'Unemployed', grade = 0, onduty = false }
    end
    local level = 0
    if type(job.grade) == 'table' then
        level = tonumberOr(job.grade.level, 0)
    else
        level = tonumberOr(job.grade, 0)
    end
    local name = type(job.name) == 'string' and LiveRules.sanitize_text(job.name, 32) or 'unemployed'
    local label = type(job.label) == 'string' and LiveRules.sanitize_text(job.label, 64) or name
    return {
        name = name or 'unemployed',
        label = label or 'Unemployed',
        grade = level,
        onduty = job.onduty == true,
    }
end

local function project_gang(gang)
    if type(gang) ~= 'table' then
        return { name = 'none', grade = 0 }
    end
    local level = 0
    if type(gang.grade) == 'table' then
        level = tonumberOr(gang.grade.level, 0)
    else
        level = tonumberOr(gang.grade, 0)
    end
    local name = type(gang.name) == 'string' and LiveRules.sanitize_text(gang.name, 32) or 'none'
    return { name = name or 'none', grade = level }
end

local function project_money(money)
    money = type(money) == 'table' and money or {}
    return {
        cash = tonumberOr(money.cash, 0),
        bank = tonumberOr(money.bank, 0),
        crypto = tonumberOr(money.crypto, 0),
    }
end

local function project_vehicle(vehicle)
    if type(vehicle) ~= 'table' then return nil end
    return {
        model = tonumber(vehicle.model),
        plate = LiveRules.mask_plate(vehicle.plate),
        seat = tonumberOr(vehicle.seat, -1),
    }
end

-- opts:
--   precision   number   25 = coarse (default), <= 0 = fine
--   position    {x,y,z}  sampled natively by live_api
--   heading     number
--   vehicle     {model,plate,seat} only while the player is in a vehicle
--   bucket      number
--   ping        number
--   health      number   live GetEntityHealth overrides cached metadata
--   armor       number   live GetPedArmour overrides cached metadata
--   now_ms      number   last_seen_ms
--   clock       function injected clock (used when now_ms is absent)
function LiveRules.sanitize_player(player, opts)
    opts = opts or {}
    local data
    if type(player) == 'table' then
        data = type(player.PlayerData) == 'table' and player.PlayerData or player
    end
    if type(data) ~= 'table' then return nil end

    local citizenid = type(data.citizenid) == 'string' and LiveRules.sanitize_text(data.citizenid, 32) or nil
    if not citizenid or citizenid == '' then return nil end

    local metadata = LiveRules.sanitize_metadata(data.metadata)
    if opts.health ~= nil then
        local health = tonumber(opts.health)
        if health then metadata.health = health end
    end
    if opts.armor ~= nil then
        local armor = tonumber(opts.armor)
        if armor then metadata.armor = armor end
    end

    local precision = opts.precision
    if precision == nil then precision = LiveRules.DEFAULT_PRECISION_M end

    local lastSeen = tonumber(opts.now_ms)
    if not lastSeen then lastSeen = LiveRules.now_ms(opts.clock) end

    return {
        citizenid = citizenid,
        -- Display name only: it is player-controlled text and is flagged as
        -- untrusted by the tool registry; never the license or identifiers.
        name = LiveRules.sanitize_text(data.name, 64),
        source = tonumberOr(data.source, 0),
        job = project_job(data.job),
        gang = project_gang(data.gang),
        money = project_money(data.money),
        metadata = metadata,
        position = LiveRules.quantize_position(opts.position, precision),
        heading = tonumber(opts.heading),
        bucket = tonumber(opts.bucket),
        ping = tonumber(opts.ping),
        vehicle = project_vehicle(opts.vehicle),
        last_seen_ms = lastSeen,
    }
end

return LiveRules
