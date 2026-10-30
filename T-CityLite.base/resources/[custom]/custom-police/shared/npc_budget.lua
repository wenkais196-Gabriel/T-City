-- shared/npc_budget.lua — NPC spawn budget constants and pure limit checks.
--
-- FIT-07: every NPC the police layer spawns is charged to one global budget.
-- A backup unit (car + two officers) costs 1 slot; a callout scene (car +
-- suspect) costs 2 slots. The server owns the live entries, TTL sweep and the
-- audit trail (server/npc_budget.lua); this file keeps the cap arithmetic and
-- the cost table in one place so tests, docs and call sites cannot drift.
--
-- The budget is deliberately expressed in *slots*, not requests: the per
-- player limit is 2 slots, which is exactly the old "two backup units" cap,
-- while a callout consumes the whole per-player allowance on its own.

NPCBudget = NPCBudget or {}

NPCBudget.MAX_GLOBAL = 6      -- total slots across every citizen
NPCBudget.MAX_PLAYER = 2      -- slots owned by one citizenid
NPCBudget.TTL_SECONDS = 10 * 60
NPCBudget.SWEEP_INTERVAL_MS = 60 * 1000
NPCBudget.SLOT_COST = {
    backup = 1,
    callout = 2,
    coroner = 1,
    tow = 1,
}

--- Normalize the id used as the slot key (backup request id / callout id).
--- @param id string|number|nil
--- @return string|nil
function NPCBudget.Normalize(id)
    if id == nil then return nil end
    local text = tostring(id)
    if text == '' then return nil end
    return text
end

--- Slot cost for a spawn kind, or nil for an unknown kind.
--- @param kind string
--- @return number|nil
function NPCBudget.Cost(kind)
    if type(kind) ~= 'string' then return nil end
    return NPCBudget.SLOT_COST[kind]
end

--- Current slot usage: total and per-citizen totals.
--- @param entries table map of normalized id -> entry
--- @return number used, table byPlayer
function NPCBudget.Usage(entries)
    local used = 0
    local byPlayer = {}
    for _, entry in pairs(entries or {}) do
        local slots = tonumber(entry.slots) or 0
        used = used + slots
        local cid = entry.citizenid
        if type(cid) == 'string' and cid ~= '' then
            byPlayer[cid] = (byPlayer[cid] or 0) + slots
        end
    end
    return used, byPlayer
end

--- Pure admission check shared by the server and the offline tests.
--- Returns `true, cost` when the spawn may be admitted, otherwise
--- `false, error` (`invalid_kind`, `invalid_id`, `invalid_citizenid`,
--- `duplicate`, `global_limit`, `player_limit`).
--- @param entries table map of normalized id -> entry
--- @param kind string
--- @param id string|number|nil
--- @param citizenid string
--- @return boolean, number|string
function NPCBudget.CanAcquire(entries, kind, id, citizenid)
    local cost = NPCBudget.Cost(kind)
    if not cost then return false, 'invalid_kind' end

    local key = NPCBudget.Normalize(id)
    if not key then return false, 'invalid_id' end
    if type(citizenid) ~= 'string' or citizenid == '' then
        return false, 'invalid_citizenid'
    end

    entries = entries or {}
    if entries[key] then return false, 'duplicate' end

    local used, byPlayer = NPCBudget.Usage(entries)
    if used + cost > NPCBudget.MAX_GLOBAL then return false, 'global_limit' end
    if (byPlayer[citizenid] or 0) + cost > NPCBudget.MAX_PLAYER then
        return false, 'player_limit'
    end

    return true, cost
end
