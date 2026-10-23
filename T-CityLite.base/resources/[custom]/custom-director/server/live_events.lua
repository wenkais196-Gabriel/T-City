-- server/live_events.lua — event tap feeding the in-memory live ring.
--
-- Hooks are qb-core server events; each one is projected to a small,
-- PII-free payload and pushed to LiveStore.  Handlers only do O(1) work: no
-- SQL, no Wait, no PlayerData copy.
--
-- `playerDropped` is the FXServer event, `QBCore:Server:PlayerDropped` is the
-- qb-core event (fired before QBCore.Players[src] is cleared and carrying the
-- Player object).  Both are registered because FXServer does not guarantee
-- cross-resource handler order; a 2s tombstone removes the duplicate.

local LiveEvents = {}
_G.LiveEvents = LiveEvents

LiveEvents.VERSION = 1
LiveEvents.META_WHITELIST = {
    health = true,
    armor = true,
    hunger = true,
    thirst = true,
    stress = true,
    isdead = true,
    inlaststand = true,
    ishandcuffed = true,
}
LiveEvents.ACCOUNTS = { cash = true, bank = true, crypto = true }
LiveEvents.OPERATIONS = { add = true, remove = true, set = true }

local LEAVE_DEDUPE_MS = 2000

-- [source] = summary of the last job/gang we saw for that session.
local lastJob = {}
local lastGang = {}
-- [citizenid] = ms of the last player.leave we emitted.
local leftAt = {}

local function convarString(name, default)
    if type(GetConvar) == 'function' then
        local value = GetConvar(name, default)
        if type(value) == 'string' then return value end
    end
    return default
end

local function store()
    local LiveStore = _G.LiveStore
    if not LiveStore then return nil end
    return LiveStore.Default()
end

local function playerData(player)
    if type(player) ~= 'table' then return nil end
    if type(player.PlayerData) == 'table' then return player.PlayerData end
    return player
end

local function playerDataBySource(source)
    local qb = _G.QBCore
    if type(qb) ~= 'table' or type(qb.Players) ~= 'table' then return nil end
    local key = tonumber(source) or source
    local player = qb.Players[key]
    return playerData(player)
end

local function gradeLevel(grade)
    if type(grade) == 'table' then
        local level = tonumber(grade.level)
        if level then return level end
        return 0
    end
    return tonumber(grade) or 0
end

local function jobSummary(job)
    if type(job) ~= 'table' then
        return { name = 'unemployed', grade = 0, onduty = false }
    end
    local name = type(job.name) == 'string' and LiveRules.sanitize_text(job.name, 32) or 'unemployed'
    return {
        name = name or 'unemployed',
        grade = gradeLevel(job.grade),
        onduty = job.onduty == true,
    }
end

local function gangSummary(gang)
    if type(gang) ~= 'table' then return { name = 'none', grade = 0 } end
    local name = type(gang.name) == 'string' and LiveRules.sanitize_text(gang.name, 32) or 'none'
    return { name = name or 'none', grade = gradeLevel(gang.grade) }
end

local function sameJob(a, b)
    if not a or not b then return false end
    return a.name == b.name and a.grade == b.grade and a.onduty == b.onduty
end

local function sameGang(a, b)
    if not a or not b then return false end
    return a.name == b.name and a.grade == b.grade
end

local function emit(eventType, citizenid, payload)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local buffer = store()
    if not buffer then return nil end
    return buffer:Push({
        type = eventType,
        citizenid = citizenid,
        at = LiveRules.now_ms(),
        payload = payload or {},
    })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function onLoaded(player)
    local data = playerData(player)
    if not data or type(data.citizenid) ~= 'string' then return end
    local source = tonumber(data.source) or 0

    local job = jobSummary(data.job)
    local gang = gangSummary(data.gang)
    lastJob[source] = job
    lastGang[source] = gang

    emit('player.join', data.citizenid, {
        source = source,
        job = job,
        gang = gang,
    })
end

local function leave(player, reason)
    local data = playerData(player)
    if not data or type(data.citizenid) ~= 'string' then return end
    local source = tonumber(data.source) or 0

    local now = LiveRules.now_ms()
    local duplicate = leftAt[data.citizenid] and now - leftAt[data.citizenid] < LEAVE_DEDUPE_MS
    if not duplicate then
        leftAt[data.citizenid] = now
        emit('player.leave', data.citizenid, {
            source = source,
            reason = LiveRules.sanitize_text(reason, 64) or 'unknown',
        })
    end

    -- Clear session state even for the duplicate event.
    lastJob[source] = nil
    lastGang[source] = nil
end

-- ---------------------------------------------------------------------------
-- Cold-field events
-- ---------------------------------------------------------------------------

local function onJobUpdate(source, job)
    local data = playerDataBySource(source)
    if not data or type(data.citizenid) ~= 'string' then return end

    local nextJob = jobSummary(job)
    local previous = lastJob[source]
    if sameJob(previous, nextJob) then return end
    lastJob[source] = nextJob

    emit('player.job.change', data.citizenid, {
        job = nextJob,
        prev = previous,
    })
end

local function onGangUpdate(source, gang)
    local data = playerDataBySource(source)
    if not data or type(data.citizenid) ~= 'string' then return end

    local nextGang = gangSummary(gang)
    local previous = lastGang[source]
    if sameGang(previous, nextGang) then return end
    lastGang[source] = nextGang

    emit('player.gang.change', data.citizenid, {
        gang = nextGang,
        prev = previous,
    })
end

local function onMoneyChange(source, account, amount, operation, reason)
    local data = playerDataBySource(source)
    if not data or type(data.citizenid) ~= 'string' then return end

    account = type(account) == 'string' and account:lower() or nil
    if not account or not LiveEvents.ACCOUNTS[account] then return end

    operation = type(operation) == 'string' and operation:lower() or 'add'
    if not LiveEvents.OPERATIONS[operation] then operation = 'add' end

    local delta = tonumber(amount)
    if operation == 'set' then delta = nil end

    local money = type(data.money) == 'table' and data.money or nil
    -- The reason string is free text produced by other resources: custom-phone
    -- writes "Transfer to <number>", which would leak a phone number that the
    -- read layer is forbidden to expose. Drop it rather than try to scrub it.
    emit('money.change', data.citizenid, {
        account = account,
        delta = delta,
        operation = operation,
        after = money and tonumber(money[account]) or nil,
    })
end

local function onMetaUpdate(source, key, value)
    if type(key) ~= 'string' or not LiveEvents.META_WHITELIST[key] then return end
    local data = playerDataBySource(source)
    if not data or type(data.citizenid) ~= 'string' then return end

    local projected
    local valueType = type(value)
    if valueType == 'number' or valueType == 'boolean' then
        projected = value
    elseif valueType == 'string' then
        projected = LiveRules.sanitize_text(value, 32)
    end
    if projected == nil then return end

    emit('player.meta', data.citizenid, { key = key, value = projected })
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

if type(AddEventHandler) == 'function' then
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        local ok, err = pcall(onLoaded, player)
        if not ok then print(('[custom-director] live player.join error: %s'):format(tostring(err))) end
    end)

    AddEventHandler('QBCore:Server:PlayerDropped', function(player)
        local ok, err = pcall(leave, player, 'unknown')
        if not ok then print(('[custom-director] live player.leave error: %s'):format(tostring(err))) end
    end)

    -- qb-core's own playerDropped handler runs first (the dependency starts
    -- first) and clears QBCore.Players, so this handler usually only sees the
    -- reason and no Player.  It is kept for the reverse ordering and for
    -- deployments that fire playerDropped without the qb-core wrapper.
    AddEventHandler('playerDropped', function(reason)
        local src = tonumber(source)
        if not src then return end

        local qb = _G.QBCore
        local player = type(qb) == 'table' and type(qb.Players) == 'table' and qb.Players[src] or nil
        if not player then return end

        local reasonText = LiveRules.sanitize_text(reason, 64) or 'unknown'
        local ok, err = pcall(leave, player, reasonText)
        if not ok then print(('[custom-director] live player.leave error: %s'):format(tostring(err))) end
    end)

    AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job)
        local ok, err = pcall(onJobUpdate, source, job)
        if not ok then print(('[custom-director] live job.change error: %s'):format(tostring(err))) end
    end)

    AddEventHandler('QBCore:Server:OnGangUpdate', function(source, gang)
        local ok, err = pcall(onGangUpdate, source, gang)
        if not ok then print(('[custom-director] live gang.change error: %s'):format(tostring(err))) end
    end)

    AddEventHandler('QBCore:Server:OnMoneyChange', function(source, account, amount, operation, reason)
        local ok, err = pcall(onMoneyChange, source, account, amount, operation, reason)
        if not ok then print(('[custom-director] live money.change error: %s'):format(tostring(err))) end
    end)

    -- qb-core in this checkout does not emit QBCore:Server:OnMetaUpdate yet
    -- (design 01 §11-D3); it is opt-in via agent_live_meta_source=event so the
    -- default build does not subscribe to an event nothing fires.
    if convarString('agent_live_meta_source', 'throttled') == 'event' then
        AddEventHandler('QBCore:Server:OnMetaUpdate', function(source, key, value)
            local ok, err = pcall(onMetaUpdate, source, key, value)
            if not ok then print(('[custom-director] live player.meta error: %s'):format(tostring(err))) end
        end)
    end
end

-- Exported for tests / future director use.
function LiveEvents.Stats()
    local buffer = store()
    if not buffer then return nil end
    return buffer:Stats()
end

function LiveEvents.Reset()
    lastJob = {}
    lastGang = {}
    leftAt = {}
end

return LiveEvents
