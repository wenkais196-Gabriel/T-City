-- tests/agent/lua/cases_client/agent_effects.lua — the agent effect channel, headless.
--
-- custom-agent-client is the one client surface a server agent drives directly,
-- so its contract is worth asserting without a player:
--   * nothing executes before the session handshake, and a foreign session id
--     is ignored (the client is not a general command bus)
--   * the handler table is literal: unknown action -> rejected ack, never a
--     forwarded event
--   * every outcome produces exactly one ack for the caller: ok / rejected /
--     failed with an error_code the server can sanitise
--   * cancel only clears what is active; it does not abort a running handler,
--     so a second (late) ack can follow - the server must dedupe on `settled`
--   * anim assets are assumed absent, so a timeout is a normal path

return {
    run = function(ctx)
        local env = ctx.bootstrap.Load({
            resource = '[custom]/custom-agent-client',
            files = { 'client/main.lua' },
        })

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

        local function acksFor(rid)
            local found = {}
            for _, record in ipairs(env.server_events) do
                if record.name == 'tcity:agent:ack'
                    and type(record.args[1]) == 'table'
                    and record.args[1].request_id == rid then
                    found[#found + 1] = record.args[1]
                end
            end
            return found
        end

        local function exec(requestId, action, payload, session, version)
            env.Emit('tcity:agent:exec', {
                v = version or 1,
                session = session or 'session-A',
                request_id = requestId,
                action = action,
                timeout_ms = 4000,
                payload = payload or {},
            })
        end

        check('ready_is_announced_on_start', function()
            local announced = false
            for _, record in ipairs(env.server_events) do
                if record.name == 'tcity:agent:ready' then announced = true end
            end
            assert(announced, 'onClientResourceStart must send tcity:agent:ready')
        end)

        check('nothing_runs_before_the_handshake', function()
            exec('r0', 'send_notify', { text = 'boom', kind = 'error' })
            assert(#acksFor('r0') == 0, 'an exec before hello must be ignored')
            assert(#env.notifications == 0, 'no effect may run before the handshake')
        end)

        check('foreign_session_is_ignored', function()
            env.Emit('tcity:agent:hello', { v = 1, session = 'session-A' })
            exec('r1', 'send_notify', { text = 'stolen' }, 'session-B')
            assert(#acksFor('r1') == 0, 'a foreign session id must be dropped silently')
            assert(#env.notifications == 0, 'no effect may run for a foreign session')
        end)

        check('notify_executes_and_acks_ok', function()
            exec('r2', 'send_notify', { text = 'hello', kind = 'success' })
            local ack = acksFor('r2')[1]
            assert(ack ~= nil, 'a valid exec must be acknowledged')
            assert(ack.status == 'ok', 'status must be ok, got ' .. tostring(ack.status))
            assert(#env.notifications == 1 and env.notifications[1].text == 'hello',
                'the effect must actually run')
        end)

        check('unknown_action_is_rejected_not_forwarded', function()
            exec('r3', 'trigger_server_event', { name = 'QBCore:Server:GiveMoney' })
            local ack = acksFor('r3')[1]
            assert(ack ~= nil and ack.status == 'rejected', 'unknown action must be rejected')
            assert(ack.error_code == 'action_not_allowed', 'error_code must be action_not_allowed')
            local forwarded = false
            for _, record in ipairs(env.local_events) do
                if record.name == 'QBCore:Server:GiveMoney' then forwarded = true end
            end
            assert(not forwarded, 'the client must never forward an action as an event')
        end)

        check('malformed_envelopes_are_ignored', function()
            exec('r4', 'send_notify', { text = 'v2' }, 'session-A', 2)
            assert(#acksFor('r4') == 0, 'v ~= 1 must be ignored')
            env.Emit('tcity:agent:exec', { v = 1, session = 'session-A', action = 'send_notify' })
            assert(#acksFor('nil') == 0, 'a missing request_id must be ignored')
        end)

        check('anim_timeout_reports_failed_with_code', function()
            env.anim_load_delay = 5000 -- asset not resident: the normal case on a cold client
            exec('r5', 'play_anim', { dict = 'cellphone@', clip = 'cellphone_text_in', duration_ms = 800 })
            env.Step(1200) -- ANIM_LOAD_TIMEOUT_MS is 1000
            local ack = acksFor('r5')[1]
            assert(ack ~= nil, 'a timed-out handler must still ack')
            assert(ack.status == 'failed', 'status must be failed, got ' .. tostring(ack.status))
            assert(ack.error_code == 'anim_load_timeout', 'error_code must name the timeout')
        end)

        check('teleport_keeps_the_player_in_the_vehicle', function()
            env.vehicle = 900
            exec('r6', 'teleport', { x = 100.0, y = 200.0, z = 30.0, heading = 90.0 })
            local ack = acksFor('r6')[1]
            assert(ack ~= nil and ack.status == 'ok', 'teleport must succeed')
            assert(env.coords_log[1] ~= nil and env.coords_log[1].mode == 'keep_vehicle',
                'teleport inside a vehicle must use SetPedCoordsKeepVehicle')
            env.vehicle = 0
        end)

        check('help_text_effect_takes_no_focus', function()
            exec('r7', 'open_text_ui', { title = 'T', body = 'B', timeout_ms = 4000 })
            local ack = acksFor('r7')[1]
            assert(ack ~= nil and ack.status == 'ok', 'help text must ack ok')
            assert(env.help_text.shown == true, 'help text must be displayed natively')
            assert(#env.nui.calls == 0, 'open_text_ui must never take NUI focus')
        end)

        check('cancel_acks_but_does_not_abort_the_handler', function()
            env.anim_load_delay = 5000
            exec('r8', 'play_anim', { dict = 'slow@', clip = 'slow_clip', duration_ms = 500 })
            env.Emit('tcity:agent:cancel', { v = 1, session = 'session-A', request_id = 'r8' })
            local first = acksFor('r8')[1]
            assert(first ~= nil and first.status == 'cancelled', 'cancel must ack cancelled')
            assert(env.clear_ped_tasks_calls > 0, 'cancel must clear what is playing')
            env.Step(1200)
            local acks = acksFor('r8')
            assert(#acks == 2 and acks[2].status == 'failed',
                'the running handler still acks after cancel: the server must dedupe on settled')
        end)

        check('no_unmodelled_native_was_called', function()
            assert(#env.thread_errors == 0,
                'client threads raised: ' .. table.concat(env.thread_errors, ' | '))
        end)

        check('phone_change_event_pushes_one_coalesced_snapshot', function()
            -- 手机只广播"变了"；快照由本资源自己采集后推给服务端。
            -- 150ms 内连续多次变化只推最终态：换形态是"先关再开"，
            -- 若两次都推，服务端 250ms 窗口会把真正的终态丢掉。
            local function pushes()
                local n = 0
                for _, record in ipairs(env.server_events) do
                    if record.name == 'tcity:agent:state' then n = n + 1 end
                end
                return n
            end

            local before = pushes()
            env.Emit('phone:client:stateChanged')
            env.Step(200)
            assert(pushes() == before + 1, 'one change must produce one push, got '
                .. tostring(pushes() - before))

            local afterFirst = pushes()
            env.Emit('phone:client:stateChanged')
            env.Step(50)
            env.Emit('phone:client:stateChanged')
            env.Step(200)
            assert(pushes() == afterFirst + 1, 'two changes inside 150ms must coalesce into one push, got '
                .. tostring(pushes() - afterFirst))
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
        }
    end,
}
