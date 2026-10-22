-- tests/agent/lua/cases/effect_server.lua — server-side effect channel contract.
--
-- Every scenario gets a fresh bootstrap env so sessions, buckets and pending
-- state cannot leak between cases. `SetTimeout` is manual: env.Drain() runs
-- the timeout timers, while acks are delivered through the registered net
-- event exactly as FXServer would.

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

        local function newEnv(convars, online)
            local env = ctx.bootstrap.Load({
                agent_client = true,
                convars = convars or {},
                resource_states = { ['custom-logs'] = 'started' },
            })
            if online ~= false then env.peds[1] = 9001 end
            return env
        end

        local function enabled(overrides)
            local convars = { agent_effect_enabled = '1' }
            for key, value in pairs(overrides or {}) do convars[key] = value end
            return convars
        end

        local function findEvent(env, name)
            for index = #env.client_events, 1, -1 do
                local item = env.client_events[index]
                if item.event == name then return item end
            end
        end

        local function countEvents(env, name)
            local count = 0
            for _, item in ipairs(env.client_events) do
                if item.event == name then count = count + 1 end
            end
            return count
        end

        local function handshake(env, src)
            _G.source = src
            TriggerEvent('tcity:agent:ready')
            local hello = findEvent(env, 'tcity:agent:hello')
            assert(hello, 'ready did not produce a hello event')
            local message = hello.args[1]
            assert(type(message) == 'table' and message.v == 1, 'bad hello envelope')
            assert(type(message.session) == 'string' and #message.session == 16,
                'session must be 16 hex characters')
            return message.session
        end

        local function start(env, action, payload, timeout, opts)
            local co = coroutine.create(function()
                return env.exports.Execute(1, action, payload, timeout, opts)
            end)
            local ok, first, second, third = coroutine.resume(co)
            assert(ok, tostring(first))
            return co, first, second, third
        end

        local function finish(co)
            assert(coroutine.status(co) == 'suspended', 'caller was not waiting for a settle')
            local ok, first, second, third = coroutine.resume(co)
            assert(ok, tostring(first))
            return first, second, third
        end

        local function dispatch(env, action, payload, timeout, opts)
            local before = #env.client_events
            local co = start(env, action, payload, timeout, opts)
            local event = env.client_events[before + 1]
            assert(event and event.event == 'tcity:agent:exec', 'expected one exec event')
            local message = event.args[1]
            assert(type(message) == 'table', 'exec message must be a table')
            return co, message
        end

        local function sendAck(env, src, message, overrides)
            local ack = {
                v = 1,
                request_id = message.request_id,
                session = message.session,
                status = 'ok',
                detail = {},
            }
            for key, value in pairs(overrides or {}) do ack[key] = value end
            _G.source = src
            TriggerEvent('tcity:agent:ack', ack)
        end

        local function auditLines(env)
            local lines = {}
            for _, item in ipairs(env.log) do
                if item.export == 'custom-logs:LogGeneric' then
                    lines[#lines + 1] = tostring(item.args[2] or '')
                end
            end
            return lines
        end

        -- ------------------------------------------------------------------
        -- Gates
        -- ------------------------------------------------------------------
        check('channel_disabled_returns_executor_disabled', function()
            local env = newEnv({})
            local co, ok, result, err = start(env, 'send_notify', { text = 'hi', kind = 'info' })
            assert(coroutine.status(co) == 'dead', 'disabled call must not await')
            assert(ok == false and result == nil)
            assert(err.ok == false and err.code == 'executor_disabled')
            assert(#env.client_events == 0, 'disabled channel must not emit exec')
        end)

        check('main_thread_call_returns_not_yieldable', function()
            local env = newEnv(enabled())
            local ok, result, err = env.exports.Execute(1, 'send_notify', { text = 'hi', kind = 'info' })
            assert(ok == false and result == nil)
            assert(err.code == 'not_yieldable')
        end)

        check('offline_player_returns_player_offline', function()
            local env = newEnv(enabled(), false)
            local co, ok, result, err = start(env, 'send_notify', { text = 'hi', kind = 'info' })
            assert(coroutine.status(co) == 'dead')
            assert(ok == false and result == nil and err.code == 'player_offline')
        end)

        check('normalize_failure_is_returned_unchanged', function()
            local env = newEnv(enabled())
            local co, ok, result, err = start(env, 'send_notify',
                { text = 'hi', kind = 'info', event = 'QBCore:Notify' })
            assert(coroutine.status(co) == 'dead')
            assert(ok == false and result == nil)
            assert(err.code == 'invalid_params')
            assert(#env.client_events == 0, 'invalid payload must not reach the client')
        end)

        check('server_side_action_is_not_forwarded_to_client', function()
            local env = newEnv(enabled())
            local co, ok, result, err = start(env, 'give_vehicle_keys', { plate = 'ABC123' })
            assert(coroutine.status(co) == 'dead')
            assert(ok == false and result == nil and err.code == 'server_action_unsupported')
            assert(#env.client_events == 0)
        end)

        check('handshake_missing_returns_retryable_error', function()
            local env = newEnv(enabled())
            local co, ok, result, err = start(env, 'send_notify', { text = 'hi', kind = 'info' })
            assert(coroutine.status(co) == 'dead')
            assert(ok == false and result == nil and err.code == 'handshake_missing')
            assert(#env.client_events == 0)
        end)

        -- ------------------------------------------------------------------
        -- Inflight / rate limits
        -- ------------------------------------------------------------------
        check('inflight_limit_rejects_the_extra_request', function()
            local env = newEnv(enabled({ agent_effect_max_inflight = '1' }))
            handshake(env, 1)
            local co, message = dispatch(env, 'send_notify', { text = 'first', kind = 'info' })

            local co2, ok2, result2, err2 = start(env, 'send_notify', { text = 'second', kind = 'info' })
            assert(coroutine.status(co2) == 'dead')
            assert(ok2 == false and result2 == nil and err2.code == 'too_many_inflight')
            assert(countEvents(env, 'tcity:agent:exec') == 1, 'rejected request must not dispatch')

            sendAck(env, 1, message, { status = 'ok' })
            local ok = finish(co)
            assert(ok == true, 'first request must still succeed')
            assert(env.exports.Stats().inflight == 0)
        end)

        check('token_bucket_returns_rate_limited_with_retry_after', function()
            local env = newEnv(enabled({ agent_effect_burst = '1', agent_effect_rate_per_min = '1' }))
            handshake(env, 1)

            local co, message = dispatch(env, 'send_notify', { text = 'first', kind = 'info' })
            sendAck(env, 1, message, { status = 'ok' })
            assert(finish(co) == true)

            local co2, ok2, result2, err2 = start(env, 'send_notify', { text = 'second', kind = 'info' })
            assert(coroutine.status(co2) == 'dead')
            assert(ok2 == false and result2 == nil)
            assert(err2.code == 'rate_limited')
            assert(type(err2.detail) == 'table' and err2.detail.retry_after_ms > 0)
        end)

        -- ------------------------------------------------------------------
        -- Ack / settle
        -- ------------------------------------------------------------------
        check('ack_ok_settles_once_and_audits_without_text', function()
            local env = newEnv(enabled())
            local session = handshake(env, 1)
            local co, message = dispatch(env, 'send_notify',
                { text = 'top-secret-text', kind = 'primary' }, 4000, { agent_id = 'test.agent' })

            assert(message.v == 1)
            assert(message.request_id ~= '' and message.session == session)
            assert(message.action == 'send_notify')
            assert(message.payload.text == 'top-secret-text')
            assert(message.timeout_ms == 4000)

            sendAck(env, 1, message, { status = 'ok', detail = { latency_ms = 12 } })
            local ok, result, err = finish(co)
            assert(ok == true and err == nil)
            assert(result.latency_ms == 12)

            local snapshot = env.exports.Stats()
            assert(snapshot.ok == true and snapshot.pending == 0 and snapshot.inflight == 0)

            local lines = auditLines(env)
            assert(#lines == 1, 'expected exactly one audit line, got ' .. #lines)
            assert(lines[1]:find('status=ok', 1, true) ~= nil)
            assert(lines[1]:find('agent=test.agent', 1, true) ~= nil)
            assert(lines[1]:find('top-secret-text', 1, true) == nil,
                'audit must not contain the notify text')
        end)

        check('open_text_ui_audit_does_not_contain_body', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co, message = dispatch(env, 'open_text_ui',
                { title = 'notice', body = 'top-secret-body', timeout_ms = 2000 })

            sendAck(env, 1, message, { status = 'ok' })
            assert(finish(co) == true)
            local lines = auditLines(env)
            assert(#lines == 1)
            assert(lines[1]:find('top-secret-body', 1, true) == nil,
                'audit must not contain the open_text_ui body')
            assert(lines[1]:find('action=open_text_ui', 1, true) ~= nil)
        end)

        check('forged_ack_is_dropped_and_counted', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co, message = dispatch(env, 'send_notify', { text = 'hi', kind = 'info' }, 250)

            sendAck(env, 1, message, { session = 'forged-session', status = 'ok' })
            local snapshot = env.exports.Stats()
            assert(snapshot.pending == 1, 'forged ack must not settle the request')
            assert(snapshot.dropped_acks == 1)
            assert(#auditLines(env) == 0)

            env.Drain()
            local ok, result, err = finish(co)
            assert(ok == false and result == nil and err.code == 'timeout')
        end)

        check('timeout_settles_with_timeout_status', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co = dispatch(env, 'send_notify', { text = 'hi', kind = 'info' }, 250)

            env.Drain()
            local ok, result, err = finish(co)
            assert(ok == false and result == nil and err.code == 'timeout')
            assert(env.exports.Stats().pending == 0 and env.exports.Stats().inflight == 0)

            local lines = auditLines(env)
            assert(#lines == 1 and lines[1]:find('status=timeout', 1, true) ~= nil)
        end)

        check('duplicate_ack_only_settles_once', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co, message = dispatch(env, 'send_notify', { text = 'hi', kind = 'info' })

            sendAck(env, 1, message, { status = 'ok', detail = { first = true } })
            local ok, result = finish(co)
            assert(ok == true and result.first == true)

            sendAck(env, 1, message, { status = 'failed', error_code = 'late_failure' })
            local snapshot = env.exports.Stats()
            assert(snapshot.pending == 0 and snapshot.inflight == 0)
            assert(snapshot.dropped_acks == 1, 'duplicate ack must be dropped')

            local lines = auditLines(env)
            assert(#lines == 1, 'duplicate ack must not add an audit line')
            assert(lines[1]:find('status=ok', 1, true) ~= nil)
        end)

        -- ------------------------------------------------------------------
        -- Cancel / lifecycle
        -- ------------------------------------------------------------------
        check('cancel_settles_and_notifies_client', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co, message = dispatch(env, 'play_anim', {
                dict = 'amb@world_human_smoking@male@male_a@idle_a',
                clip = 'idle_a',
                duration_ms = 6000,
            })

            assert(env.exports.Cancel(1, message.request_id) == true)
            local cancelEvent = findEvent(env, 'tcity:agent:cancel')
            assert(cancelEvent and cancelEvent.args[1].request_id == message.request_id)
            local ok, result, err = finish(co)
            assert(ok == false and result == nil and err.code == 'cancelled')
            assert(env.exports.Cancel(1, message.request_id) == false, 'second cancel must be a no-op')

            local lines = auditLines(env)
            assert(#lines == 1 and lines[1]:find('status=cancelled', 1, true) ~= nil)
        end)

        check('player_drop_settles_pending_as_player_offline', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co = dispatch(env, 'send_notify', { text = 'hi', kind = 'info' })

            _G.source = 1
            TriggerEvent('playerDropped')
            local ok, result, err = finish(co)
            assert(ok == false and result == nil and err.code == 'player_offline')

            local snapshot = env.exports.Stats()
            assert(snapshot.pending == 0 and snapshot.inflight == 0 and snapshot.sessions == 0)
            local lines = auditLines(env)
            assert(#lines == 1 and lines[1]:find('status=player_offline', 1, true) ~= nil)
        end)

        check('resource_stop_settles_pending_as_executor_stopped', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local co, message = dispatch(env, 'send_notify', { text = 'hi', kind = 'info' })

            TriggerEvent('onResourceStop', 'custom-agent-client')
            local ok, result, err = finish(co)
            assert(ok == false and result == nil and err.code == 'executor_stopped')
            assert(env.exports.Stats().pending == 0)

            local lines = auditLines(env)
            assert(#lines == 1 and lines[1]:find('executor_stopped', 1, true) ~= nil)
            sendAck(env, 1, message, { status = 'ok' })
            assert(env.exports.Stats().dropped_acks == 1, 'late ack after stop must be dropped')
        end)

        check('stats_reports_pending_and_inflight', function()
            local env = newEnv(enabled())
            handshake(env, 1)
            local snapshot = env.exports.Stats()
            assert(snapshot.pending == 0 and snapshot.inflight == 0 and snapshot.sessions == 1)
            local co = dispatch(env, 'send_notify', { text = 'hi', kind = 'info' })
            local busy = env.exports.Stats()
            assert(busy.pending == 1 and busy.inflight == 1)
            env.Drain()
            finish(co)
            local idle = env.exports.Stats()
            assert(idle.pending == 0 and idle.inflight == 0)
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d effect server case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
