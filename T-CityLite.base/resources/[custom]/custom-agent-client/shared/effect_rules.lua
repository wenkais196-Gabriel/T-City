-- shared/effect_rules.lua — pure validation rules for the agent effect channel.
--
-- Loaded as a FiveM shared_script and also with dofile() from the Lua harness,
-- so this file must not touch any FiveM global. It only normalises one action
-- payload; the decision to execute anything stays on the server
-- (server/main.lua) and the client only dispatches an already-normalised
-- message.
--
--   local normalized, err = EffectRules.Normalize('send_notify', payload, cfg)
--   -- on success: normalized table, nil
--   -- on failure: nil, { ok = false, code = ..., message = ... }
--
-- `cfg` may tighten the built-in text caps (max_notify_chars,
-- max_text_ui_body); it can never raise them.

local EffectRules = {}
_G.EffectRules = EffectRules

EffectRules.VERSION = 1

EffectRules.MAP_BOUNDS = {
    x_min = -4500, x_max = 8500,
    y_min = -4500, y_max = 8500,
    z_min = -200, z_max = 3000,
}

-- site = 'client' runs through tcity:agent:exec; site = 'server' is a
-- server-authoritative action and must never be forwarded to a client.
EffectRules.ACTIONS = {
    send_notify = { site = 'client', risk = 'L1', cancellable = false },
    play_anim = { site = 'client', risk = 'L1', cancellable = true },
    clear_anim = { site = 'client', risk = 'L1', cancellable = false },
    teleport = { site = 'client', risk = 'L2', cancellable = false },
    screen_effect = { site = 'client', risk = 'L1', cancellable = true },
    open_text_ui = { site = 'client', risk = 'L1', cancellable = true },
    give_vehicle_keys = { site = 'server', risk = 'L3', cancellable = false },
}

EffectRules.NOTIFY_KINDS = {
    info = true,
    success = true,
    warning = true,
    error = true,
    primary = true,
}

EffectRules.SCREEN_EFFECTS = {
    DrugsMichaelAliensFight = true,
    DeathFailOut = true,
    Rampage = true,
}

-- Lua patterns have no {n,m} repetition, so length is checked separately.
local DICT_PATTERN = '^[A-Za-z0-9@_%-%.]+$'
local PLATE_PATTERN = '^[A-Z0-9]+$'
local CLIP_MAX = 80
local DICT_MAX = 80

local function invalid(code, message)
    return nil, { ok = false, code = code, message = message }
end

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

-- Character count for valid UTF-8; unknown bytes are a validation failure
-- rather than a silent byte-length fallback.
local function textLength(value)
    if type(value) ~= 'string' then return nil end
    local ok, length = pcall(utf8.len, value)
    if ok and length then return length end
    return nil
end

-- \t, \n and \r are allowed (multi-line help text); every other C0 control
-- character is rejected.
local function hasControlChars(value)
    local printable = value:gsub('[\t\n\r]', '')
    return printable:find('%c') ~= nil
end

-- Distinguishes "too long" (stable error code for callers) from other
-- validation failures such as wrong type or invalid UTF-8.
local function lengthErrorCode(value, maximum)
    local length = textLength(value)
    if length and length > maximum then return 'text_too_long' end
    return 'invalid_params'
end

local function normalizeText(value, minimum, maximum)
    if type(value) ~= 'string' then
        return nil, 'must be a string'
    end
    local length = textLength(value)
    if not length then return nil, 'must be valid UTF-8' end
    if length < minimum then return nil, 'must not be empty' end
    if length > maximum then return nil, ('must be at most %d characters'):format(maximum) end
    if hasControlChars(value) then return nil, 'must not contain control characters' end
    return value, nil
end

local function checkFields(payload, allowed)
    if payload == nil then return {} end
    if type(payload) ~= 'table' then return nil, 'payload must be a table' end
    for key in pairs(payload) do
        if type(key) ~= 'string' or not allowed[key] then
            return nil, ('unknown field: %s'):format(tostring(key))
        end
    end
    return payload, nil
end

local function capValue(cfg, key, fallback)
    local value = type(cfg) == 'table' and cfg[key] or nil
    if isFiniteNumber(value) then
        value = math.floor(value)
        if value >= 1 and value < fallback then return value end
    end
    return fallback
end

function EffectRules.ClampLimit(value, minimum, maximum)
    minimum = isFiniteNumber(minimum) and minimum or 0
    maximum = isFiniteNumber(maximum) and maximum or minimum
    local number = tonumber(value)
    if not number or number ~= number then number = minimum end
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

-- `clock` is injected so tests are deterministic; production uses the wall
-- clock because the value is only used for audit timestamps.
function EffectRules.NowMs(clock)
    if type(clock) == 'function' then
        local ok, value = pcall(clock)
        if ok and isFiniteNumber(value) then return math.floor(value) end
    end
    return os.time() * 1000
end

function EffectRules.ExecutionSite(action)
    local definition = EffectRules.ACTIONS[action]
    return definition and definition.site or nil
end

function EffectRules.Redact(payload)
    if type(payload) ~= 'table' then return {} end
    local redacted = {}
    for key, value in pairs(payload) do
        if type(key) == 'string' and (key == 'text' or key == 'body') then
            if type(value) == 'string' then
                redacted[key == 'text' and 'text_len' or 'body_len'] = textLength(value) or #value
            end
        else
            redacted[key] = value
        end
    end
    return redacted
end

--- Normalise one action payload.
---@param action string
---@param payload table|nil
---@param cfg table|nil
---@return table|nil normalized, table|nil err
function EffectRules.Normalize(action, payload, cfg)
    if type(action) ~= 'string' or not EffectRules.ACTIONS[action] then
        return invalid('action_not_allowed', ('unknown action: %s'):format(tostring(action)))
    end

    if action == 'send_notify' then
        local body, fieldErr = checkFields(payload, { text = true, kind = true })
        if not body then return invalid('invalid_params', fieldErr) end
        local maxText = capValue(cfg, 'max_notify_chars', 300)
        local text, textErr = normalizeText(body.text, 1, maxText)
        if not text then
            return invalid(lengthErrorCode(body.text, maxText), 'text ' .. tostring(textErr))
        end
        local kind = body.kind
        if kind == nil then kind = 'info' end
        if type(kind) ~= 'string' or not EffectRules.NOTIFY_KINDS[kind] then
            return invalid('invalid_params', 'kind must be one of info/success/warning/error/primary')
        end
        return { text = text, kind = kind }
    end

    if action == 'play_anim' then
        local body, fieldErr = checkFields(payload, { dict = true, clip = true, duration_ms = true })
        if not body then return invalid('invalid_params', fieldErr) end
        if type(body.dict) ~= 'string' or #body.dict < 1 or #body.dict > DICT_MAX
            or not body.dict:match(DICT_PATTERN) then
            return invalid('anim_not_whitelisted', 'dict must match ^[A-Za-z0-9@_%-%.]{1,80}$')
        end
        if type(body.clip) ~= 'string' or #body.clip < 1 or #body.clip > CLIP_MAX
            or not body.clip:match(DICT_PATTERN) then
            return invalid('invalid_params', 'clip must match ^[A-Za-z0-9@_%-%.]{1,80}$')
        end
        if not isFiniteNumber(body.duration_ms) then
            return invalid('invalid_params', 'duration_ms must be a number')
        end
        local duration = math.floor(body.duration_ms)
        if duration < 1000 or duration > 60000 then
            return invalid('invalid_params', 'duration_ms must be within 1000..60000')
        end
        return { dict = body.dict, clip = body.clip, duration_ms = duration }
    end

    if action == 'clear_anim' then
        local body, fieldErr = checkFields(payload, {})
        if not body then return invalid('invalid_params', fieldErr) end
        return {}
    end

    if action == 'teleport' then
        local body, fieldErr = checkFields(payload, { x = true, y = true, z = true, heading = true })
        if not body then return invalid('invalid_params', fieldErr) end
        if not isFiniteNumber(body.x) or not isFiniteNumber(body.y) or not isFiniteNumber(body.z) then
            return invalid('invalid_params', 'x/y/z must be finite numbers')
        end
        local bounds = EffectRules.MAP_BOUNDS
        if body.x < bounds.x_min or body.x > bounds.x_max
            or body.y < bounds.y_min or body.y > bounds.y_max
            or body.z < bounds.z_min or body.z > bounds.z_max then
            return invalid('invalid_params', 'coordinates are outside the GTA map bounds')
        end
        local normalized = { x = body.x, y = body.y, z = body.z }
        if body.heading ~= nil then
            if not isFiniteNumber(body.heading) or body.heading < 0 or body.heading > 360 then
                return invalid('invalid_params', 'heading must be within 0..360')
            end
            normalized.heading = body.heading
        end
        return normalized
    end

    if action == 'screen_effect' then
        local body, fieldErr = checkFields(payload, { name = true, duration_ms = true })
        if not body then return invalid('invalid_params', fieldErr) end
        if type(body.name) ~= 'string' or not EffectRules.SCREEN_EFFECTS[body.name] then
            return invalid('invalid_params', 'screen effect is not whitelisted')
        end
        if not isFiniteNumber(body.duration_ms) then
            return invalid('invalid_params', 'duration_ms must be a number')
        end
        local duration = math.floor(body.duration_ms)
        if duration < 500 or duration > 15000 then
            return invalid('invalid_params', 'duration_ms must be within 500..15000')
        end
        return { name = body.name, duration_ms = duration }
    end

    if action == 'open_text_ui' then
        local body, fieldErr = checkFields(payload, { title = true, body = true, timeout_ms = true })
        if not body then return invalid('invalid_params', fieldErr) end
        local title, titleErr = normalizeText(body.title, 1, 80)
        if not title then
            return invalid(lengthErrorCode(body.title, 80), 'title ' .. tostring(titleErr))
        end
        local maxBody = capValue(cfg, 'max_text_ui_body', 1000)
        local message, messageErr = normalizeText(body.body, 1, maxBody)
        if not message then
            return invalid(lengthErrorCode(body.body, maxBody), 'body ' .. tostring(messageErr))
        end
        if not isFiniteNumber(body.timeout_ms) then
            return invalid('invalid_params', 'timeout_ms must be a number')
        end
        local timeout = math.floor(body.timeout_ms)
        if timeout < 1000 or timeout > 30000 then
            return invalid('invalid_params', 'timeout_ms must be within 1000..30000')
        end
        return { title = title, body = message, timeout_ms = timeout }
    end

    if action == 'give_vehicle_keys' then
        local body, fieldErr = checkFields(payload, { plate = true })
        if not body then return invalid('invalid_params', fieldErr) end
        if type(body.plate) ~= 'string' or #body.plate < 1 or #body.plate > 8
            or not body.plate:match(PLATE_PATTERN) then
            return invalid('invalid_params', 'plate must match ^[A-Z0-9]{1,8}$')
        end
        return { plate = body.plate }
    end

    -- ACTIONS is a literal whitelist; this line is unreachable unless a new
    -- action is added to the table without a validator.
    return invalid('action_not_allowed', ('action has no validator: %s'):format(action))
end

return EffectRules
