--[[
    MenuSpec P0 Schema Contract & Pure Validator
    Side-effect-free Lua module testable standalone in lua5.4.
]]

MenuSpec = {}

MenuSpec.SURFACES = {
    list = true,
    form = true,
    confirm = true,
    range = true,
}

MenuSpec.KINDS = {
    action = true,
    toggle = true,
    input = true,
    range = true,
    confirm = true,
    nav = true,
    info = true,
    progress = true,
}

MenuSpec.THEMES = {
    noir = true,
    amber = true,
    ice = true,
}

MenuSpec.DENSITIES = {
    comfortable = true,
    compact = true,
}

MenuSpec.TONES = {
    default = true,
    accent = true,
    success = true,
    warning = true,
    danger = true,
    info = true,
}

local TOP_ALLOWED = {
    id = true,
    title = true,
    subtitle = true,
    surface = true,
    items = true,
    theme = true,
    density = true,
    breadcrumbs = true,
    intent = true,
    cancelIntent = true,
    backIntent = true,
    submitLabel = true,
    cancelLabel = true,
    confirmLabel = true,
    danger = true,
    doubleConfirm = true,
    message = true,
    emptyMessage = true,
    closeOnSubmit = true,
    closeOnBack = true,
}

local ITEM_ALLOWED = {
    id = true,
    kind = true,
    label = true,
    description = true,
    subtitle = true,
    hint = true,
    icon = true,
    badge = true,
    badgeTone = true,
    group = true,
    disabled = true,
    disabledReason = true,
    tone = true,
    danger = true,
    intent = true,
    args = true,
    value = true,
    defaultValue = true,
    checked = true,
    placeholder = true,
    required = true,
    pattern = true,
    minLength = true,
    maxLength = true,
    inputType = true,
    min = true,
    max = true,
    step = true,
    unit = true,
    progress = true,
    progressMax = true,
    doubleConfirm = true,
    confirmMessage = true,
    confirmLabel = true,
    cancelLabel = true,
}

local INPUT_TYPES = {
    text = true,
    number = true,
    password = true,
}

local BADGE_ALLOWED = {
    text = true,
    tone = true,
}

local function isNonEmptyString(v)
    return type(v) == 'string' and #v > 0
end

local function isSequentialArray(tbl)
    if type(tbl) ~= 'table' then
        return false
    end
    local count = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
            return false
        end
        count = count + 1
    end
    return count == #tbl
end

local function checkSafeValue(val, path, visited)
    local vt = type(val)
    if vt == 'function' or vt == 'thread' or vt == 'userdata' then
        return false, ('Function or non-serializable %s not allowed at %s'):format(vt, path)
    end
    if vt ~= 'table' then
        return true, nil
    end
    if visited[val] then
        return false, ('Cyclic table reference not allowed at %s'):format(path)
    end
    visited[val] = true
    for k, v in pairs(val) do
        local kt = type(k)
        if kt == 'function' or kt == 'thread' or kt == 'userdata' then
            visited[val] = nil
            return false, ('Function or non-serializable key (%s) not allowed at %s'):format(kt, path)
        end
        if kt ~= 'string' and kt ~= 'number' then
            visited[val] = nil
            return false, ('Invalid key type %s at %s'):format(kt, path)
        end
        local ok, err = checkSafeValue(v, path .. '.' .. tostring(k), visited)
        if not ok then
            visited[val] = nil
            return false, err
        end
    end
    visited[val] = nil
    return true, nil
end

local function validateIntentField(value, fieldName, path, knownIntents)
    if value == nil then
        return true, nil
    end
    if not isNonEmptyString(value) or #value > 128 then
        return false, ('Invalid %s at %s: must be a non-empty string <= 128 chars'):format(fieldName, path)
    end
    if type(knownIntents) ~= 'table' then
        return false, ('knownIntents set is required when %s is specified (%s at %s)'):format(fieldName, value, path)
    end
    if knownIntents[value] ~= true then
        return false, ('Unknown %s %q at %s'):format(fieldName, value, path)
    end
    return true, nil
end

local function validateOptionalString(tbl, key, path)
    local v = tbl[key]
    if v ~= nil and type(v) ~= 'string' then
        return false, ('Field %s at %s must be a string'):format(key, path)
    end
    return true, nil
end

local function validateOptionalBoolean(tbl, key, path)
    local v = tbl[key]
    if v ~= nil and type(v) ~= 'boolean' then
        return false, ('Field %s at %s must be a boolean'):format(key, path)
    end
    return true, nil
end

local function validateOptionalNumber(tbl, key, path)
    local v = tbl[key]
    if v ~= nil and type(v) ~= 'number' then
        return false, ('Field %s at %s must be a number'):format(key, path)
    end
    return true, nil
end

local function validateBadge(badge, badgeTone, path)
    if badge ~= nil then
        local bt = type(badge)
        if bt == 'string' then
            if badgeTone ~= nil and not MenuSpec.TONES[badgeTone] then
                return false, ('Invalid badgeTone at %s'):format(path)
            end
        elseif bt == 'table' then
            for k, _ in pairs(badge) do
                if not BADGE_ALLOWED[k] then
                    return false, ('Unknown badge field %q at %s'):format(tostring(k), path)
                end
            end
            if not isNonEmptyString(badge.text) then
                return false, ('badge.text at %s must be a non-empty string'):format(path)
            end
            if badge.tone ~= nil and not MenuSpec.TONES[badge.tone] then
                return false, ('Invalid badge.tone at %s'):format(path)
            end
        else
            return false, ('Field badge at %s must be string or { text, tone }'):format(path)
        end
    elseif badgeTone ~= nil and not MenuSpec.TONES[badgeTone] then
        return false, ('Invalid badgeTone at %s'):format(path)
    end
    return true, nil
end

local function validateItem(item, index, knownIntents, seenIds)
    local path = ('items[%d]'):format(index)
    if type(item) ~= 'table' then
        return false, ('%s must be a table'):format(path)
    end

    for k, _ in pairs(item) do
        if type(k) ~= 'string' or not ITEM_ALLOWED[k] then
            return false, ('Unknown field %q at %s'):format(tostring(k), path)
        end
    end

    if not isNonEmptyString(item.id) or #item.id > 64 then
        return false, ('Missing or invalid item id at %s (required string, <= 64 chars)'):format(path)
    end
    if seenIds[item.id] then
        return false, ('Duplicate item id %q at %s'):format(item.id, path)
    end
    seenIds[item.id] = true

    if not isNonEmptyString(item.kind) or not MenuSpec.KINDS[item.kind] then
        return false, ('Invalid item kind %q at %s'):format(tostring(item.kind), path)
    end
    if item.kind == 'info' then
        if item.action ~= nil then
            return false, ('Info item at %s must not specify action'):format(path)
        end
        if item.params ~= nil then
            return false, ('Info item at %s must not specify params'):format(path)
        end
        if item.intent ~= nil then
            return false, ('Info item at %s must not specify intent'):format(path)
        end
    end
    if not isNonEmptyString(item.label) then
        return false, ('Missing or invalid item label at %s'):format(path)
    end

    for _, strField in ipairs({
        'description', 'subtitle', 'hint', 'icon', 'group',
        'disabledReason', 'placeholder', 'pattern', 'unit',
        'confirmMessage', 'confirmLabel', 'cancelLabel',
    }) do
        local ok, err = validateOptionalString(item, strField, path)
        if not ok then
            return false, err
        end
    end

    for _, boolField in ipairs({ 'disabled', 'danger', 'checked', 'required', 'doubleConfirm' }) do
        local ok, err = validateOptionalBoolean(item, boolField, path)
        if not ok then
            return false, err
        end
    end

    for _, numField in ipairs({ 'minLength', 'maxLength', 'min', 'max', 'step', 'progress', 'progressMax' }) do
        local ok, err = validateOptionalNumber(item, numField, path)
        if not ok then
            return false, err
        end
    end

    if item.tone ~= nil and not MenuSpec.TONES[item.tone] then
        return false, ('Invalid item tone %q at %s'):format(tostring(item.tone), path)
    end

    if item.inputType ~= nil and not INPUT_TYPES[item.inputType] then
        return false, ('Invalid inputType %q at %s'):format(tostring(item.inputType), path)
    end

    if item.min ~= nil and item.max ~= nil and item.min > item.max then
        return false, ('Invalid range bounds min > max at %s'):format(path)
    end
    if item.step ~= nil and item.step <= 0 then
        return false, ('Invalid step <= 0 at %s'):format(path)
    end
    if item.progressMax ~= nil and item.progressMax <= 0 then
        return false, ('Invalid progressMax <= 0 at %s'):format(path)
    end
    if item.minLength ~= nil and item.maxLength ~= nil and item.minLength > item.maxLength then
        return false, ('Invalid minLength > maxLength at %s'):format(path)
    end

    if item.args ~= nil and type(item.args) ~= 'table' then
        return false, ('Field args at %s must be a table'):format(path)
    end

    local okBadge, errBadge = validateBadge(item.badge, item.badgeTone, path)
    if not okBadge then
        return false, errBadge
    end

    local okIntent, errIntent = validateIntentField(item.intent, 'intent', path, knownIntents)
    if not okIntent then
        return false, errIntent
    end

    return true, nil
end

--- Pure MenuSpec contract validation.
--- @param spec table
--- @param opts table|nil Optional `{ knownIntents = { [intentName] = true } }`
--- @return boolean, string|nil
function MenuSpec.Validate(spec, opts)
    if type(spec) ~= 'table' then
        return false, 'MenuSpec must be a table'
    end
    if opts ~= nil and type(opts) ~= 'table' then
        return false, 'Validate opts must be a table when provided'
    end

    local okSafe, errSafe = checkSafeValue(spec, 'spec', {})
    if not okSafe then
        return false, errSafe
    end

    for k, _ in pairs(spec) do
        if type(k) ~= 'string' or not TOP_ALLOWED[k] then
            return false, ('Unknown top-level field: %s'):format(tostring(k))
        end
    end

    if not isNonEmptyString(spec.id) or #spec.id > 64 then
        return false, 'Invalid top-level id: must be a non-empty string with length <= 64'
    end
    if not isNonEmptyString(spec.title) then
        return false, 'Invalid top-level title: must be a non-empty string'
    end
    if not isNonEmptyString(spec.surface) or not MenuSpec.SURFACES[spec.surface] then
        return false, ('Invalid top-level surface %q: expected list|form|confirm|range'):format(tostring(spec.surface))
    end
    if not isSequentialArray(spec.items) then
        return false, 'Invalid top-level items: must be a dense array table'
    end

    if spec.theme ~= nil and not MenuSpec.THEMES[spec.theme] then
        return false, ('Invalid top-level theme: %s'):format(tostring(spec.theme))
    end
    if spec.density ~= nil and not MenuSpec.DENSITIES[spec.density] then
        return false, ('Invalid top-level density: %s'):format(tostring(spec.density))
    end

    for _, strField in ipairs({ 'subtitle', 'submitLabel', 'cancelLabel', 'confirmLabel', 'message', 'emptyMessage' }) do
        local ok, err = validateOptionalString(spec, strField, 'spec')
        if not ok then
            return false, err
        end
    end
    for _, boolField in ipairs({ 'danger', 'doubleConfirm', 'closeOnSubmit', 'closeOnBack' }) do
        local ok, err = validateOptionalBoolean(spec, boolField, 'spec')
        if not ok then
            return false, err
        end
    end

    if spec.breadcrumbs ~= nil then
        if not isSequentialArray(spec.breadcrumbs) then
            return false, 'Top-level breadcrumbs must be an array of strings'
        end
        for i = 1, #spec.breadcrumbs do
            if not isNonEmptyString(spec.breadcrumbs[i]) then
                return false, ('breadcrumbs[%d] must be a non-empty string'):format(i)
            end
        end
    end

    local knownIntents = opts and opts.knownIntents or nil
    for _, intentKey in ipairs({ 'intent', 'cancelIntent', 'backIntent' }) do
        local ok, err = validateIntentField(spec[intentKey], intentKey, 'spec', knownIntents)
        if not ok then
            return false, err
        end
    end

    local seenIds = {}
    for i = 1, #spec.items do
        local okItem, errItem = validateItem(spec.items[i], i, knownIntents, seenIds)
        if not okItem then
            return false, errItem
        end
    end

    return true, nil
end

return MenuSpec
