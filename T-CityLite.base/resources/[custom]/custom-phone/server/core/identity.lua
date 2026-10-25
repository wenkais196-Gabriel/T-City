-- server/core/identity.lua — authoritative career identity -> phone role map.
--
-- Loaded before server/main.lua and the app registry. No QBCore/MySQL access:
-- the only external dependency is custom-career's export, resolved lazily at
-- call time so the module can load in any resource order.

-- ----------------------------------------------------
-- Career identity -> phone role resolution
-- ----------------------------------------------------
-- custom-career v2 returns job_name/job_label/org_id/rank_tier/certs and no
-- primary_role. This is the single place custom-phone maps that identity onto
-- the roles the NUI/faction/hotline code expects, so no caller can end up
-- indexing a table with nil.
PhoneIdentity = {}

local JOB_ROLE = {
    police = 'police',
    ambulance = 'medic',
    doctor = 'medic',
    ems = 'medic',
    mayor = 'mayor',
    judge = 'justice',
    lawyer = 'justice',
    mechanic = 'mechanic',
    taxi = 'taxi',
    bus = 'bus',
}

--- Normalise an identity table. `job_name` wins; legacy `primary_role` is
--- honoured when the career data has no usable job. A missing identity
--- resolves to the 'none' role instead of nil.
---@param identity table|nil
---@return table
function PhoneIdentity.From(identity)
    identity = type(identity) == 'table' and identity or {}

    local job = type(identity.job_name) == 'string' and identity.job_name:lower() or nil
    if job == '' or job == 'none' then job = nil end

    local role
    if job and job ~= 'unemployed' then
        role = JOB_ROLE[job] or job
    elseif type(identity.primary_role) == 'string' and identity.primary_role ~= '' then
        role = identity.primary_role
    end

    local gang = identity.gang_name
    if (not role or role == 'civilian')
        and type(gang) == 'string' and gang ~= '' and gang ~= 'none' then
        role = 'gang'
    end

    identity.primary_role = role or 'none'
    identity.job_name = identity.job_name or 'unemployed'
    identity.rank_tier = identity.rank_tier or 'entry'
    identity.certs = type(identity.certs) == 'table' and identity.certs or {}
    return identity
end

--- Career tier for a leader. custom-career uses 'leader' for jobs and 'boss'
--- for gangs, so both count.
---@param identity table|nil
---@return boolean
function PhoneIdentity.IsLeader(identity)
    local tier = type(identity) == 'table' and identity.rank_tier or nil
    return tier == 'leader' or tier == 'boss'
end

---@param source number
---@return table
function PhoneIdentity.Resolve(source)
    local ok, identity = pcall(function()
        return exports['custom-career']:GetPlayerIdentity(source)
    end)
    if not ok then identity = nil end
    return PhoneIdentity.From(identity)
end
