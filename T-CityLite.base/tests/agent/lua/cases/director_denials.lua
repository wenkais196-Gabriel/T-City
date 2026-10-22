-- tests/agent/lua/cases/director_denials.lua — policy denials of agent action
-- proposals are audited in agent_denials, never in agent_actions, and a broken
-- denial insert must not change the rejection the agent receives.
--
-- The MySQL stub records every call in env.mysql.log ({kind, sql, params}), so
-- these checks assert the exact column order of the INSERT and that no
-- parameter VALUES reach the new table.

return {
    run = function(ctx)
        local results = {}
        local failed = 0

        local function check(name, fn)
            local record = { name = name, ok = true }
            local ok, err = pcall(fn)
            if not ok then
                record.ok = false
                record.error = tostring(err)
                failed = failed + 1
            end
            results[#results + 1] = record
        end

        local function newEnv(convars, resourceStates)
            return ctx.bootstrap.Load({
                load_main = true,
                convars = convars or {},
                resource_states = resourceStates or {},
            })
        end

        local function callsMatching(env, kind, fragment)
            local matches = {}
            for _, call in ipairs(env.mysql.log) do
                if call.kind == kind and tostring(call.sql):find(fragment, 1, true) then
                    matches[#matches + 1] = call
                end
            end
            return matches
        end

        local function denialInserts(env)
            return callsMatching(env, 'insert', 'INSERT INTO agent_denials')
        end

        -- Column order of the denial INSERT:
        --   1 agent_id  2 action_type  3 code  4 message
        --   5 param_keys  6 params_hash  7 dry_run
        check('propose_policy_denial_is_inserted_without_param_values', function()
            local env = newEnv({
                agent_actions_enabled = '1',
                agent_actions_max_money = '1000',
                agent_actions_daily_budget = '100',
            })
            env.makePlayer(7, 'ABC12345', { cash = 0, bank = 0, crypto = 0 })
            env.mysql.push({ match = 'SUM', result = 0 })

            local response = env.actions.Propose('director.rules', 'add_money', {
                citizenid = 'ABC12345',
                account = 'bank',
                amount = 500,
                reason = 'denial test',
            }, 'denial/money/1', false)

            assert(response.ok == false, 'a policy denial must fail')
            assert(response.code == 'daily_budget_exceeded', tostring(response.code))
            assert(response.status == 'rejected', tostring(response.status))
            assert(response.id == nil, 'a denied proposal must not get an action id')
            assert(response.preview ~= nil, 'denial response must keep its preview')

            local inserts = denialInserts(env)
            assert(#inserts == 1, ('expected 1 denial insert, got %d'):format(#inserts))
            local params = inserts[1].params
            assert(params[1] == 'director.rules', tostring(params[1]))
            assert(params[2] == 'add_money', tostring(params[2]))
            assert(params[3] == 'daily_budget_exceeded', tostring(params[3]))
            assert(tostring(params[4]):find('daily budget', 1, true), tostring(params[4]))
            assert(params[5] == 'account,amount,citizenid,reason', 'param_keys must be sorted names: '
                .. tostring(params[5]))
            assert(tostring(params[6]):match('^%x+$') ~= nil, 'params_hash must be hex: ' .. tostring(params[6]))
            assert(#tostring(params[6]) == 16, 'params_hash must be 16 chars: ' .. tostring(params[6]))
            assert(params[7] == 0, 'dry_run must be 0: ' .. tostring(params[7]))

            -- Privacy: values never leave agent_actions' rejection response.
            for index = 1, #params do
                local value = tostring(params[index])
                assert(not value:find('ABC12345', 1, true), 'citizenid leaked into agent_denials')
                assert(not value:find('denial test', 1, true), 'free-text reason leaked into agent_denials')
            end

            -- The idempotency key must stay reusable: nothing in agent_actions.
            assert(#callsMatching(env, 'insert', 'INSERT INTO agent_actions') == 0,
                'a policy-denied proposal must not be persisted')
        end)

        check('params_hash_is_stable_and_dry_run_is_recorded', function()
            local env = newEnv({ agent_actions_enabled = '1' })

            local dry = env.actions.Propose('director.rules', 'set_weather',
                { weather = 'RAIN' }, 'denial/weather/1', true)
            local wet = env.actions.Propose('director.rules', 'set_weather',
                { weather = 'RAIN' }, 'denial/weather/2', false)
            local dryWeather = env.actions.Propose('director.rules', 'set_weather',
                { weather = 'CLEAR' }, 'denial/weather/3', false)

            assert(dry.code == 'weather_sync_unavailable', tostring(dry.code))
            assert(wet.code == 'weather_sync_unavailable', tostring(wet.code))
            assert(dryWeather.code == 'weather_sync_unavailable', tostring(dryWeather.code))

            local inserts = denialInserts(env)
            assert(#inserts == 3, ('expected 3 denial inserts, got %d'):format(#inserts))
            assert(inserts[1].params[5] == 'weather', tostring(inserts[1].params[5]))
            assert(inserts[1].params[7] == 1, 'a dry-run denial must be marked dry_run=1')
            assert(inserts[2].params[7] == 0, 'a real denial must be dry_run=0')
            assert(inserts[1].params[6] == inserts[2].params[6], 'same params must hash the same')
            assert(inserts[1].params[6] ~= inserts[3].params[6], 'different params must hash differently')
        end)

        check('denial_log_convar_disables_the_insert', function()
            local env = newEnv({ agent_actions_enabled = '1', agent_actions_denial_log = '0' })
            local response = env.actions.Propose('director.rules', 'set_weather',
                { weather = 'RAIN' }, 'denial/off/1', false)

            assert(response.ok == false)
            assert(response.code == 'weather_sync_unavailable', tostring(response.code))
            assert(response.status == 'rejected', tostring(response.status))
            assert(#denialInserts(env) == 0, 'agent_actions_denial_log=0 must not write a row')
        end)

        check('denial_insert_failure_does_not_change_the_rejection', function()
            local env = newEnv({ agent_actions_enabled = '1' })
            env.mysql.push({ match = 'INSERT INTO agent_denials', error = 'denial table unavailable' })

            local captured = {}
            local originalPrint = _G.print
            _G.print = function(...)
                local parts = {}
                for index = 1, select('#', ...) do
                    parts[#parts + 1] = tostring(select(index, ...))
                end
                captured[#captured + 1] = table.concat(parts, ' ')
            end
            local called, response = pcall(function()
                return env.actions.Propose('director.rules', 'set_weather',
                    { weather = 'RAIN' }, 'denial/broken/1', false)
            end)
            _G.print = originalPrint

            assert(called, tostring(response))
            assert(response.ok == false, 'a failed audit insert must not turn into success')
            assert(response.code == 'weather_sync_unavailable', tostring(response.code))
            assert(response.status == 'rejected', tostring(response.status))
            assert(type(response.preview) == 'table' and response.preview.weather == 'RAIN',
                'the denial response must keep its preview')
            assert(#denialInserts(env) == 1, 'the insert must be attempted exactly once (no retries)')
            assert(table.concat(captured, '\n'):find('DB insert failed', 1, true) ~= nil,
                'a failed denial insert must be logged loudly')
        end)

        check('approve_policy_recheck_writes_a_denial', function()
            local env = newEnv({ agent_actions_enabled = '1' }, { ['qb-weathersync'] = 'started' })
            local proposed = env.actions.Propose('director.rules', 'set_weather',
                { weather = 'RAIN' }, 'denial/approve/1', false)
            assert(proposed.ok == true, tostring(proposed.error))
            assert(proposed.status == 'pending_approval', tostring(proposed.status))
            assert(#denialInserts(env) == 0, 'a successful proposal must not write a denial')

            -- The world moved between propose and approve: weathersync stopped.
            env.resource_states['qb-weathersync'] = 'stopped'
            env.mysql.push({
                match = 'FROM agent_actions',
                result = {
                    id = proposed.id,
                    agent_id = 'director.rules',
                    action_type = 'set_weather',
                    params = '{"weather":"RAIN"}',
                    status = 'pending_approval',
                    preview = '{}',
                    expired = 0,
                },
            })

            local response = env.actions.Approve(proposed.id, 'console')
            assert(response.ok == false, 'the recheck must reject the row')
            assert(response.code == 'weather_sync_unavailable', tostring(response.code))
            assert(response.status == 'rejected', tostring(response.status))
            assert(response.id == proposed.id, 'the denial response must keep the action id')

            local inserts = denialInserts(env)
            assert(#inserts == 1, ('expected 1 approval denial, got %d'):format(#inserts))
            assert(inserts[1].params[1] == 'director.rules', tostring(inserts[1].params[1]))
            assert(inserts[1].params[2] == 'set_weather', tostring(inserts[1].params[2]))
            assert(inserts[1].params[3] == 'weather_sync_unavailable', tostring(inserts[1].params[3]))
            assert(inserts[1].params[7] == 0, 'an approval denial is never a dry run')
        end)

        check('normalize_rejection_is_recorded', function()
            local env = newEnv({ agent_actions_enabled = '1', agent_actions_token = 't' })
            local response = env.actions.Propose(
                'agent-1', 'delete_player', { citizenid = 'ABC12345' }, 'deny-normalize-1', false)
            assert(response.ok == false, 'unsupported action must be rejected')
            assert(response.code == 'unsupported_action', tostring(response.code))

            local inserts = denialInserts(env)
            assert(#inserts == 1, ('expected 1 normalize denial, got %d'):format(#inserts))
            assert(inserts[1].params[2] == 'delete_player', tostring(inserts[1].params[2]))
            assert(inserts[1].params[3] == 'unsupported_action', tostring(inserts[1].params[3]))

            local actions = callsMatching(env, 'insert', 'INSERT INTO agent_actions')
            assert(#actions == 0, 'a normalize rejection must not create an action row')
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed, total = #results } }
    end,
}
