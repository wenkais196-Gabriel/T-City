-- tests/agent/lua/cases/director_actions.lua — executor contract for
-- custom-director's set_job (L3), grant_item (L4), teleport (L3, delegated to
-- custom-agent-client), spawn_vehicle (L3, server-side), revive (L3, server
-- metadata + qb-ambulancejob client event) and delete_vehicle (L4, current
-- vehicle only) actions.
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

        local function removeItem(env, citizenid, item, amount, reason)
            return env.actions._Execute.remove_item(1, {
                citizenid = citizenid,
                item = item,
                amount = amount,
                reason = reason or 'test cleanup',
            })
        end

        local function setBucket(env, citizenid, bucket)
            return env.actions._Execute.set_bucket(1, {
                citizenid = citizenid,
                bucket = bucket,
            })
        end

        local function setJobDuty(env, citizenid, onduty)
            return env.actions._Execute.set_job_duty(1, {
                citizenid = citizenid,
                onduty = onduty,
            })
        end

        local function setMetadata(env, citizenid, key, value)
            return env.actions._Execute.set_metadata(1, {
                citizenid = citizenid,
                key = key,
                value = value,
            })
        end

        local function kick(env, citizenid, reason)
            return env.actions._Execute.kick(1, {
                citizenid = citizenid,
                reason = reason or 'test kick',
            })
        end

        local function newPlayerWithPhone(env, citizenid, phone)
            local player = newPlayer(env, citizenid)
            player.PlayerData.charinfo.phone = phone
            return player
        end

        local function sendPhoneMessage(env, citizenid, message)
            return env.actions._Execute.send_phone_message(1, {
                citizenid = citizenid,
                message = message,
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
            assert(type(env.actions._Execute.set_job_duty) == 'function', 'set_job_duty executor missing')
            assert(type(env.actions._Execute.set_metadata) == 'function', 'set_metadata executor missing')
            assert(type(env.actions._Execute.grant_item) == 'function', 'grant_item executor missing')
            assert(type(env.actions._Execute.announce) == 'function', 'announce executor missing')
            assert(type(env.actions._Execute.set_weather) == 'function', 'set_weather executor missing')
            assert(type(env.actions._Execute.set_time_of_day) == 'function', 'set_time_of_day executor missing')
            assert(type(env.actions._Execute.teleport) == 'function', 'teleport executor missing')
            assert(type(env.actions._Execute.spawn_vehicle) == 'function', 'spawn_vehicle executor missing')
            assert(type(env.actions._Execute.remove_item) == 'function', 'remove_item executor missing')
            assert(type(env.actions._Execute.set_bucket) == 'function', 'set_bucket executor missing')
            assert(type(env.actions._Execute.kick) == 'function', 'kick executor missing')
            assert(type(env.actions._Execute.send_phone_message) == 'function',
                'send_phone_message executor missing')
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

        -- remove_item -----------------------------------------------------------

        check('remove_item_normalize_amount_bounds_and_default', function()
            local env = newEnv()
            for _, amount in ipairs({ 0, -1, 1.5, 51 }) do
                local normalized, err = env.policy.Normalize('remove_item', {
                    citizenid = 'ABC12345',
                    item = 'bread',
                    amount = amount,
                    reason = 'cleanup',
                })
                assert(normalized == nil, 'amount ' .. tostring(amount) .. ' must be rejected')
                assert(err and err.code == 'invalid_params',
                    'amount ' .. tostring(amount) .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local missing, missingErr = env.policy.Normalize('remove_item', {
                citizenid = 'ABC12345',
                item = 'bread',
                reason = 'cleanup',
            })
            assert(missing == nil, 'amount must be required, not defaulted to the cap')
            assert(missingErr.code == 'invalid_params', tostring(missingErr.code))

            local capped = newEnv({ agent_actions_max_item_amount = '7' })
            local overCap, overCapErr = capped.policy.Normalize('remove_item', {
                citizenid = 'ABC12345',
                item = 'bread',
                amount = 8,
                reason = 'cleanup',
            }, { max_item_amount = 7 })
            assert(overCap == nil, 'amount above the configured cap must be rejected')
            assert(overCapErr.code == 'invalid_params', tostring(overCapErr.code))

            local noReason, noReasonErr = env.policy.Normalize('remove_item', {
                citizenid = 'ABC12345',
                item = 'bread',
                amount = 1,
            })
            assert(noReason == nil, 'reason is required')
            assert(noReasonErr.code == 'invalid_params', tostring(noReasonErr.code))
        end)

        check('remove_item_normalize_rejects_unknown_field', function()
            local env = newEnv()
            local normalized, err = env.policy.Normalize('remove_item', {
                citizenid = 'ABC12345',
                item = 'bread',
                amount = 1,
                reason = 'cleanup',
                slot = 3,
            })
            assert(normalized == nil, 'unknown field must be rejected')
            assert(err and err.code == 'invalid_params', tostring(err and err.code))
            assert(tostring(err.message):match('unknown field slot'), tostring(err.message))
        end)

        check('remove_item_policy_requires_item_definition', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')

            local missing = { citizenid = 'ABC12345', item = 'gold', amount = 1, reason = 'cleanup' }
            local missingContext = env.actions._Context('remove_item', missing)
            local ok, err = env.policy.CheckPolicy('remove_item', missing, {}, missingContext)
            assert(ok == false, 'unknown item must be rejected')
            assert(err.code == 'item_not_found', tostring(err.code))

            local known = { citizenid = 'ABC12345', item = 'bread', amount = 1, reason = 'cleanup' }
            local knownContext = env.actions._Context('remove_item', known)
            local knownOk, knownErr = env.policy.CheckPolicy('remove_item', known, {}, knownContext)
            assert(knownOk == true, tostring(knownErr and knownErr.code))

            local definition = env.policy.ACTIONS.remove_item
            assert(definition.risk == 'L4', 'remove_item risk must be L4')
            assert(definition.requires_approval == true, 'remove_item must require approval')
            assert(definition.auto_execute == false, 'remove_item must never auto-execute')
            assert(definition.blast_radius == 'single', 'remove_item blast radius must be single')
            assert(definition.compensation == 'manual', 'remove_item compensation must be manual')
        end)

        check('remove_item_success_records_delta', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.items.bread = 5

            local params = assert(env.policy.Normalize('remove_item', {
                citizenid = 'ABC12345',
                item = 'bread',
                amount = 2,
                reason = 'confiscated',
            }))
            local context = env.actions._Context('remove_item', params)
            local preview = env.policy.Preview('remove_item', params, context, {})
            assert(preview.before == 5, 'preview.before must be the held quantity')
            assert(preview.amount == 2 and preview.reason == 'confiscated',
                'preview item/amount/reason mismatch')

            local ok, err, result = removeItem(env, 'ABC12345', 'bread', 2, 'confiscated')
            assert(ok == true, tostring(err))
            assert(result.item == 'bread' and result.amount == 2, 'result item/amount mismatch')
            assert(result.before == 5 and result.after == 3, 'before/after mismatch')
            assert(result.reason == 'confiscated', 'reason missing from result')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.items['bread'] == 3, 'inventory was not mutated')
            assert(env.log[#env.log].remove_item == 'ABC12345',
                'RemoveItem call was not recorded')
        end)

        check('remove_item_returns_false_when_removeitem_fails', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.items.bread = 2
            player.Functions.RemoveItem = function() return false end

            local ok, err = removeItem(env, 'ABC12345', 'bread', 1)
            assert(ok == false, 'RemoveItem false must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('remove_item_delta_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.items.bread = 5
            player.Functions.RemoveItem = function(item, amount)
                player.PlayerData.items[item] = player.PlayerData.items[item] - (amount - 1)
                return true
            end

            local ok, err = removeItem(env, 'ABC12345', 'bread', 2)
            assert(ok == false, 'partial remove must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('remove_item_offline_player', function()
            local env = newEnv()
            local ok, err = removeItem(env, 'OFFLINE01', 'bread', 1)
            assert(ok == false, 'offline target must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        -- set_bucket ------------------------------------------------------------

        check('set_bucket_normalize_rejects_out_of_range', function()
            local env = newEnv()
            for _, bucket in ipairs({ -1, 65536, 1.5, 0 / 0, math.huge }) do
                local normalized, err = env.policy.Normalize('set_bucket', {
                    citizenid = 'ABC12345',
                    bucket = bucket,
                })
                assert(normalized == nil, 'bucket ' .. tostring(bucket) .. ' must be rejected')
                assert(err and err.code == 'invalid_params',
                    'bucket ' .. tostring(bucket) .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local low = assert(env.policy.Normalize('set_bucket', {
                citizenid = 'ABC12345',
                bucket = 0,
            }))
            local high = assert(env.policy.Normalize('set_bucket', {
                citizenid = 'ABC12345',
                bucket = 65535,
            }))
            assert(low.bucket == 0 and high.bucket == 65535, 'bucket bounds must be inclusive')
        end)

        check('set_bucket_preview_and_success_readback', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.player_buckets[7] = 3

            local params = assert(env.policy.Normalize('set_bucket', {
                citizenid = 'ABC12345',
                bucket = 42,
            }))
            local context = env.actions._Context('set_bucket', params)
            assert(context.player.bucket == 3, 'context.player.bucket must be the live bucket')

            local preview = env.policy.Preview('set_bucket', params, context, {})
            assert(preview.bucket == 42, 'preview.bucket mismatch')
            assert(preview.from == 3, 'preview.from must be the current bucket')

            local policyOk, policyErr = env.policy.CheckPolicy('set_bucket', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))

            local ok, err, result = setBucket(env, 'ABC12345', 42)
            assert(ok == true, tostring(err))
            assert(result.bucket == 42 and result.before == 3, 'result bucket/before mismatch')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(tostring(result.notes):match('session%-scoped'), 'notes must explain scope')
            assert(tostring(result.notes):match('reconnect'), 'notes must mention reconnects')
            assert(env.player_buckets[7] == 42, 'routing bucket was not updated')
        end)

        check('set_bucket_returns_false_is_execution_failed', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.qb.Functions.SetPlayerBucket = function() return false end

            local ok, err = setBucket(env, 'ABC12345', 42)
            assert(ok == false, 'SetPlayerBucket false must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('set_bucket_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.qb.Functions.SetPlayerBucket = function() return true end -- lies: no mutation

            local ok, err = setBucket(env, 'ABC12345', 42)
            assert(ok == false, 'unchanged bucket must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_bucket_policy_and_metadata', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')

            local params = assert(env.policy.Normalize('set_bucket', {
                citizenid = 'ABC12345',
                bucket = 7,
            }))
            local context = env.actions._Context('set_bucket', params)
            local ok, err = env.policy.CheckPolicy('set_bucket', params, {}, context)
            assert(ok == true, tostring(err and err.code))

            local definition = env.policy.ACTIONS.set_bucket
            assert(definition.risk == 'L3', 'set_bucket risk must be L3')
            assert(definition.requires_approval == true, 'set_bucket must require approval')
            assert(definition.auto_execute == false, 'set_bucket must never auto-execute')
            assert(definition.blast_radius == 'single', 'set_bucket blast radius must be single')
        end)

        -- kick ------------------------------------------------------------------

        check('kick_requires_reason_and_rejects_unknown_field', function()
            local env = newEnv()
            local missing, missingErr = env.policy.Normalize('kick', { citizenid = 'ABC12345' })
            assert(missing == nil, 'missing reason must be rejected')
            assert(missingErr.code == 'invalid_params', tostring(missingErr.code))

            local blank, blankErr = env.policy.Normalize('kick', {
                citizenid = 'ABC12345',
                reason = '   ',
            })
            assert(blank == nil, 'blank reason must be rejected')
            assert(blankErr.code == 'invalid_params', tostring(blankErr.code))

            local control, controlErr = env.policy.Normalize('kick', {
                citizenid = 'ABC12345',
                reason = 'bad\nreason',
            })
            assert(control == nil, 'control characters must be rejected')
            assert(controlErr.code == 'invalid_params', tostring(controlErr.code))

            local unknown, unknownErr = env.policy.Normalize('kick', {
                citizenid = 'ABC12345',
                reason = 'cheating',
                duration = 60,
            })
            assert(unknown == nil, 'unknown field must be rejected')
            assert(unknownErr.code == 'invalid_params', tostring(unknownErr.code))
            assert(tostring(unknownErr.message):match('unknown field duration'),
                tostring(unknownErr.message))

            local edge = assert(env.policy.Normalize('kick', {
                citizenid = 'ABC12345',
                reason = string.rep('a', 128),
            }))
            assert(#edge.reason == 128, '128-char reason must be accepted')
            local tooLong, tooLongErr = env.policy.Normalize('kick', {
                citizenid = 'ABC12345',
                reason = string.rep('a', 129),
            })
            assert(tooLong == nil, '129-char reason must be rejected (contract cap)')
            assert(tooLongErr.code == 'invalid_params', tostring(tooLongErr.code))
        end)

        check('kick_success_records_call', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')

            local params = assert(env.policy.Normalize('kick', {
                citizenid = 'ABC12345',
                reason = 'cheating',
            }))
            local context = env.actions._Context('kick', params)
            local preview = env.policy.Preview('kick', params, context, {})
            assert(preview.citizenid == 'ABC12345' and preview.reason == 'cheating',
                'kick preview mismatch')

            local policyOk, policyErr = env.policy.CheckPolicy('kick', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))

            local ok, err, result = kick(env, 'ABC12345', 'cheating')
            assert(ok == true, tostring(err))
            assert(result.kicked == true and result.reason == 'cheating', 'result mismatch')
            assert(#env.kicks == 1, 'Kick was not called')
            assert(env.kicks[1].source == 7 and env.kicks[1].reason == 'cheating',
                'Kick call arguments mismatch')
        end)

        check('kick_throwing_kick_is_execution_failed', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.qb.Functions.Kick = function() error('kick channel down') end

            local ok, err = kick(env, 'ABC12345', 'cheating')
            assert(ok == false, 'throwing Kick must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
            assert(tostring(err):match('kick channel down'), tostring(err))
        end)

        check('kick_metadata_requires_manual_compensation', function()
            local env = newEnv()
            local definition = env.policy.ACTIONS.kick
            assert(definition.risk == 'L4', 'kick risk must be L4')
            assert(definition.requires_approval == true, 'kick must require approval')
            assert(definition.auto_execute == false, 'kick must never auto-execute')
            assert(definition.blast_radius == 'single', 'kick blast radius must be single')
            assert(definition.compensation == 'manual', 'kick compensation must be manual')
        end)

        -- revive ---------------------------------------------------------------

        local function putPlayerInVehicle(env, source, entity, plate)
            env.peds[source] = 99
            env.vehicle_in_use[99] = entity
            env.created_entities[entity] = true
            env.entity_models[entity] = 123456
            env.vehicle_plates[entity] = plate or 'ABC123'
        end

        check('revive_success_sets_metadata_and_client_event', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.metadata.isdead = true
            player.PlayerData.metadata.inlaststand = true

            local definition = env.policy.ACTIONS.revive
            assert(type(definition) == 'table', 'revive missing from ACTIONS')
            assert(definition.risk == 'L3', 'revive risk must be L3')
            assert(definition.requires_approval == true, 'revive must require approval')
            assert(definition.auto_execute == false, 'revive must never auto-execute')
            assert(definition.blast_radius == 'single', 'revive blast radius must be single')

            local params = assert(env.policy.Normalize('revive', { citizenid = 'ABC12345' }))
            local context = env.actions._Context('revive', params)
            local preview = env.policy.Preview('revive', params, context, {})
            assert(preview.metadata.isdead == true and preview.metadata.inlaststand == true,
                'preview metadata must reflect the live death state')

            local policyOk, policyErr = env.policy.CheckPolicy('revive', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))

            local ok, err, result = env.actions._Execute.revive(1, params)
            assert(ok == true, tostring(err))
            assert(result.before.isdead == true and result.before.inlaststand == true,
                'before must capture the pre-revive metadata')
            assert(result.after.isdead == false and result.after.inlaststand == false,
                'after must capture the cleared metadata')
            assert(player.PlayerData.metadata.isdead == false,
                'PlayerData.metadata.isdead was not cleared')
            assert(player.PlayerData.metadata.inlaststand == false,
                'PlayerData.metadata.inlaststand was not cleared')

            assert(#env.client_events == 1, 'hospital:client:Revive was not triggered')
            assert(env.client_events[1].event == 'hospital:client:Revive',
                'wrong client event: ' .. tostring(env.client_events[1].event))
            assert(env.client_events[1].target == 7, 'client event target must be the player source')
        end)

        check('revive_already_alive_still_succeeds', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.metadata.isdead = false
            player.PlayerData.metadata.inlaststand = false

            local ok, err, result = env.actions._Execute.revive(1, { citizenid = 'ABC12345' })
            assert(ok == true, tostring(err))
            assert(result.before.isdead == false and result.before.inlaststand == false,
                'before must keep the already-alive values')
            assert(result.after.isdead == false and result.after.inlaststand == false,
                'after must stay false/false')
            assert(#env.client_events == 1, 'the client event should still be attempted')
        end)

        check('revive_preview_missing_metadata_fields_are_nil', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345') -- metadata = {} in the stub
            local params = { citizenid = 'ABC12345' }
            local context = env.actions._Context('revive', params)
            local preview = env.policy.Preview('revive', params, context, {})
            assert(type(preview.metadata) == 'table', 'preview.metadata must be present')
            assert(preview.metadata.isdead == nil and preview.metadata.inlaststand == nil,
                'missing metadata keys must stay nil')
        end)

        check('revive_client_event_failure_is_contained', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.metadata.isdead = true
            player.PlayerData.metadata.inlaststand = true
            _G.TriggerClientEvent = function() error('ambulancejob handler crashed') end

            local ok, err, result = env.actions._Execute.revive(1, { citizenid = 'ABC12345' })
            assert(ok == true, 'a throwing client event must not fail the server mutation: '
                .. tostring(err))
            assert(result.after.isdead == false and result.after.inlaststand == false,
                'metadata must still be cleared')
            assert(player.PlayerData.metadata.isdead == false,
                'metadata read-back must reflect the cleared state')
        end)

        check('revive_normalize_rejects_unknown_field', function()
            local env = newEnv()
            local normalized, err = env.policy.Normalize('revive', {
                citizenid = 'ABC12345',
                reason = 'player asked',
            })
            assert(normalized == nil, 'unknown field must be rejected')
            assert(err and err.code == 'invalid_params', tostring(err and err.code))
            assert(tostring(err.message):match('unknown field reason'), tostring(err.message))
        end)

        check('revive_metadata_not_cleared_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.metadata.isdead = true
            player.Functions.SetMetaData = function() end -- lies: no mutation

            local ok, err = env.actions._Execute.revive(1, { citizenid = 'ABC12345' })
            assert(ok == false, 'unchanged metadata must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
            assert(#env.client_events == 1, 'the client event is still best-effort')
        end)

        check('revive_offline_player_is_rejected', function()
            local env = newEnv()
            local params = { citizenid = 'OFFLINE01' }
            local context = env.actions._Context('revive', params)
            local ok, err = env.policy.CheckPolicy('revive', params, {}, context)
            assert(ok == false, 'offline target must be rejected')
            assert(err.code == 'player_not_found', tostring(err.code))

            local execOk, execErr = env.actions._Execute.revive(1, params)
            assert(execOk == false and execErr == 'player_not_found', tostring(execErr))
        end)

        -- delete_vehicle --------------------------------------------------------

        check('delete_vehicle_registry_preview_and_policy', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            putPlayerInVehicle(env, 7, 701, 'ABC123')

            local definition = env.policy.ACTIONS.delete_vehicle
            assert(type(definition) == 'table', 'delete_vehicle missing from ACTIONS')
            assert(definition.risk == 'L4', 'delete_vehicle risk must be L4')
            assert(definition.requires_approval == true, 'delete_vehicle must require approval')
            assert(definition.auto_execute == false, 'delete_vehicle must never auto-execute')
            assert(definition.blast_radius == 'single', 'delete_vehicle blast radius must be single')
            assert(definition.compensation == 'manual', 'delete_vehicle compensation must be manual')

            local params = assert(env.policy.Normalize('delete_vehicle', {
                citizenid = 'ABC12345',
                plate = 'abc123',
            }))
            assert(params.plate == 'ABC123', 'plate must be uppercased')

            local context = env.actions._Context('delete_vehicle', params)
            assert(context.vehicle_entity == 701, 'context.vehicle_entity must be the current vehicle')
            assert(context.vehicle_target.entity == 701
                and context.vehicle_target.model == 123456
                and context.vehicle_target.plate == 'ABC123',
                'context.vehicle_target mismatch')

            local preview = env.policy.Preview('delete_vehicle', params, context, {})
            assert(preview.plate == 'ABC123', 'preview.plate mismatch')
            assert(preview.target.entity == 701 and preview.target.model == 123456
                and preview.target.plate == 'ABC123', 'preview.target mismatch')

            local policyOk, policyErr = env.policy.CheckPolicy('delete_vehicle', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))
        end)

        check('delete_vehicle_not_in_vehicle_is_rejected', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            env.peds[7] = 99 -- online and spawned, but on foot (no vehicle_in_use entry)

            local params = assert(env.policy.Normalize('delete_vehicle', {
                citizenid = 'ABC12345',
            }))
            local context = env.actions._Context('delete_vehicle', params)
            assert(context.vehicle_entity == nil, 'context must not invent a vehicle')
            local preview = env.policy.Preview('delete_vehicle', params, context, {})
            assert(preview.target == nil, 'preview.target must be nil when on foot')

            local ok, err = env.policy.CheckPolicy('delete_vehicle', params, {}, context)
            assert(ok == false, 'a player on foot must be rejected')
            assert(err.code == 'not_in_vehicle', tostring(err.code))

            local execOk, execErr = env.actions._Execute.delete_vehicle(1, params)
            assert(execOk == false and execErr == 'not_in_vehicle', tostring(execErr))
            assert(#env.deleted_entities == 0, 'nothing may be deleted')
        end)

        check('delete_vehicle_plate_mismatch_is_rejected', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            putPlayerInVehicle(env, 7, 702, 'ABC123')

            local params = assert(env.policy.Normalize('delete_vehicle', {
                citizenid = 'ABC12345',
                plate = 'zzz999',
            }))
            local context = env.actions._Context('delete_vehicle', params)

            local ok, err = env.policy.CheckPolicy('delete_vehicle', params, {}, context)
            assert(ok == false, 'plate mismatch must be rejected by policy')
            assert(err.code == 'plate_mismatch', tostring(err.code))

            local execOk, execErr = env.actions._Execute.delete_vehicle(1, params)
            assert(execOk == false, 'executor must re-check the plate (TOCTOU)')
            assert(tostring(execErr):match('^plate_mismatch'), tostring(execErr))
            assert(#env.deleted_entities == 0, 'mismatched vehicle must not be deleted')
        end)

        check('delete_vehicle_success_confirms_entity_gone', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            putPlayerInVehicle(env, 7, 703, 'ABC123')

            local params = assert(env.policy.Normalize('delete_vehicle', {
                citizenid = 'ABC12345',
                plate = 'abc123',
            }))
            local ok, err, result = env.actions._Execute.delete_vehicle(1, params)
            assert(ok == true, tostring(err))
            assert(result.entity == 703, 'result.entity mismatch')
            assert(result.model == 123456, 'result.model mismatch')
            assert(result.plate == 'ABC123', 'result.plate mismatch')
            assert(#env.deleted_entities == 1 and env.deleted_entities[1] == 703,
                'DeleteEntity was not called with the current vehicle')
            assert(DoesEntityExist(703) == false, 'the deleted entity must not exist')
        end)

        check('delete_vehicle_lingering_entity_is_verification_failed', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            putPlayerInVehicle(env, 7, 704, 'ABC123')
            env.entity_exists_override = true -- DeleteEntity "fails" to remove it

            local waits = 0
            _G.Wait = function()
                waits = waits + 1
                env.now = env.now + 500
            end
            _G.GetGameTimer = function() return env.now end

            local ok, err = env.actions._Execute.delete_vehicle(1, { citizenid = 'ABC12345' })
            assert(ok == false, 'a surviving entity must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
            assert(#env.deleted_entities == 1 and env.deleted_entities[1] == 704,
                'DeleteEntity must still have been attempted')
            assert(waits >= 1 and waits <= 10,
                'the confirmation wait must be bounded, took ' .. tostring(waits) .. ' waits')
        end)

        check('delete_vehicle_normalize_rejects_bad_plate_and_unknown_field', function()
            local env = newEnv()
            local badPlates = {
                { value = '', label = 'empty' },
                { value = 'ABCDEFGHI', label = 'too long' },
                { value = 'AB-CD', label = 'dash' },
                { value = 'ABC 123', label = 'inner space' },
                { value = 42, label = 'non-string' },
            }
            for _, case in ipairs(badPlates) do
                local normalized, err = env.policy.Normalize('delete_vehicle', {
                    citizenid = 'ABC12345',
                    plate = case.value,
                })
                assert(normalized == nil, case.label .. ' plate must be rejected')
                assert(err and err.code == 'invalid_params',
                    case.label .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local unknown, unknownErr = env.policy.Normalize('delete_vehicle', {
                citizenid = 'ABC12345',
                entity = 123,
            })
            assert(unknown == nil, 'an arbitrary entity id must be rejected')
            assert(unknownErr and unknownErr.code == 'invalid_params',
                tostring(unknownErr and unknownErr.code))
            assert(tostring(unknownErr.message):match('unknown field entity'),
                tostring(unknownErr.message))

            local optional = assert(env.policy.Normalize('delete_vehicle', {
                citizenid = 'ABC12345',
            }))
            assert(optional.plate == nil, 'plate must stay optional')
        end)

        -- set_job_duty ----------------------------------------------------------

        check('set_job_duty_normalize_rejects_non_boolean', function()
            local env = newEnv()
            for _, onduty in ipairs({ 'true', 'false', 1, 0, {} }) do
                local normalized, err = env.policy.Normalize('set_job_duty', {
                    citizenid = 'ABC12345',
                    onduty = onduty,
                })
                assert(normalized == nil, 'onduty ' .. tostring(onduty) .. ' must be rejected')
                assert(err and err.code == 'invalid_params',
                    'onduty ' .. tostring(onduty) .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local missing, missingErr = env.policy.Normalize('set_job_duty', {
                citizenid = 'ABC12345',
            })
            assert(missing == nil, 'missing onduty must be rejected')
            assert(missingErr.code == 'invalid_params', tostring(missingErr.code))

            local on = assert(env.policy.Normalize('set_job_duty', {
                citizenid = 'ABC12345',
                onduty = true,
            }))
            local off = assert(env.policy.Normalize('set_job_duty', {
                citizenid = 'ABC12345',
                onduty = false,
            }))
            assert(on.onduty == true and off.onduty == false, 'boolean values must be preserved')
        end)

        check('set_job_duty_normalize_rejects_unknown_field', function()
            local env = newEnv()
            local unknown, unknownErr = env.policy.Normalize('set_job_duty', {
                citizenid = 'ABC12345',
                onduty = true,
                duration = 60,
            })
            assert(unknown == nil, 'unknown field must be rejected')
            assert(unknownErr and unknownErr.code == 'invalid_params',
                tostring(unknownErr and unknownErr.code))
            assert(tostring(unknownErr.message):match('unknown field duration'),
                tostring(unknownErr.message))
        end)

        check('set_job_duty_registry_preview_and_policy', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')

            local definition = env.policy.ACTIONS.set_job_duty
            assert(type(definition) == 'table', 'set_job_duty missing from ACTIONS')
            assert(definition.risk == 'L2', 'set_job_duty risk must be L2')
            assert(definition.requires_approval == true, 'set_job_duty must require approval')
            assert(definition.auto_execute == false, 'set_job_duty must never auto-execute')
            assert(definition.blast_radius == 'single', 'set_job_duty blast radius must be single')

            local params = assert(env.policy.Normalize('set_job_duty', {
                citizenid = 'ABC12345',
                onduty = true,
            }))
            local context = env.actions._Context('set_job_duty', params)
            assert(type(context.player) == 'table' and type(context.player.job) == 'table',
                'context.player.job must be present')

            local preview = env.policy.Preview('set_job_duty', params, context, {})
            assert(preview.citizenid == 'ABC12345', 'preview.citizenid mismatch')
            assert(preview.onduty == true, 'preview.onduty mismatch')
            assert(preview.from == false, 'preview.from must be the current onduty state')

            local policyOk, policyErr = env.policy.CheckPolicy('set_job_duty', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))
        end)

        check('set_job_duty_success_records_before_and_readback', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')

            local ok, err, result = setJobDuty(env, 'ABC12345', true)
            assert(ok == true, tostring(err))
            assert(result.onduty == true and result.before == false, 'result onduty/before mismatch')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.job.onduty == true, 'PlayerData.job.onduty was not updated')

            local offOk, offErr, off = setJobDuty(env, 'ABC12345', false)
            assert(offOk == true, tostring(offErr))
            assert(off.before == true and off.onduty == false, 'second flip mismatch')
            assert(player.PlayerData.job.onduty == false, 'onduty was not cleared')
        end)

        check('set_job_duty_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.SetJobDuty = function() end -- lies: no mutation

            local ok, err = setJobDuty(env, 'ABC12345', true)
            assert(ok == false, 'unchanged duty must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_job_duty_policy_requires_job', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.job = nil

            local params = assert(env.policy.Normalize('set_job_duty', {
                citizenid = 'ABC12345',
                onduty = true,
            }))
            local context = env.actions._Context('set_job_duty', params)
            assert(context.player.job == nil, 'context.player.job must stay nil')

            local policyOk, policyErr = env.policy.CheckPolicy('set_job_duty', params, {}, context)
            assert(policyOk == false, 'missing job must be rejected')
            assert(policyErr.code == 'job_unavailable', tostring(policyErr.code))
        end)

        check('set_job_duty_offline_and_throwing_api', function()
            local env = newEnv()

            local offlineOk, offlineErr = setJobDuty(env, 'OFFLINE01', true)
            assert(offlineOk == false, 'offline target must fail')
            assert(offlineErr == 'player_not_found', tostring(offlineErr))

            local player = newPlayer(env, 'ABC12345')
            player.Functions.SetJobDuty = function() error('duty channel down') end
            local ok, err = setJobDuty(env, 'ABC12345', true)
            assert(ok == false, 'throwing SetJobDuty must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
            assert(tostring(err):match('duty channel down'), tostring(err))
        end)

        -- set_metadata -----------------------------------------------------------

        check('set_metadata_normalize_rejects_unknown_key', function()
            local env = newEnv()
            local invalidKeys = {
                'isdead', 'inlaststand', 'ishandcuffed', 'health', 'rep', 'HUNGER', 'armour',
            }
            for _, key in ipairs(invalidKeys) do
                local normalized, err = env.policy.Normalize('set_metadata', {
                    citizenid = 'ABC12345',
                    key = key,
                    value = 50,
                })
                assert(normalized == nil, 'key ' .. tostring(key) .. ' must be rejected')
                assert(err and err.code == 'invalid_params',
                    'key ' .. tostring(key) .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local missing, missingErr = env.policy.Normalize('set_metadata', {
                citizenid = 'ABC12345',
                value = 50,
            })
            assert(missing == nil, 'missing key must be rejected')
            assert(missingErr.code == 'invalid_params', tostring(missingErr.code))

            for _, key in ipairs({ 'hunger', 'thirst', 'stress', 'armor' }) do
                local normalized = assert(env.policy.Normalize('set_metadata', {
                    citizenid = 'ABC12345',
                    key = key,
                    value = 100,
                }))
                assert(normalized.key == key, 'key ' .. key .. ' must be whitelisted')
            end
        end)

        check('set_metadata_normalize_rejects_bad_value', function()
            local env = newEnv()
            local badValues = { -1, 101, 1.5, '50', 0 / 0, math.huge, true }
            for _, value in ipairs(badValues) do
                local normalized, err = env.policy.Normalize('set_metadata', {
                    citizenid = 'ABC12345',
                    key = 'hunger',
                    value = value,
                })
                assert(normalized == nil, 'value ' .. tostring(value) .. ' must be rejected')
                assert(err and err.code == 'invalid_params',
                    'value ' .. tostring(value) .. ': expected invalid_params, got '
                        .. tostring(err and err.code))
            end

            local low = assert(env.policy.Normalize('set_metadata', {
                citizenid = 'ABC12345',
                key = 'hunger',
                value = 0,
            }))
            local high = assert(env.policy.Normalize('set_metadata', {
                citizenid = 'ABC12345',
                key = 'hunger',
                value = 100,
            }))
            assert(low.value == 0 and high.value == 100, 'value bounds must be inclusive')
        end)

        check('set_metadata_normalize_rejects_unknown_field', function()
            local env = newEnv()
            local unknown, unknownErr = env.policy.Normalize('set_metadata', {
                citizenid = 'ABC12345',
                key = 'hunger',
                value = 50,
                meta = 'isdead',
            })
            assert(unknown == nil, 'unknown field must be rejected')
            assert(unknownErr and unknownErr.code == 'invalid_params',
                tostring(unknownErr and unknownErr.code))
            assert(tostring(unknownErr.message):match('unknown field meta'),
                tostring(unknownErr.message))
        end)

        check('set_metadata_registry_preview_and_success', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.metadata.hunger = 42

            local definition = env.policy.ACTIONS.set_metadata
            assert(type(definition) == 'table', 'set_metadata missing from ACTIONS')
            assert(definition.risk == 'L3', 'set_metadata risk must be L3')
            assert(definition.requires_approval == true, 'set_metadata must require approval')
            assert(definition.auto_execute == false, 'set_metadata must never auto-execute')
            assert(definition.blast_radius == 'single', 'set_metadata blast radius must be single')

            local params = assert(env.policy.Normalize('set_metadata', {
                citizenid = 'ABC12345',
                key = 'hunger',
                value = 80,
            }))
            local context = env.actions._Context('set_metadata', params)
            assert(type(context.player.metadata) == 'table', 'context.player.metadata missing')

            local preview = env.policy.Preview('set_metadata', params, context, {})
            assert(preview.key == 'hunger' and preview.value == 80, 'preview key/value mismatch')
            assert(preview.from == 42, 'preview.from must be the current metadata value')

            local policyOk, policyErr = env.policy.CheckPolicy('set_metadata', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))

            local ok, err, result = setMetadata(env, 'ABC12345', 'hunger', 80)
            assert(ok == true, tostring(err))
            assert(result.key == 'hunger' and result.value == 80, 'result key/value mismatch')
            assert(result.before == 42, 'result.before must be the previous value')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.metadata.hunger == 80, 'metadata was not updated')
        end)

        check('set_metadata_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.SetMetaData = function() end -- lies: no mutation

            local ok, err = setMetadata(env, 'ABC12345', 'stress', 20)
            assert(ok == false, 'unchanged metadata must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_metadata_policy_and_execution_require_online_player', function()
            local env = newEnv()
            local params = assert(env.policy.Normalize('set_metadata', {
                citizenid = 'OFFLINE01',
                key = 'thirst',
                value = 60,
            }))
            local context = env.actions._Context('set_metadata', params)
            local policyOk, policyErr = env.policy.CheckPolicy('set_metadata', params, {}, context)
            assert(policyOk == false, 'offline target must be rejected by policy')
            assert(policyErr.code == 'player_not_found', tostring(policyErr.code))

            local ok, err = setMetadata(env, 'OFFLINE01', 'thirst', 60)
            assert(ok == false, 'offline execution must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        check('set_metadata_throwing_setmetadata_is_execution_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.SetMetaData = function() error('metadata channel down') end

            local ok, err = setMetadata(env, 'ABC12345', 'armor', 100)
            assert(ok == false, 'throwing SetMetaData must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
            assert(tostring(err):match('metadata channel down'), tostring(err))
        end)

        check('send_phone_message_registry_context_preview_and_policy', function()
            local env = newEnv()
            local player = newPlayerWithPhone(env, 'ABC12345', '555-0100')

            local definition = env.policy.ACTIONS.send_phone_message
            assert(type(definition) == 'table', 'send_phone_message missing from ACTIONS')
            assert(definition.risk == 'L2', 'send_phone_message risk must be L2')
            assert(definition.requires_approval == true, 'send_phone_message must require approval')
            assert(definition.auto_execute == false, 'send_phone_message must never auto-execute')
            assert(definition.blast_radius == 'single', 'blast_radius must be single')

            local message = string.rep('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 2)
            local params = assert(env.policy.Normalize('send_phone_message', {
                citizenid = 'ABC12345',
                message = message,
            }))
            assert(params.message == message, 'message must be preserved verbatim')

            local context = env.actions._Context('send_phone_message', params)
            assert(context.player and context.player.phone == '555-0100',
                'buildContext must inject charinfo.phone')

            local preview = env.policy.Preview('send_phone_message', params, context, {})
            assert(preview.citizenid == 'ABC12345', 'preview must carry citizenid')
            assert(preview.length == #message, 'preview.length mismatch')
            assert(preview.preview == message:sub(1, 40), 'preview must be the first 40 chars')

            local policyOk, policyErr = env.policy.CheckPolicy(
                'send_phone_message', params, {}, context)
            assert(policyOk == true, tostring(policyErr and policyErr.code))
            assert(player.PlayerData.charinfo.phone == '555-0100', 'context must not mutate player')
        end)

        check('send_phone_message_normalize_rejects_missing_message', function()
            local env = newEnv()
            local cases = {
                { citizenid = 'ABC12345' },
                { citizenid = 'ABC12345', message = '' },
                { citizenid = 'ABC12345', message = 42 },
                { citizenid = 'ABC12345', message = true },
            }
            for _, params in ipairs(cases) do
                local normalized, err = env.policy.Normalize('send_phone_message', params)
                assert(normalized == nil, 'invalid message must be rejected')
                assert(err and err.code == 'invalid_params',
                    'expected invalid_params, got ' .. tostring(err and err.code))
            end
        end)

        check('send_phone_message_normalize_rejects_overlong_message', function()
            local env = newEnv()
            local tooLong, tooLongErr = env.policy.Normalize('send_phone_message', {
                citizenid = 'ABC12345',
                message = string.rep('a', 501),
            })
            assert(tooLong == nil, '501 chars must be rejected')
            assert(tooLongErr and tooLongErr.code == 'invalid_params',
                tostring(tooLongErr and tooLongErr.code))

            local max = assert(env.policy.Normalize('send_phone_message', {
                citizenid = 'ABC12345',
                message = string.rep('a', 500),
            }))
            assert(#max.message == 500, '500 chars must be accepted')

            -- custom-phone counts bytes: 200 CJK chars are 600 bytes and must
            -- be rejected here too, not after approval.
            local multibyte, multibyteErr = env.policy.Normalize('send_phone_message', {
                citizenid = 'ABC12345',
                message = string.rep('你', 200),
            })
            assert(multibyte == nil, '600-byte message must be rejected')
            assert(multibyteErr and multibyteErr.code == 'invalid_params',
                tostring(multibyteErr and multibyteErr.code))
        end)

        check('send_phone_message_normalize_control_chars', function()
            local env = newEnv()
            -- LF is allowed (multi-line SMS); every other C0 byte and DEL is not.
            local multiline = assert(env.policy.Normalize('send_phone_message', {
                citizenid = 'ABC12345',
                message = 'line one' .. string.char(10) .. 'line two',
            }))
            assert(#multiline.message == 17, 'LF must be preserved')

            local rejected = {
                string.char(0),
                '\t',
                '\r',
                string.char(127),
                'hi' .. string.char(7) .. 'there',
            }
            for _, message in ipairs(rejected) do
                local normalized, err = env.policy.Normalize('send_phone_message', {
                    citizenid = 'ABC12345',
                    message = message,
                })
                assert(normalized == nil,
                    ('message with byte %d must be rejected'):format(message:byte(1)))
                assert(err and err.code == 'invalid_params',
                    'expected invalid_params, got ' .. tostring(err and err.code))
            end
        end)

        check('send_phone_message_normalize_rejects_unknown_field', function()
            local env = newEnv()
            for _, extra in ipairs({
                { sender = 'City Services' },
                { text = 'hello' },
                { phone = '555-0100' },
            }) do
                local params = {
                    citizenid = 'ABC12345',
                    message = 'hello',
                }
                for key, value in pairs(extra) do params[key] = value end
                local normalized, err = env.policy.Normalize('send_phone_message', params)
                assert(normalized == nil, 'unknown field must be rejected')
                assert(err and err.code == 'invalid_params',
                    tostring(err and err.code))
                assert(tostring(err.message):match('^unknown field'),
                    tostring(err.message))
            end
        end)

        check('send_phone_message_phone_missing_is_phone_unavailable', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.PlayerData.charinfo.phone = nil

            local params = assert(env.policy.Normalize('send_phone_message', {
                citizenid = 'ABC12345',
                message = 'hello',
            }))
            local context = env.actions._Context('send_phone_message', params)
            assert(context.player and context.player.phone == nil,
                'missing phone must surface as nil in context')

            local policyOk, policyErr = env.policy.CheckPolicy(
                'send_phone_message', params, {}, context)
            assert(policyOk == false, 'missing phone must be rejected by policy')
            assert(policyErr.code == 'phone_unavailable', tostring(policyErr.code))

            -- An empty string is unavailable too (not "a phone with no digits").
            player.PlayerData.charinfo.phone = ''
            local emptyContext = env.actions._Context('send_phone_message', params)
            local emptyOk, emptyErr = env.policy.CheckPolicy(
                'send_phone_message', params, {}, emptyContext)
            assert(emptyOk == false and emptyErr.code == 'phone_unavailable',
                tostring(emptyErr and emptyErr.code))

            local ok, err = sendPhoneMessage(env, 'ABC12345', 'hello')
            assert(ok == false, 'executor must refuse a player without a phone')
            assert(err == 'phone_unavailable', tostring(err))
        end)

        check('send_phone_message_success_masks_number', function()
            local env = newEnv()
            local phone = '555-0100'
            newPlayerWithPhone(env, 'ABC12345', phone)

            local calls = {}
            env.export_overrides['custom-phone'] = {
                SendSystemMessage = function(receiverNumber, message, senderLabel)
                    calls[#calls + 1] = {
                        receiver = receiverNumber,
                        message = message,
                        sender = senderLabel,
                    }
                    return true
                end,
            }

            local message = 'Your vehicle has been impounded. Contact City Services.'
            local ok, err, result = sendPhoneMessage(env, 'ABC12345', message)
            assert(ok == true, tostring(err))
            assert(result.message_length == #message, 'message_length mismatch')
            assert(result.phone_masked == '555***00', tostring(result.phone_masked))
            assert(type(result.at) == 'number', 'result.at must be a timestamp')

            -- The full number must never appear in the audit result.
            for key, value in pairs(result) do
                assert(tostring(value):find(phone, 1, true) == nil,
                    'result.' .. tostring(key) .. ' leaked the full phone number')
            end

            assert(#calls == 1, 'export must be called exactly once')
            assert(calls[1].receiver == phone, 'export must receive the target phone')
            assert(calls[1].message == message, 'export must receive the message')
            assert(calls[1].sender == 'City Services', 'sender label must be server-chosen')
        end)

        check('send_phone_message_export_false_is_execution_failed', function()
            local env = newEnv()
            newPlayerWithPhone(env, 'ABC12345', '555-0100')
            env.export_overrides['custom-phone'] = {
                SendSystemMessage = function()
                    return false, 'db_error'
                end,
            }

            local ok, err = sendPhoneMessage(env, 'ABC12345', 'hello')
            assert(ok == false, 'export failure must fail the action')
            assert(err == 'execution_failed: db_error', tostring(err))
        end)

        check('send_phone_message_export_true_with_error_is_execution_failed', function()
            local env = newEnv()
            newPlayerWithPhone(env, 'ABC12345', '555-0100')
            env.export_overrides['custom-phone'] = {
                SendSystemMessage = function()
                    return true, 'unexpected'
                end,
            }

            local ok, err = sendPhoneMessage(env, 'ABC12345', 'hello')
            assert(ok == false, 'true plus a non-nil err must fail the action')
            assert(err == 'execution_failed: unexpected', tostring(err))
        end)

        check('send_phone_message_export_throw_is_phone_unavailable', function()
            local env = newEnv()
            newPlayerWithPhone(env, 'ABC12345', '555-0100')
            env.export_overrides['custom-phone'] = {
                SendSystemMessage = function()
                    error('phone channel down')
                end,
            }

            local ok, err = sendPhoneMessage(env, 'ABC12345', 'hello')
            assert(ok == false, 'throwing export must fail the action')
            assert(err == 'phone_unavailable', tostring(err))
        end)

        check('send_phone_message_offline_player', function()
            local env = newEnv()
            local ok, err = sendPhoneMessage(env, 'OFFLINE01', 'hello')
            assert(ok == false, 'offline target must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        check('self_approval_detection', function()
            local env = newEnv()
            local isSelf = env.actions._IsSelfApproval
            assert(type(isSelf) == 'function', 'self-approval helper not exposed')
            assert(isSelf('agent-1', 'agent-1') == true, 'same id must be self-approval')
            assert(isSelf('Agent-1', 'agent-1') == true, 'comparison is case-insensitive')
            assert(isSelf('agent:agent-1', 'agent-1') == true, 'agent: prefix must be self')
            assert(isSelf('console', 'agent-1') == false, 'console is not the agent')
            assert(isSelf('discord:alice', 'agent-1') == false, 'a human approver is allowed')
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
            error = failed == 0 and nil or 'executor cases failed',
        }
    end,
}
