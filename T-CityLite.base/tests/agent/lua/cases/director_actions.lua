-- tests/agent/lua/cases/director_actions.lua — executor contract for
-- custom-director's set_job (L3), grant_item (L4), teleport (L3, delegated to
-- custom-agent-client) and spawn_vehicle (L3, server-side) actions.
--
-- The executors live in server/main.lua; main exposes them on the internal
-- AgentActions._Execute table so this harness can drive them against the stub
-- QBCore player object. Approval still flows exclusively through
-- Propose/Approve, which this file does not exercise (policy.lua owns that).

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

        local function newEnv(convars)
            return ctx.bootstrap.Load({
                load_main = true,
                convars = convars or {},
            })
        end

        local function newPlayer(env, citizenid)
            local player = env.makePlayer(7, citizenid, { cash = 0, bank = 0, crypto = 0 })
            env.qb.Shared.Jobs = {
                police = {
                    label = 'Police',
                    defaultDuty = true,
                    grades = {
                        ['0'] = { name = 'Cadet', payment = 30 },
                        ['2'] = { name = 'Officer', payment = 50 },
                    },
                },
            }
            env.qb.Shared.Items = {
                bread = { name = 'bread', label = 'Bread', weight = 100, unique = false },
            }
            return player
        end

        local function setJob(env, citizenid, job, grade)
            return env.actions._Execute.set_job(1, {
                citizenid = citizenid,
                job = job,
                grade = grade,
            })
        end

        local function grantItem(env, citizenid, item, amount)
            return env.actions._Execute.grant_item(1, {
                citizenid = citizenid,
                item = item,
                amount = amount,
                reason = 'test reward',
            })
        end

        local function startedWeatherSync(env, state)
            env.resource_states['qb-weathersync'] = 'started'
            env.weather_state = state or 'EXTRASUNNY'
            env.export_overrides['qb-weathersync'] = {
                setWeather = function(weather)
                    env.weather_state = weather
                    return true
                end,
                getWeatherState = function()
                    return env.weather_state
                end,
            }
        end

        check('executors_exposed', function()
            local env = newEnv()
            assert(type(env.actions._Execute) == 'table', '_Execute table missing')
            assert(type(env.actions._Execute.set_job) == 'function', 'set_job executor missing')
            assert(type(env.actions._Execute.grant_item) == 'function', 'grant_item executor missing')
            assert(type(env.actions._Execute.announce) == 'function', 'announce executor missing')
            assert(type(env.actions._Execute.set_weather) == 'function', 'set_weather executor missing')
            assert(type(env.actions._Execute.set_time_of_day) == 'function', 'set_time_of_day executor missing')
            assert(type(env.actions._Execute.teleport) == 'function', 'teleport executor missing')
            assert(type(env.actions._Execute.spawn_vehicle) == 'function', 'spawn_vehicle executor missing')
            assert(type(env.actions._Context) == 'function', 'context builder missing')
        end)

        check('set_job_success_records_before_after', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            local ok, err, result = setJob(env, 'ABC12345', 'police', 2)
            assert(ok == true, tostring(err))
            assert(result.before.job == 'unemployed' and result.before.grade == 0,
                'before must capture the previous job')
            assert(result.after.job == 'police' and result.after.grade == 2,
                'after must capture the applied job')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.job.name == 'police', 'PlayerData.job was not updated')
            assert(player.PlayerData.job.grade.level == 2, 'grade level was not updated')
        end)

        check('set_job_returns_false_when_setjob_fails', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            local ok, err = setJob(env, 'ABC12345', 'ghostjob', 0)
            assert(ok == false, 'unknown job must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('set_job_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.SetJob = function() return true end -- lies: no mutation
            local ok, err = setJob(env, 'ABC12345', 'police', 2)
            assert(ok == false, 'unchanged job must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_job_offline_player', function()
            local env = newEnv()
            local ok, err = setJob(env, 'OFFLINE01', 'police', 0)
            assert(ok == false, 'offline target must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        check('grant_item_success_records_before_after', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            local ok, err, result = grantItem(env, 'ABC12345', 'bread', 3)
            assert(ok == true, tostring(err))
            assert(result.item == 'bread' and result.amount == 3, 'result item/amount mismatch')
            assert(result.before == 0 and result.after == 3, 'before/after mismatch')
            assert(result.reason == 'test reward', 'reason missing from result')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.items['bread'] == 3, 'inventory was not mutated')

            local secondOk, secondErr, second = grantItem(env, 'ABC12345', 'bread', 2)
            assert(secondOk == true, tostring(secondErr))
            assert(second.before == 3 and second.after == 5, 'second grant before/after mismatch')
        end)

        check('grant_item_returns_false_when_additem_fails', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.AddItem = function() return false end
            local ok, err = grantItem(env, 'ABC12345', 'bread', 1)
            assert(ok == false, 'AddItem false must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('grant_item_delta_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.AddItem = function(item, amount)
                player.PlayerData.items[item] = (player.PlayerData.items[item] or 0) + amount - 1
                return true
            end
            local ok, err = grantItem(env, 'ABC12345', 'bread', 2)
            assert(ok == false, 'partial add must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('grant_item_offline_player', function()
            local env = newEnv()
            local ok, err = grantItem(env, 'OFFLINE01', 'bread', 1)
            assert(ok == false, 'offline target must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        check('grant_item_cap_comes_from_convar', function()
            local env = newEnv({ agent_actions_max_item_amount = '7' })
            assert(env.actions.Policy().limits.max_item_amount == 7, 'convar cap not read')
            assert(env.actions.Policy().actions.grant_item.max_amount == 7, 'action cap not exposed')

            local clamped = newEnv({ agent_actions_max_item_amount = '9999' })
            assert(clamped.actions.Policy().limits.max_item_amount == 1000, 'convar clamp failed')

            local fallback = newEnv()
            assert(fallback.actions.Policy().limits.max_item_amount == 50, 'default cap failed')
        end)

        check('announce_broadcasts_to_two_online_players', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345') -- source 7
            env.makePlayer(8, 'DEF67890', { cash = 0, bank = 0, crypto = 0 })
            local ok, err, result = env.actions._Execute.announce(1, {
                message = 'Server restart in 5 minutes',
                kind = 'warning',
            })
            assert(ok == true, tostring(err))
            assert(result.delivered == 2,
                'expected 2 deliveries, got ' .. tostring(result.delivered))
            assert(result.kind == 'warning', 'kind missing from result')
            assert(#env.notifications == 2,
                'expected 2 notify calls, got ' .. tostring(#env.notifications))
            for _, notification in ipairs(env.notifications) do
                assert(notification.text == 'Server restart in 5 minutes', 'wrong notify text')
                assert(notification.kind == 'warning', 'wrong notify kind')
                assert(notification.duration == 5000, 'wrong notify duration')
            end
        end)

        check('announce_with_no_players_is_not_failure', function()
            local env = newEnv()
            local ok, err, result = env.actions._Execute.announce(1, {
                message = 'Nobody is online',
                kind = 'info',
            })
            assert(ok == true, tostring(err))
            assert(result.delivered == 0, 'expected zero deliveries')
            assert(#env.notifications == 0, 'no player should be notified')
        end)

        check('set_weather_rejected_when_weathersync_stopped', function()
            local env = newEnv()
            local params = { weather = 'RAIN' }
            local context = env.actions._Context('set_weather', params)
            assert(context.weather_sync == false, 'context.weather_sync should be false')
            local ok, err = env.policy.CheckPolicy('set_weather', params, {}, context)
            assert(ok == false, 'policy must reject without qb-weathersync')
            assert(err.code == 'weather_sync_unavailable', tostring(err.code))
        end)

        check('set_weather_success_records_before_and_verifies', function()
            local env = newEnv()
            startedWeatherSync(env, 'CLEAR')
            local context = env.actions._Context('set_weather', { weather = 'RAIN' })
            assert(context.weather_sync == true, 'context.weather_sync should be true')
            assert(context.weather == 'CLEAR', 'context.weather should be the live state')

            local ok, err, result = env.actions._Execute.set_weather(1, { weather = 'RAIN' })
            assert(ok == true, tostring(err))
            assert(result.weather == 'RAIN', 'result.weather mismatch')
            assert(result.before == 'CLEAR', 'result.before mismatch')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(env.weather_state == 'RAIN', 'weathersync state was not updated')
        end)

        check('set_weather_returns_false_is_execution_failed', function()
            local env = newEnv()
            env.resource_states['qb-weathersync'] = 'started'
            env.export_overrides['qb-weathersync'] = {
                setWeather = function() return false end,
                getWeatherState = function() return 'CLEAR' end,
            }
            local ok, err = env.actions._Execute.set_weather(1, { weather = 'RAIN' })
            assert(ok == false, 'false setWeather must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('set_weather_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            env.resource_states['qb-weathersync'] = 'started'
            env.export_overrides['qb-weathersync'] = {
                setWeather = function() return true end, -- lies: no state change
                getWeatherState = function() return 'CLEAR' end,
            }
            local ok, err = env.actions._Execute.set_weather(1, { weather = 'RAIN' })
            assert(ok == false, 'unchanged weather must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_time_success_records_hour_minute', function()
            local env = newEnv()
            local calls = {}
            env.resource_states['qb-weathersync'] = 'started'
            env.export_overrides['qb-weathersync'] = {
                setTime = function(hour, minute)
                    calls[#calls + 1] = { hour, minute }
                    return true
                end,
                getTime = function() return 22, 30 end,
            }
            local ok, err, result = env.actions._Execute.set_time_of_day(1, {
                hour = 22,
                minute = 30,
            })
            assert(ok == true, tostring(err))
            assert(result.hour == 22 and result.minute == 30, 'result time mismatch')
            assert(#calls == 1 and calls[1][1] == 22 and calls[1][2] == 30,
                'setTime was not called with hour/minute')
            assert(result.verify_result == true, 'getTime read-back should verify')
        end)

        check('set_time_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            env.resource_states['qb-weathersync'] = 'started'
            env.export_overrides['qb-weathersync'] = {
                setTime = function() return true end,
                getTime = function() return 23, 0 end,
            }
            local ok, err = env.actions._Execute.set_time_of_day(1, {
                hour = 22,
                minute = 30,
            })
            assert(ok == false, 'a clock that did not move must not be reported as success')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_time_returns_false_is_execution_failed', function()
            local env = newEnv()
            env.resource_states['qb-weathersync'] = 'started'
            env.export_overrides['qb-weathersync'] = {
                setTime = function() return false end,
            }
            local ok, err = env.actions._Execute.set_time_of_day(1, {
                hour = 22,
                minute = 30,
            })
            assert(ok == false, 'false setTime must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('announce_cap_comes_from_convar', function()
            local env = newEnv({ agent_actions_max_announce_chars = '7' })
            assert(env.actions.Policy().limits.max_announce_chars == 7, 'convar cap not read')
            assert(env.actions.Policy().actions.announce.blast_radius == 'world',
                'announce blast radius not exposed')

            local clamped = newEnv({ agent_actions_max_announce_chars = '9999' })
            assert(clamped.actions.Policy().limits.max_announce_chars == 2000, 'convar clamp failed')

            local fallback = newEnv()
            assert(fallback.actions.Policy().limits.max_announce_chars == 300, 'default cap failed')
        end)

        check('teleport_policy_requires_executor', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')

            local definition = env.policy.ACTIONS.teleport
            assert(type(definition) == 'table', 'teleport missing from ACTIONS')
            assert(definition.risk == 'L3', 'teleport risk must be L3')
            assert(definition.requires_approval == true, 'teleport must require approval')
            assert(definition.auto_execute == false, 'teleport must never auto-execute')
            assert(definition.blast_radius == 'single', 'teleport blast radius must be single')

            local params = { citizenid = 'ABC12345', x = 100.0, y = 200.0, z = 30.0 }
            local context = env.actions._Context('teleport', params)
            assert(context.executor_ready == false, 'executor_ready should be false')
            local ok, err = env.policy.CheckPolicy('teleport', params, {}, context)
            assert(ok == false, 'policy must reject without custom-agent-client')
            assert(err.code == 'executor_unavailable', tostring(err.code))
        end)

        check('teleport_context_position_and_preview', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.resource_states['custom-agent-client'] = 'started'
            env.peds[7] = 99
            env.entity_coords[99] = { x = 10.5, y = -20.25, z = 30.0 }

            local params = {
                citizenid = 'ABC12345',
                x = 300.0,
                y = 400.0,
                z = 20.0,
                heading = 90.0,
            }
            local context = env.actions._Context('teleport', params)
            assert(context.executor_ready == true, 'executor_ready should be true')
            assert(context.position and context.position.x == 10.5,
                'context.position must be the player position')
            assert(context.position.y == -20.25 and context.position.z == 30.0,
                'context.position y/z mismatch')

            local preview = env.policy.Preview('teleport', params, context, {})
            assert(preview.citizenid == 'ABC12345', 'preview citizenid missing')
            assert(preview.target.x == 300.0 and preview.target.y == 400.0
                and preview.target.z == 20.0, 'preview.target mismatch')
            assert(preview.target.heading == 90.0, 'preview.target.heading missing')
            assert(preview.from.x == 10.5 and preview.from.z == 30.0, 'preview.from mismatch')

            local ok, err = env.policy.CheckPolicy('teleport', params, {}, context)
            assert(ok == true, tostring(err and err.code))
        end)

        check('teleport_success_keeps_ack_and_from', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.resource_states['custom-agent-client'] = 'started'
            env.peds[7] = 99
            env.entity_coords[99] = { x = 1.0, y = 2.0, z = 3.0 }

            local seen = nil
            env.export_overrides['custom-agent-client'] = {
                Execute = function(source, action, payload, timeoutMs, opts)
                    seen = {
                        source = source,
                        action = action,
                        payload = payload,
                        timeoutMs = timeoutMs,
                        opts = opts,
                    }
                    return true, { request_id = 'req-1', status = 'ok' }
                end,
            }

            local ok, err, result = env.actions._Execute.teleport(42, {
                citizenid = 'ABC12345',
                x = 300.0,
                y = 400.0,
                z = 20.0,
                heading = 90.0,
            })
            assert(ok == true, tostring(err))
            assert(result.ack.request_id == 'req-1' and result.ack.status == 'ok',
                'ack must be preserved in result.ack')
            assert(result.from.x == 1.0 and result.from.y == 2.0 and result.from.z == 3.0,
                'from must be the pre-execution position')
            assert(type(result.at) == 'number', 'at timestamp missing')

            assert(seen.source == 7, 'wrong source')
            assert(seen.action == 'teleport', 'wrong action')
            assert(seen.payload.x == 300.0 and seen.payload.y == 400.0
                and seen.payload.z == 20.0 and seen.payload.heading == 90.0,
                'payload mismatch')
            assert(seen.timeoutMs == 5000, 'timeout must be 5000ms')
            assert(seen.opts.agent_id == 'director:42', 'agent_id mismatch')
        end)

        check('teleport_timeout_is_execution_failed', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.export_overrides['custom-agent-client'] = {
                Execute = function()
                    return false, nil, { code = 'timeout', message = 'no ack within 5000ms' }
                end,
            }
            local ok, err = env.actions._Execute.teleport(1, {
                citizenid = 'ABC12345',
                x = 1.0,
                y = 2.0,
                z = 3.0,
            })
            assert(ok == false, 'timeout must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
            assert(tostring(err):match('timeout'), tostring(err))
        end)

        check('teleport_executor_disabled_is_reported', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.export_overrides['custom-agent-client'] = {
                Execute = function()
                    return false, nil, { code = 'executor_disabled', message = 'channel disabled' }
                end,
            }
            local ok, err = env.actions._Execute.teleport(1, {
                citizenid = 'ABC12345',
                x = 1.0,
                y = 2.0,
                z = 3.0,
            })
            assert(ok == false, 'disabled executor must fail')
            assert(err == 'executor_disabled', tostring(err))
        end)

        check('teleport_not_yieldable_mentions_coroutine', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.export_overrides['custom-agent-client'] = {
                Execute = function()
                    return false, nil, { code = 'not_yieldable', message = 'needs a coroutine' }
                end,
            }
            local ok, err = env.actions._Execute.teleport(1, {
                citizenid = 'ABC12345',
                x = 1.0,
                y = 2.0,
                z = 3.0,
            })
            assert(ok == false, 'not_yieldable must fail')
            assert(tostring(err):match('^not_yieldable'), tostring(err))
            assert(tostring(err):match('coroutine'), tostring(err))
        end)

        check('teleport_throwing_export_is_executor_unavailable', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.export_overrides['custom-agent-client'] = {
                Execute = function()
                    error('custom-agent-client export failed')
                end,
            }
            local ok, err = env.actions._Execute.teleport(1, {
                citizenid = 'ABC12345',
                x = 1.0,
                y = 2.0,
                z = 3.0,
            })
            assert(ok == false, 'throwing export must fail')
            assert(err == 'executor_unavailable', tostring(err))
        end)

        check('teleport_normalize_rejects_bad_coordinates', function()
            local env = newEnv()
            local bad = {
                { x = 9000.0, y = 0.0, z = 0.0, label = 'x out of bounds' },
                { x = 0.0, y = -5000.0, z = 0.0, label = 'y out of bounds' },
                { x = 0.0, y = 0.0, z = -500.0, label = 'z out of bounds' },
                { x = 0 / 0, y = 0.0, z = 0.0, label = 'x NaN' },
                { x = 0.0, y = math.huge, z = 0.0, label = 'y +inf' },
                { x = 0.0, y = 0.0, z = -math.huge, label = 'z -inf' },
            }
            for _, case in ipairs(bad) do
                local normalized, err = env.policy.Normalize('teleport', {
                    citizenid = 'ABC12345',
                    x = case.x,
                    y = case.y,
                    z = case.z,
                })
                assert(normalized == nil, case.label .. ' must be rejected')
                assert(err and err.code == 'invalid_params',
                    case.label .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local missing, missingErr = env.policy.Normalize('teleport', { citizenid = 'ABC12345' })
            assert(missing == nil, 'missing coordinates must be rejected')
            assert(missingErr.code == 'invalid_params', tostring(missingErr.code))

            local edge = env.policy.Normalize('teleport', {
                citizenid = 'ABC12345',
                x = -4500,
                y = 8500,
                z = 3000,
                heading = 360,
            })
            assert(edge and edge.x == -4500 and edge.y == 8500 and edge.z == 3000,
                'map bounds must be inclusive')
            assert(edge.heading == 360, 'heading 360 must be accepted')
        end)

        check('teleport_normalize_rejects_bad_heading', function()
            local env = newEnv()
            local bad = { -1, 361, 0 / 0, math.huge, '90' }
            for _, heading in ipairs(bad) do
                local normalized, err = env.policy.Normalize('teleport', {
                    citizenid = 'ABC12345',
                    x = 1.0,
                    y = 2.0,
                    z = 3.0,
                    heading = heading,
                })
                assert(normalized == nil, 'heading ' .. tostring(heading) .. ' must be rejected')
                assert(err and err.code == 'invalid_params', tostring(err and err.code))
            end
        end)

        check('teleport_normalize_rejects_unknown_field', function()
            local env = newEnv()
            local normalized, err = env.policy.Normalize('teleport', {
                citizenid = 'ABC12345',
                x = 1.0,
                y = 2.0,
                z = 3.0,
                weapon = 'WEAPON_CARBINERIFLE',
            })
            assert(normalized == nil, 'unknown field must be rejected')
            assert(err and err.code == 'invalid_params', tostring(err and err.code))
            assert(tostring(err.message):match('unknown field weapon'), tostring(err.message))
        end)

        check('spawn_vehicle_registry_and_preview', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.peds[7] = 99
            env.entity_coords[99] = { x = 10.0, y = 20.0, z = 30.0 }

            local definition = env.policy.ACTIONS.spawn_vehicle
            assert(type(definition) == 'table', 'spawn_vehicle missing from ACTIONS')
            assert(definition.risk == 'L3', 'spawn_vehicle risk must be L3')
            assert(definition.requires_approval == true, 'spawn_vehicle must require approval')
            assert(definition.auto_execute == false, 'spawn_vehicle must never auto-execute')
            assert(definition.blast_radius == 'single', 'spawn_vehicle blast radius must be single')

            local params = assert(env.policy.Normalize('spawn_vehicle', {
                citizenid = 'ABC12345',
                model = 'Sultan',
                plate = 'abc123',
            }))
            assert(params.model == 'sultan', 'model must be lowercased')
            assert(params.plate == 'ABC123', 'plate must be uppercased')

            local context = env.actions._Context('spawn_vehicle', params)
            assert(context.position and context.position.x == 10.0,
                'context.position must be the player position')
            assert(type(context.model_hash) == 'number' and context.model_hash ~= 0,
                'context.model_hash must be injected by main')

            local preview = env.policy.Preview('spawn_vehicle', params, context, {})
            assert(preview.citizenid == 'ABC12345', 'preview citizenid missing')
            assert(preview.model == 'sultan' and preview.plate == 'ABC123',
                'preview model/plate mismatch')
            assert(preview.from.x == 10.0 and preview.from.y == 20.0
                and preview.from.z == 30.0, 'preview.from mismatch')

            local ok, err = env.policy.CheckPolicy('spawn_vehicle', params, {}, context)
            assert(ok == true, tostring(err and err.code))
        end)

        check('spawn_vehicle_normalize_rejects_bad_model', function()
            local env = newEnv()
            local badModels = {
                { value = '', label = 'empty' },
                { value = 'bad model', label = 'space' },
                { value = 'sultan!', label = 'bang' },
                { value = string.rep('a', 65), label = 'too long' },
                { value = 123, label = 'non-string' },
            }
            for _, case in ipairs(badModels) do
                local normalized, err = env.policy.Normalize('spawn_vehicle', {
                    citizenid = 'ABC12345',
                    model = case.value,
                })
                assert(normalized == nil, case.label .. ' model must be rejected')
                assert(err and err.code == 'invalid_params',
                    case.label .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local edge = env.policy.Normalize('spawn_vehicle', {
                citizenid = 'ABC12345',
                model = string.rep('a', 64),
            })
            assert(edge ~= nil and #edge.model == 64, '64-char model must be accepted')
        end)

        check('spawn_vehicle_normalize_rejects_bad_plate', function()
            local env = newEnv()
            local badPlates = {
                { value = '', label = 'empty' },
                { value = 'ABCDEFGHI', label = 'too long' },
                { value = 'AB-CD', label = 'dash' },
                { value = 'ABC 123', label = 'inner space' },
                { value = 42, label = 'non-string' },
            }
            for _, case in ipairs(badPlates) do
                local normalized, err = env.policy.Normalize('spawn_vehicle', {
                    citizenid = 'ABC12345',
                    model = 'sultan',
                    plate = case.value,
                })
                assert(normalized == nil, case.label .. ' plate must be rejected')
                assert(err and err.code == 'invalid_params',
                    case.label .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local noPlate = env.policy.Normalize('spawn_vehicle', {
                citizenid = 'ABC12345',
                model = 'sultan',
            })
            assert(noPlate ~= nil and noPlate.plate == nil, 'plate must stay optional')
        end)

        check('spawn_vehicle_normalize_rejects_unknown_field', function()
            local env = newEnv()
            local normalized, err = env.policy.Normalize('spawn_vehicle', {
                citizenid = 'ABC12345',
                model = 'sultan',
                color = 'red',
            })
            assert(normalized == nil, 'unknown field must be rejected')
            assert(err and err.code == 'invalid_params', tostring(err and err.code))
            assert(tostring(err.message):match('unknown field color'), tostring(err.message))
        end)

        check('spawn_vehicle_policy_rejects_zero_model_hash', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.hashes.ghostcar = 0

            local params = { citizenid = 'ABC12345', model = 'ghostcar' }
            local context = env.actions._Context('spawn_vehicle', params)
            assert(context.model_hash == 0, 'model_hash should be 0')

            local ok, err = env.policy.CheckPolicy('spawn_vehicle', params, {}, context)
            assert(ok == false, 'zero model hash must be rejected')
            assert(err.code == 'model_not_found', tostring(err.code))
        end)

        check('spawn_vehicle_ped_zero_is_player_offline', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345') -- no env.peds entry: GetPlayerPed returns 0
            local ok, err = env.actions._Execute.spawn_vehicle(1, {
                citizenid = 'ABC12345',
                model = 'sultan',
            })
            assert(ok == false, 'missing ped must fail')
            assert(err == 'player_offline', tostring(err))
            assert(#env.vehicles == 0, 'no vehicle should be created')
            assert(#env.deleted_entities == 0, 'nothing to delete')
        end)

        check('spawn_vehicle_success_returns_entity', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.peds[7] = 99
            env.entity_coords[99] = { x = 100.0, y = 200.0, z = 30.0 }
            env.entity_headings[99] = 90.0
            env.entity_forward[99] = { x = 0.0, y = 1.0, z = 0.0 }

            local params = assert(env.policy.Normalize('spawn_vehicle', {
                citizenid = 'ABC12345',
                model = 'Sultan',
                plate = 'abc123',
            }))
            local ok, err, result = env.actions._Execute.spawn_vehicle(1, params)
            assert(ok == true, tostring(err))
            assert(type(result.entity) == 'number', 'result.entity missing')
            assert(result.model == 'sultan' and result.plate == 'ABC123',
                'result model/plate mismatch')
            assert(result.coords.x == 100.0 and result.coords.y == 201.5
                and result.coords.z == 30.0, 'result.coords must be 1.5m in front')

            local vehicle = env.vehicles[1]
            assert(vehicle and vehicle.native == 'server_setter',
                'CreateVehicleServerSetter was not used')
            assert(vehicle.model == 'sultan' and vehicle.vehtype == 'automobile',
                'vehicle model/type mismatch')
            assert(vehicle.heading == 90.0, 'vehicle heading mismatch')
            assert(vehicle.x == 100.0 and vehicle.y == 201.5,
                'vehicle spawn position mismatch')
            assert(env.vehicle_plates[result.entity] == 'ABC123',
                'plate was not applied')
            assert(#env.deleted_entities == 0, 'a live vehicle must not be deleted')
        end)

        check('spawn_vehicle_timeout_is_bounded_and_deletes_entity', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.peds[7] = 99
            env.entity_coords[99] = { x = 1.0, y = 2.0, z = 3.0 }
            env.entity_exists_override = false

            -- Controlled clock: Wait advances env.now by 500 ms, so the 2000 ms
            -- deadline is reached in four iterations instead of really sleeping.
            local waits = 0
            _G.Wait = function()
                waits = waits + 1
                env.now = env.now + 500
            end
            _G.GetGameTimer = function() return env.now end

            local ok, err = env.actions._Execute.spawn_vehicle(1, {
                citizenid = 'ABC12345',
                model = 'sultan',
            })
            assert(ok == false, 'timeout must fail')
            assert(err == 'vehicle_spawn_timeout', tostring(err))
            assert(waits >= 1 and waits <= 10,
                'wait loop must be bounded, took ' .. tostring(waits) .. ' waits')
            assert(#env.deleted_entities == 1, 'timed-out entity must be deleted')
            assert(env.deleted_entities[1] == env.vehicles[1].entity,
                'deleted entity must be the spawned one')
        end)

        check('spawn_vehicle_plate_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.peds[7] = 99
            env.entity_coords[99] = { x = 1.0, y = 2.0, z = 3.0 }
            env.plate_readback_override = 'ZZZ999'

            local ok, err = env.actions._Execute.spawn_vehicle(1, {
                citizenid = 'ABC12345',
                model = 'sultan',
                plate = 'ABC123',
            })
            assert(ok == false, 'plate read-back mismatch must fail')
            assert(tostring(err):match('^verification_failed'), tostring(err))
            assert(tostring(err):match('ZZZ999'), 'error must include the read-back plate')
        end)

        check('spawn_vehicle_falls_back_without_server_setter', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.peds[7] = 99
            env.entity_coords[99] = { x = 5.0, y = 6.0, z = 7.0 }
            _G.CreateVehicleServerSetter = nil

            local ok, err, result = env.actions._Execute.spawn_vehicle(1, {
                citizenid = 'ABC12345',
                model = 'sultan',
            })
            assert(ok == true, tostring(err))
            assert(type(result.entity) == 'number', 'result.entity missing')
            assert(env.vehicles[1].native == 'create_vehicle',
                'CreateVehicle fallback was not used')
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
            error = failed == 0 and nil or 'executor cases failed',
        }
    end,
}
