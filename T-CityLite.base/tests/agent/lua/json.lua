-- tests/agent/lua/json.lua — dependency-free JSON codec for Lua 5.4.
local json = {}
_G.json = json
local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function decodeError(pos, message)
    error(('json decode error at byte %d: %s'):format(pos, message), 0)
end
local function utf8Char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
    if cp < 0x10000 then return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)) end
    if cp <= 0x10FFFF then return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)) end
    decodeError(1, 'unicode codepoint out of range')
end
function json.decode(text)
    if type(text) ~= 'string' then decodeError(1, 'expected a string') end
    local pos, length = 1, #text
    local parseValue
    local function skipWhitespace()
        while pos <= length do
            local byte = text:byte(pos)
            if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then return end
            pos = pos + 1
        end
    end
    local function parseString()
        pos = pos + 1
        local buffer = {}
        while true do
            if pos > length then decodeError(pos, 'unterminated string') end
            local char = text:sub(pos, pos)
            if char == '"' then pos = pos + 1; return table.concat(buffer) end
            if char ~= '\\' then
                if char:byte() < 0x20 then decodeError(pos, 'control character in string') end
                buffer[#buffer + 1] = char
                pos = pos + 1
            else
                local escape = text:sub(pos + 1, pos + 1)
                if escape == '"' or escape == '\\' or escape == '/' then
                    buffer[#buffer + 1] = escape
                    pos = pos + 2
                elseif escape == 'b' or escape == 'f' or escape == 'n'
                    or escape == 'r' or escape == 't' then
                    buffer[#buffer + 1] = ({ b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[escape]
                    pos = pos + 2
                elseif escape == 'u' then
                    local hex = text:sub(pos + 2, pos + 5)
                    if not hex:match('^%x%x%x%x$') then decodeError(pos, 'invalid unicode escape') end
                    local cp = tonumber(hex, 16)
                    pos = pos + 6
                    if cp >= 0xD800 and cp <= 0xDBFF then
                        if text:sub(pos, pos + 1) ~= '\\u' then decodeError(pos, 'missing low surrogate') end
                        local lowHex = text:sub(pos + 2, pos + 5)
                        if not lowHex:match('^%x%x%x%x$') then decodeError(pos, 'invalid low surrogate') end
                        local low = tonumber(lowHex, 16)
                        if low < 0xDC00 or low > 0xDFFF then decodeError(pos, 'invalid low surrogate') end
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                        pos = pos + 6
                    elseif cp >= 0xDC00 and cp <= 0xDFFF then
                        decodeError(pos, 'unexpected low surrogate')
                    end
                    buffer[#buffer + 1] = utf8Char(cp)
                else
                    decodeError(pos, 'invalid escape sequence')
                end
            end
        end
    end
    local function parseNumber()
        local start = pos
        local plain = text:match('^-?%d+%.?%d*', pos)
        if not plain or plain:match('^-?0%d') or plain:match('%.$') then decodeError(pos, 'invalid number') end
        pos = pos + #plain
        local exponent = text:match('^[eE][+-]?%d+', pos)
        if exponent then pos = pos + #exponent end
        local number = tonumber(text:sub(start, pos - 1))
        if not number then decodeError(start, 'invalid number') end
        return number
    end
    local function parseObject()
        pos = pos + 1
        local object = {}
        skipWhitespace()
        if text:sub(pos, pos) == '}' then pos = pos + 1; return object end
        while true do
            skipWhitespace()
            if text:sub(pos, pos) ~= '"' then decodeError(pos, 'expected object key') end
            local key = parseString()
            skipWhitespace()
            if text:sub(pos, pos) ~= ':' then decodeError(pos, "expected ':'") end
            pos = pos + 1
            object[key] = parseValue()
            skipWhitespace()
            local char = text:sub(pos, pos)
            if char == '}' then pos = pos + 1; return object end
            if char ~= ',' then decodeError(pos, "expected ',' or '}'") end
            pos = pos + 1
        end
    end
    local function parseArray()
        pos = pos + 1
        local array, index = {}, 1
        skipWhitespace()
        if text:sub(pos, pos) == ']' then pos = pos + 1; return array end
        while true do
            array[index] = parseValue()
            index = index + 1
            skipWhitespace()
            local char = text:sub(pos, pos)
            if char == ']' then pos = pos + 1; return array end
            if char ~= ',' then decodeError(pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    end
    parseValue = function()
        skipWhitespace()
        if pos > length then decodeError(pos, 'unexpected end of input') end
        local char = text:sub(pos, pos)
        if char == '{' then return parseObject() end
        if char == '[' then return parseArray() end
        if char == '"' then return parseString() end
        if char == '-' or char:match('^%d$') then return parseNumber() end
        if text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true end
        if text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false end
        if text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil end
        decodeError(pos, ('unexpected character %q'):format(char))
    end
    local value = parseValue()
    skipWhitespace()
    if pos <= length then decodeError(pos, 'trailing characters') end
    return value
end
local function encodeString(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return ESCAPES[char] or ('\\u%04x'):format(char:byte())
    end) .. '"'
end
local function encodeValue(value, seen, depth)
    if depth > 100 then error('json encode error: nesting too deep', 0) end
    local kind = type(value)
    if value == nil then return 'null' end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then error('json encode error: non-finite number', 0) end
        return math.type(value) == 'integer' and ('%d'):format(value) or ('%.17g'):format(value)
    end
    if kind == 'string' then return encodeString(value) end
    if kind ~= 'table' then error('json encode error: unsupported type ' .. kind, 0) end
    if seen[value] then error('json encode error: cycle detected', 0) end
    seen[value] = true
    local count, maximum, isArray = 0, 0, true
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then isArray = false
        else
            count = count + 1
            if key > maximum then maximum = key end
        end
    end
    local encoded
    if count == 0 and isArray then
        encoded = '{}'
    elseif isArray and maximum == count then
        local parts = {}
        for index = 1, count do parts[index] = encodeValue(value[index], seen, depth + 1) end
        encoded = '[' .. table.concat(parts, ',') .. ']'
    else
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, key in ipairs(keys) do
            local name = type(key) == 'string' and key or tostring(key)
            parts[#parts + 1] = encodeString(name) .. ':' .. encodeValue(value[key], seen, depth + 1)
        end
        encoded = '{' .. table.concat(parts, ',') .. '}'
    end
    seen[value] = nil
    return encoded
end
function json.encode(value)
    local ok, result = pcall(encodeValue, value, {}, 0)
    if ok then return result end
    return nil, result
end
return json
