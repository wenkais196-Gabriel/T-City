-- server/director.lua — rule-based director bridge (#31).
--
-- Observe -> propose only:
--   * consume the append-only agent_events outbox from a durable cursor,
--   * map quest.completed events to a candidate follow-up quest via the pure
--     server/director_rules.lua table,
--   * create an L3 start_quest proposal through AgentActions.Propose.
--
-- This file never executes or approves an action. L3 proposals stay in
-- pending_approval until a human approves them with the admin token.
-- There is no LLM, no client input and no auto-approval path.
--
-- Cursor semantics:
--   * one row in agent_director_state named 'agent_events',
--   * the batch is processed in ascending id order,
--   * at most agent_director_max_proposals successful proposals per tick; once
--     the cap is reached the loop stops before the next rule-producing event,
--     so the cursor is advanced only to the last fully processed row and the
--     rest of the batch is retried next tick,
--   * the cursor is advanced once per batch, after processing, even when an
--     individual proposal failed transiently. agent_actions.idempotency_key is
--     derived from agent_events.id, so a cursor rollback/manual replay is safe,
--     but this bridge prefers moving forward over getting stuck on one row.
--     Failures are logged as [director] policy rejected / proposal failed.

local AgentActions = _G.AgentActions
local DirectorRules = _G.DirectorRules

if not AgentActions then
    print('[director] ❌ _G.AgentActions is missing; server/main.lua must load first')
    return
end
if not DirectorRules then
    print('[director] ❌ _G.DirectorRules is missing; server/director_rules.lua must load first')
    return
end

local STATE_NAME = 'agent_events'
local Director = {}
_G.Director = Director

-- ---------------------------------------------------------------------------
-- Convar configuration (read per tick so the kill switch is live)
-- ---------------------------------------------------------------------------

local function convarString(name, default)
    local value = GetConvar(name, default)
    if type(value) ~= 'string' then return default end
    return value
end

local function convarInt(name, default, minimum, maximum)
    local raw = convarString(name, tostring(default))
    local value = tonumber(raw)
    if not value or value ~= value then value = default end
    value = math.floor(value)
    if value < minimum then value = minimum end
    if maximum and value > maximum then value = maximum end
    return value
end

local function Config()
    return {
        enabled = convarString('agent_director_enabled', '0') == '1',
        interval = convarInt('agent_director_interval', 15, 3, 86400),
        batch = convarInt('agent_director_batch', 50, 1, 200),
        max_proposals = convarInt('agent_director_max_proposals', 5, 1, 200),
    }
end

local function actionsEnabled()
    return convarString('agent_actions_enabled', '0') == '1'
end

-- ---------------------------------------------------------------------------
-- DB helpers (pcall + short logs; SQL and credentials stay server-side)
-- ---------------------------------------------------------------------------

local function truncate(value, limit)
    local text = tostring(value or '')
    if #text > limit then return text:sub(1, limit) end
    return text
end

local function dbQuery(sql, params)
    local ok, result = pcall(function()
        return MySQL.query.await(sql, params or {})
    end)
    if not ok then
        print(('[director] DB query failed: %s'):format(truncate(result, 200)))
        return nil, tostring(result)
    end
    return result or {}, nil
end

local function dbSingle(sql, params)
    local ok, row = pcall(function()
        return MySQL.single.await(sql, params or {})
    end)
    if not ok then
        print(('[director] DB single failed: %s'):format(truncate(row, 200)))
        return nil, tostring(row)
    end
    return row, nil
end

local function dbInsert(sql, params)
    local ok, insertId = pcall(function()
        return MySQL.insert.await(sql, params or {})
    end)
    if not ok then
        print(('[director] DB insert failed: %s'):format(truncate(insertId, 200)))
        return nil, tostring(insertId)
    end
    if type(insertId) == 'table' then
        insertId = insertId.insertId or insertId.affectedRows or 0
    end
    return tonumber(insertId) or 0, nil
end

local function dbUpdate(sql, params)
    local ok, affected = pcall(function()
        return MySQL.update.await(sql, params or {})
    end)
    if not ok then
        print(('[director] DB update failed: %s'):format(truncate(affected, 200)))
        return 0, tostring(affected)
    end
    if type(affected) == 'table' then
        affected = affected.affectedRows or 0
    end
    return tonumber(affected) or 0, nil
end

-- ---------------------------------------------------------------------------
-- Cursor state
-- ---------------------------------------------------------------------------

local function readState(ensureRow)
    local sql = [[
        SELECT `name`, `cursor`, `updated_at`, `last_event_at`
        FROM `agent_director_state`
        WHERE `name` = ?
        LIMIT 1
    ]]
    local row, err = dbSingle(sql, { STATE_NAME })
    if err then return nil, err end

    if not row and ensureRow then
        local _, insertErr = dbInsert(
            'INSERT IGNORE INTO `agent_director_state` (`name`, `cursor`) VALUES (?, 0)',
            { STATE_NAME })
        if insertErr then return nil, insertErr end
        row, err = dbSingle(sql, { STATE_NAME })
        if err then return nil, err end
    end

    return row, nil
end

local function stateToApi(row)
    if type(row) ~= 'table' then return nil end
    return {
        name = row.name,
        cursor = tonumber(row.cursor) or 0,
        updated_at = row.updated_at,
        last_event_at = row.last_event_at,
    }
end

local function mysqlDateTime(value)
    if type(value) ~= 'string' then return nil end
    -- oxmysql may hand back a JSON/ISO string with surrounding quotes.
    value = value:gsub('^%s*"(.*)"%s*$', '%1')
    local y, m, d, h, mi, sec = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)')
    if y then
        return ('%s-%s-%s %s:%s:%s'):format(y, m, d, h, mi, sec)
    end
    if value:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d') then
        return value
    end
    return nil
end

local function advanceCursor(cursor, lastEventAt)
    -- oxmysql can return an error string (not an exception); check the
    -- result shape. Also normalize agent_events.created_at (ISO-8601 with T/Z)
    -- to a MariaDB DATETIME before writing last_event_at.
    local ok, result = pcall(function()
        return MySQL.query.await([[
            UPDATE `agent_director_state`
            SET `cursor` = ?, `updated_at` = NOW(3)
            WHERE `name` = ? AND `cursor` < ?
        ]], { cursor, STATE_NAME, cursor })
    end)
    if not ok or type(result) == 'string' then
        return 0, tostring(result)
    end

    local eventAt = mysqlDateTime(lastEventAt)
    if eventAt then
        pcall(function()
            MySQL.query.await([[
                UPDATE `agent_director_state`
                SET `last_event_at` = ?
                WHERE `name` = ?
            ]], { eventAt, STATE_NAME })
        end)
    end

    return 1, nil
end

-- ---------------------------------------------------------------------------
-- Public: run one batch
-- ---------------------------------------------------------------------------

function Director.RunOnce()
    local cfg = Config()
    local summary = {
        processed = 0,
        proposed = 0,
        skipped = 0,
        errors = 0,
        cursor = 0,
    }

    if not cfg.enabled then
        summary.error = 'disabled'
        return summary
    end
    if not actionsEnabled() then
        summary.error = 'agent_actions_disabled'
        return summary
    end

    local state, stateErr = readState(true)
    if not state then
        summary.errors = 1
        summary.error = 'state_unavailable: ' .. truncate(stateErr or 'unknown', 160)
        return summary
    end

    local cursor = tonumber(state.cursor) or 0
    summary.cursor = cursor

    local rows, queryErr = dbQuery([[
        SELECT `id`, `event_type`, `citizenid`, `payload`, `created_at`
        FROM `agent_events`
        WHERE `id` > ?
        ORDER BY `id` ASC
        LIMIT ?
    ]], { cursor, cfg.batch })
    if not rows then
        summary.errors = 1
        summary.error = 'query_failed: ' .. truncate(queryErr, 160)
        return summary
    end
    if #rows == 0 then return summary end

    local lastProcessedId = cursor
    local lastEventAt = nil

    for _, event in ipairs(rows) do
        local eventId = tonumber(event.id)
        if not eventId then
            summary.errors = summary.errors + 1
            summary.error = 'invalid_event_id'
            break
        end

        local eventType = event.event_type
        local targetQuest = nil
        if eventType == 'quest.completed' then
            targetQuest = DirectorRules.followUpQuest(eventType, event.payload)
        end

        -- Stop before the next rule-producing event once the per-tick cap is
        -- reached. Unprocessed rows stay above the cursor for the next tick.
        if targetQuest and summary.proposed >= cfg.max_proposals then
            break
        end

        summary.processed = summary.processed + 1
        lastProcessedId = eventId
        if type(event.created_at) == 'string' and event.created_at ~= '' then
            lastEventAt = event.created_at
        end

        local citizenid = event.citizenid
        if not targetQuest then
            summary.skipped = summary.skipped + 1
        elseif type(citizenid) ~= 'string' or citizenid == '' then
            summary.skipped = summary.skipped + 1
            print(('[director] skipped event=%s quest=%s reason=missing_citizenid'):format(
                tostring(eventId), tostring(targetQuest)))
        else
            local key = DirectorRules.idempotencyKey(eventId, eventType, targetQuest)
            local callOk, result = pcall(AgentActions.Propose, 'director:rules', 'start_quest', {
                citizenid = citizenid,
                quest_id = targetQuest,
            }, key, false)

            if not callOk then
                summary.errors = summary.errors + 1
                print(('[director] proposal error event=%s quest=%s error=%s'):format(
                    tostring(eventId), tostring(targetQuest), truncate(result, 200)))
            elseif type(result) ~= 'table' then
                summary.errors = summary.errors + 1
                print(('[director] proposal error event=%s quest=%s reason=empty_result'):format(
                    tostring(eventId), tostring(targetQuest)))
            elseif result.ok then
                summary.proposed = summary.proposed + 1
                print(('[director] proposed event=%s quest=%s action=%s status=%s'):format(
                    tostring(eventId), tostring(targetQuest),
                    tostring(result.id), tostring(result.status)))
            elseif result.code == 'db_error' or result.code == 'quest_catalog_unavailable' then
                summary.errors = summary.errors + 1
                print(('[director] proposal failed event=%s quest=%s code=%s error=%s'):format(
                    tostring(eventId), tostring(targetQuest),
                    tostring(result.code), tostring(result.error)))
            else
                -- Policy rejection: not persisted by the broker, so the event is
                -- consumed but no action row exists. Log it for operators.
                summary.skipped = summary.skipped + 1
                print(('[director] policy rejected event=%s quest=%s code=%s error=%s'):format(
                    tostring(eventId), tostring(targetQuest),
                    tostring(result.code), tostring(result.error)))
            end
        end
    end

    if lastProcessedId > cursor then
        local affected, updateErr = advanceCursor(lastProcessedId, lastEventAt)
        if updateErr then
            summary.errors = summary.errors + 1
            summary.error = 'cursor_update_failed: ' .. truncate(updateErr, 160)
            print(('[director] cursor update failed processed=%s cursor=%s error=%s'):format(
                tostring(summary.processed), tostring(lastProcessedId), tostring(updateErr)))
        else
            summary.cursor = lastProcessedId
            if affected == 0 then
                print(('[director] cursor unchanged (another writer advanced past %s)'):format(
                    tostring(lastProcessedId)))
            end
        end
    end

    return summary
end

-- ---------------------------------------------------------------------------
-- Public: state / test reset
-- ---------------------------------------------------------------------------

function Director.GetState()
    local row, err = readState(false)
    if err then return nil, err end
    if not row then
        return nil, 'state row missing; apply v2.3.1_agent_director.sql'
    end
    return stateToApi(row)
end

--- Test-only: rewind the cursor so agent_events are replayed. Idempotency keys
--- make replay of already-proposed events a no-op for agent_actions.
function Director.Reset()
    local state, stateErr = readState(true)
    if not state then return nil, stateErr or 'state_unavailable' end

    local _, updateErr = dbUpdate([[
        UPDATE `agent_director_state`
        SET `cursor` = 0, `updated_at` = NOW(3), `last_event_at` = NULL
        WHERE `name` = ?
    ]], { STATE_NAME })
    if updateErr then return nil, updateErr end

    print(('[director] ⚠️ cursor reset to 0 for %s (test-only)'):format(STATE_NAME))
    return Director.GetState()
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports('RunOnce', function()
    return Director.RunOnce()
end)

exports('GetState', function()
    return Director.GetState()
end)

exports('Reset', function()
    return Director.Reset()
end)

-- ---------------------------------------------------------------------------
-- Poll loop: only runs when both kill switches are on at resource start.
-- Changing either convar requires a custom-director restart.
-- ---------------------------------------------------------------------------

local polling = false

local function startPolling()
    if polling then return end
    polling = true

    CreateThread(function()
        local cfg = Config()
        print(('[director] poll loop started (interval=%ds batch=%d max_proposals=%d)'):format(
            cfg.interval, cfg.batch, cfg.max_proposals))

        while true do
            local tickConfig = Config()
            if not tickConfig.enabled then
                print('[director] polling stopped: agent_director_enabled is not 1')
                break
            end
            if not actionsEnabled() then
                print('[director] polling stopped: agent_actions_enabled is not 1')
                break
            end

            local ok, summaryOrErr = pcall(Director.RunOnce)
            if not ok then
                print(('[director] tick error: %s'):format(truncate(summaryOrErr, 200)))
            elseif type(summaryOrErr) == 'table' then
                local summary = summaryOrErr
                if (summary.errors or 0) > 0 then
                    print(('[director] tick processed=%s proposed=%s skipped=%s errors=%s cursor=%s error=%s'):format(
                        tostring(summary.processed), tostring(summary.proposed),
                        tostring(summary.skipped), tostring(summary.errors),
                        tostring(summary.cursor), tostring(summary.error)))
                elseif (summary.proposed or 0) > 0 then
                    print(('[director] tick processed=%s proposed=%s skipped=%s cursor=%s'):format(
                        tostring(summary.processed), tostring(summary.proposed),
                        tostring(summary.skipped), tostring(summary.cursor)))
                end
            end

            Wait(tickConfig.interval * 1000)
        end

        polling = false
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    local cfg = Config()
    if cfg.enabled and actionsEnabled() then
        startPolling()
    else
        print(('[director] idle (agent_director_enabled=%s agent_actions_enabled=%s); polling not started'):format(
            tostring(cfg.enabled), tostring(actionsEnabled())))
    end
end)

print(('[director] loaded (enabled=%s). Exports: RunOnce, GetState, Reset'):format(
    tostring(Config().enabled)))
