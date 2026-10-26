-- tests/agent/lua/cases_client/phone_focus.lua — custom-phone client, headless.
--
-- These are the invariants that used to cost a real client session per bug:
--   * open grants focus AND keeps movement input (WASD never freezes)
--   * movement controls (30-35) are never disabled, look/attack are
--   * close releases focus, and the release is verified, not assumed
--   * an incoming call opens the phone by itself (audit B04)
--   * NUI callbacks proxy to server callbacks, and a missing callback is
--     observable instead of a silent hang
--   * onResourceStop never leaves the game without input

return {
    run = function(ctx)
        local env = ctx.bootstrap.Load({
            resource = '[custom]/custom-phone',
            -- Manifest order (client_scripts): core modules, then main.
            files = {
                'config.lua',
                'client/core/bridge.lua',
                'client/core/focus.lua',
                'client/core/events.lua',
                'client/main.lua',
            },
            export_overrides = {
                -- custom-ui is the shared focus helper every menu uses.
                ['custom-ui'] = {
                    CloseMenu = function()
                        SetNuiFocus(false, false)
                    end,
                    OpenMenu = function(opts)
                        SetNuiFocus(true, true)
                        if opts and opts.keepInput then SetNuiFocusKeepInput(true) end
                    end,
                },
            },
            server_callbacks = {
                ['phone:server:getPhoneData'] = function()
                    return { success = true, playerData = { money = { cash = 42, bank = 7 } } }
                end,
            },
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

        check('startup_leaves_input_untouched', function()
            assert(env.nui.focused == false, 'focus must be off at load')
            assert(env.nui.keepInput == false, 'keepInput must be off at load')
            assert(env.key_mappings['phone'] ~= nil, 'phone key mapping must be registered')
            assert(env.key_mappings['phone'].key == Config.OpenKey, 'key must follow config.lua')
        end)

        check('open_grants_cursor_and_keeps_movement', function()
            env.Command('phone')
            env.Step(200)
            assert(env.nui.focused == true, 'focus must be granted')
            assert(env.nui.cursor == true, 'cursor must be granted (phone is clickable)')
            assert(env.nui.keepInput == true, 'keepInput must stay on so WASD works')
            local actions = env.NuiActions()
            assert(env.Count(actions, 'phone:open') == 1, 'exactly one phone:open')
            assert(env.Count(actions, 'phone:updateTime') >= 1, 'clock/weather pushed on open')
        end)

        check('loop_disables_look_and_attack_but_not_movement', function()
            env.Step(200)
            for _, control in ipairs({ 1, 2, 3, 4, 5, 6, 24, 25, 37, 44 }) do
                assert(env.disabled_controls[control] == true,
                    ('control %d must be disabled while the phone is open'):format(control))
            end
            for _, control in ipairs({ 30, 31, 32, 33, 34, 35 }) do
                assert(env.disabled_controls[control] == nil,
                    ('movement control %d must NEVER be disabled'):format(control))
            end
        end)

        check('focus_watchdog_is_bounded', function()
            -- 5 reassert attempts, one native call each, plus the initial grant.
            local calls = #env.nui.calls
            assert(calls >= 2 and calls <= 8,
                ('focus calls must stay bounded, saw %d'):format(calls))
            local reasserts = 0
            for _, record in ipairs(env.server_events) do
                if record.name == 'phone:server:focusState'
                    and type(record.args[1]) == 'table'
                    and record.args[1].phase == 'reassert' then
                    reasserts = reasserts + 1
                end
            end
            assert(reasserts >= 1 and reasserts <= 5,
                ('reassert telemetry must be bounded, saw %d'):format(reasserts))
        end)

        check('open_loop_costs_one_tick_per_frame', function()
            local before = env.resumes
            env.Step(1000)
            local ticks = env.resumes - before
            assert(ticks >= 900, ('the open loop must poll per frame, saw %d ticks'):format(ticks))
            assert(ticks <= 2000, ('per-frame loop must not fan out, saw %d ticks'):format(ticks))
        end)

        check('right_click_closes_and_releases_focus', function()
            env.controls_pressed[25] = true -- INPUT_AIM
            env.Step(50)
            assert(env.nui.focused == false, 'close must release NUI focus')
            local actions = env.NuiActions()
            assert(env.Count(actions, 'phone:close') == 1, 'NUI must be told to close')
            local phases = {}
            for _, record in ipairs(env.server_events) do
                if record.name == 'phone:server:focusState' and type(record.args[1]) == 'table' then
                    phases[#phases + 1] = record.args[1].phase
                end
            end
            assert(#phases >= 2, 'close must emit close-start and a verified close')
            assert(env.thread_errors[1] == nil, 'close must not raise: ' .. tostring(env.thread_errors[1]))
            -- the 80ms verification repass must not re-grab focus
            env.Step(200)
            assert(env.nui.focused == false, 'close must not bounce back to focused')
        end)

        check('incoming_call_opens_a_closed_phone', function()
            assert(env.nui.focused == false, 'precondition: phone is closed')
            env.Emit('phone:client:incomingCall', { callId = 'call-1', from = '555' })
            env.Step(100)
            assert(env.nui.focused == true, 'incoming call must open the phone (audit B04)')
            assert(env.Count(env.NuiActions(), 'phone:incomingCall') == 1, 'call UI must be pushed once')
        end)

        check('nui_callback_proxies_server_callback', function()
            local result = env.NuiCallback('getPhoneData')
            assert(result.called == true, 'NUI callback must answer')
            assert(result.payload.playerData.money.cash == 42, 'payload must be forwarded unchanged')
            assert(#env.missing_callbacks == 0, 'no callback may be missing')
        end)

        check('missing_server_callback_is_observable', function()
            local result = env.NuiCallback('getMessages', { before_id = nil })
            assert(result.called == false, 'an unregistered server callback cannot answer')
            assert(env.missing_callbacks[1] == 'phone:server:getMessages',
                'the hang must be recorded, not swallowed')
        end)

        check('gps_bus_updates_waypoint_and_state_bag', function()
            env.Emit('phone:client:routeGps', { x = 1200.5, y = -800.25, z = 30.0 }, 'Depot 3')
            assert(env.waypoint ~= nil and env.waypoint.x == 1200.5, 'waypoint must be set')
            assert(LocalPlayer.state.activeGpsX == 1200.5, 'state bag mirrors the waypoint')
            assert(LocalPlayer.state.activeGpsLabel == 'Depot 3', 'label must be mirrored')
        end)

        check('resource_stop_releases_focus_and_input', function()
            env.StopResource()
            assert(env.nui.focused == false, 'stop must release focus')
            assert(env.nui.keepInput == false, 'stop must not leave keepInput pinned')
        end)

        check('no_unmodelled_native_was_called', function()
            assert(#env.thread_errors == 0,
                'client threads raised: ' .. table.concat(env.thread_errors, ' | '))
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results, resumes = env.resumes },
        }
    end,
}
