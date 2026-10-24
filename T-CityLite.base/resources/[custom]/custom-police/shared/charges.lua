-- shared/charges.lua — one charge catalogue for every arrest/citation path.
-- The ids, sentences and fines mirror custom-justice's Config.Justice.Crimes
-- (13 entries). Kept locally so an arrest can be priced and sentenced without
-- a cross-resource call; the ids are the values custom-justice expects in
-- JusticeService.Imprison.
PoliceCharges = {}

local MAX_CHARGES = 8

-- Ordered so the MDT renders a stable catalogue.
local ORDER = {
    'murder', 'assault', 'kidnapping',
    'drug_traffic', 'drug_possess', 'drug_produce',
    'robbery', 'burglary', 'theft', 'fraud',
    'evasion', 'trespass', 'weapon_poss',
}

local CHARGES = {
    murder       = { id = 'murder',       label = '谋杀',      baseMinutes = 120, fine = 50000 },
    assault      = { id = 'assault',      label = '故意伤害',  baseMinutes = 30,  fine = 15000 },
    kidnapping   = { id = 'kidnapping',   label = '绑架',      baseMinutes = 60,  fine = 30000 },
    drug_traffic = { id = 'drug_traffic', label = '毒品贩运',  baseMinutes = 90,  fine = 80000 },
    drug_possess = { id = 'drug_possess', label = '持有毒品',  baseMinutes = 15,  fine = 10000 },
    drug_produce = { id = 'drug_produce', label = '制造毒品',  baseMinutes = 60,  fine = 50000 },
    robbery      = { id = 'robbery',      label = '抢劫',      baseMinutes = 45,  fine = 25000 },
    burglary     = { id = 'burglary',     label = '入室盗窃',  baseMinutes = 30,  fine = 20000 },
    theft        = { id = 'theft',        label = '盗窃',      baseMinutes = 15,  fine = 10000 },
    fraud        = { id = 'fraud',        label = '诈骗',      baseMinutes = 30,  fine = 40000 },
    evasion      = { id = 'evasion',      label = '拒捕/逃逸', baseMinutes = 20,  fine = 15000 },
    trespass     = { id = 'trespass',     label = '非法入侵',  baseMinutes = 10,  fine = 5000 },
    weapon_poss  = { id = 'weapon_poss',  label = '非法持枪',  baseMinutes = 30,  fine = 20000 },
}

local function trim(value)
    return type(value) == 'string' and value:match('^%s*(.-)%s*$') or ''
end

local function copy(charge)
    return {
        id = charge.id,
        label = charge.label,
        baseMinutes = charge.baseMinutes,
        fine = charge.fine,
    }
end

--- The whole catalogue, in display order. Callers get copies so the shared
--- table cannot be mutated from a UI or server handler.
---@return table[]
function PoliceCharges.List()
    local rows = {}
    for i, id in ipairs(ORDER) do rows[i] = copy(CHARGES[id]) end
    return rows
end

--- Look up one charge. Unknown, non-string or blank ids return nil.
---@param id string
---@return table|nil
function PoliceCharges.Get(id)
    local key = trim(id)
    local charge = CHARGES[key]
    return charge and copy(charge) or nil
end

--- Validate and aggregate 1..8 charge ids.
--- Accepts only ids from the catalogue (no duplicates); any other input is
--- rejected instead of being silently dropped, so a client cannot smuggle an
--- unknown charge into a sentence.
---@param ids string[]
---@return table|nil, string|nil { minutes, fine, labels }
function PoliceCharges.Sum(ids)
    if type(ids) ~= 'table' then return nil, 'invalid_charges' end
    local count = #ids
    if count < 1 or count > MAX_CHARGES then return nil, 'invalid_charges' end
    local minutes, fine = 0, 0
    local labels, seen = {}, {}
    for i = 1, count do
        local key = trim(ids[i])
        local charge = CHARGES[key]
        if not charge then return nil, 'invalid_charge' end
        if seen[key] then return nil, 'duplicate_charge' end
        seen[key] = true
        minutes = minutes + charge.baseMinutes
        fine = fine + charge.fine
        labels[#labels + 1] = charge.label
    end
    return { minutes = minutes, fine = fine, labels = labels }
end

PoliceCharges.MAX_CHARGES = MAX_CHARGES

return PoliceCharges
