-- server/director_rules.lua — pure rule table for the director bridge (#31).
--
-- This file has no FiveM, MySQL, QBCore or fs dependency. It is loaded by the
-- resource (fxmanifest.lua) and by tests/agent/test_director_rules.lua under
-- plain Lua 5.4.
--
-- The director only maps an observed event to a *candidate* follow-up quest.
-- It never starts the quest: server/director.lua turns the candidate into an
-- L3 proposal through AgentActions.Propose, and a human approves it.

local DirectorRules = {}

-- Chapter 1 -> chapter 2 follow-ups.
--
-- Only mappings whose target is a natural follow-up for the same audience are
-- listed. Missing entries are deliberate:
--
--   cartel_ch1_first_blood -> cartel_ch2_territory_war
--     ch1 requires role = 'civilian'; ch2 requires role = 'gang_member'
--     (custom-career: any non-'none' gang is gang_member). A player who just
--     finished ch1 is therefore not necessarily eligible for ch2 until they
--     join a gang. Proposing it would produce a proposal that must fail at
--     approval time, so the bridge does not guess and the mapping is omitted.
--
-- police_ch1_first_shift -> police_ch2_corruption_web IS mapped: both require
-- job = 'police'. ch2 additionally has min_police = 1 (on-duty count) which is
-- an environmental condition enforced by custom-quest at approval time, not a
-- story gate. If no officer is on duty, the approved execution fails and the
-- failure is recorded on the agent_actions row.
DirectorRules.FOLLOW_UPS = {
    civilian_ch1_first_dollar = 'civilian_ch2_startup_struggle',
    police_ch1_first_shift = 'police_ch2_corruption_web',
}

-- Extract quest_id from the agent_events.payload column.
--
-- The payload is a JSON object on the wire but oxmysql may hand it back as a
-- decoded table (json column / driver behaviour) depending on the call site.
-- Both shapes must work, and a JSON string must also work without relying on
-- the FiveM `json` global (plain Lua 5.4 tests have no such global).
local function decodeJsonString(payload)
    if type(payload) ~= 'string' or payload == '' then return nil end

    local jsonLib = rawget(_G, 'json')
    if type(jsonLib) == 'table' and type(jsonLib.decode) == 'function' then
        local ok, decoded = pcall(jsonLib.decode, payload)
        if ok and type(decoded) == 'table' then return decoded end
    end

    return nil
end

function DirectorRules.extractCompletedQuest(payload)
    if type(payload) == 'table' then
        local questId = payload.quest_id
        if type(questId) == 'string' and questId ~= '' then return questId end
        return nil
    end

    if type(payload) ~= 'string' or payload == '' then return nil end

    local decoded = decodeJsonString(payload)
    if decoded then
        local questId = decoded.quest_id
        if type(questId) == 'string' and questId ~= '' then return questId end
        return nil
    end

    -- Fallback for plain Lua / malformed-driver cases: accept a quoted
    -- quest_id with arbitrary JSON whitespace. This is intentionally narrow.
    local questId = payload:match('"quest_id"%s*:%s*"([%w_%.:%-]+)"')
    return questId
end

--- Return the target quest id for an observed agent_events row, or nil.
--- Only quest.completed events participate in this slice.
function DirectorRules.followUpQuest(eventType, payload)
    if eventType ~= 'quest.completed' then return nil end

    local questId = DirectorRules.extractCompletedQuest(payload)
    if not questId then return nil end

    return DirectorRules.FOLLOW_UPS[questId]
end

--- Stable per-event idempotency key used by AgentActions.Propose.
--- eventId is agent_events.id; one event can only propose one target quest.
function DirectorRules.idempotencyKey(eventId, eventType, targetQuest)
    if eventId == nil or eventType == nil or targetQuest == nil then return nil end
    if eventType == '' or targetQuest == '' then return nil end
    return ('director:event:%s:%s:%s'):format(
        tostring(eventId), tostring(eventType), tostring(targetQuest))
end

DirectorRules._VERSION = 1

_G.DirectorRules = DirectorRules
return DirectorRules
