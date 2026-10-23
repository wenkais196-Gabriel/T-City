-- server/sms.lua — pure SMS helpers shared by custom-phone and its tests.
--
-- Kept free of FiveM globals so the Lua harness can load it directly. The
-- export in server/main.lua does the IO; everything that decides whether an
-- input is acceptable lives here.

Sms = {}

-- ---------------------------------------------------------------------------
-- DB result normalisation (shared by every custom-phone server script).
--
-- The bundled oxmysql backend returns `{ insertId = n, affectedRows = n }`
-- from `insert` / `update`, while stock oxmysql returns plain numbers. Every
-- write callback must go through these helpers so a table is never used as a
-- numeric id or compared with a number.
-- ---------------------------------------------------------------------------
PhoneDb = {}

---@param result table|number|nil
---@return number insertId  0 when the insert failed or returned no id
function PhoneDb.InsertId(result)
    if type(result) == 'table' then result = result.insertId end
    return tonumber(result) or 0
end

---@param result table|number|nil
---@return number affectedRows
function PhoneDb.AffectedRows(result)
    if type(result) == 'table' then result = result.affectedRows end
    return tonumber(result) or 0
end

--- Truncate to at most `limit` UTF-8 characters (not bytes).
function Sms.TruncateChars(value, limit)
    if type(value) ~= 'string' then return '' end
    if #value <= limit then return value end
    if utf8 and utf8.len and utf8.offset then
        local ok, length = pcall(utf8.len, value)
        if ok and length and length > limit then
            local offsetOk, byteEnd = pcall(utf8.offset, value, limit + 1)
            if offsetOk and byteEnd then return value:sub(1, byteEnd - 1) end
        end
    end
    return value:sub(1, limit)
end

--- Truncate to at most `limit` bytes without splitting a UTF-8 sequence.
function Sms.TruncateBytes(value, limit)
    if type(value) ~= 'string' then return '' end
    if #value <= limit then return value end
    local cut = limit
    while cut > 0 do
        local byte = value:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return value:sub(1, cut)
end

--- Sender label for system messages; phone_messages.sender_number is
--- VARCHAR(20), so the cap is bytes, not characters.
function Sms.SenderLabel(label)
    if type(label) ~= 'string' then return 'City Services' end
    local cleaned = label:gsub('%c', '')
    if cleaned == '' then return 'City Services' end
    return Sms.TruncateBytes(cleaned, 20)
end

---@return boolean ok, string|nil errCode
function Sms.Validate(receiverNumber, message)
    if type(receiverNumber) ~= 'string' or #receiverNumber == 0 or #receiverNumber > 15 then
        return false, 'invalid_params'
    end
    if type(message) ~= 'string' or #message == 0 or #message > 500 then
        return false, 'invalid_params'
    end
    return true
end

return Sms
