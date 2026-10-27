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
                -- 形态判定 → 移动锁 → 状态（fxmanifest 里也必须在 main.lua 之前）
                'client/core/surface_rules.lua',
                'client/core/device_lock.lua',
                'client/core/surface.lua',
                'client/core/events.lua',
                'client/core/diag.lua',
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

        check('every_ui_change_announces_itself', function()
            -- 探针以前只靠 5s 心跳，按完 M 读到的还是旧值；现在开关/换页都会广播一次
            -- （事件无参数，只表示"变了，来取一份"）。
            local function announcements()
                local n = 0
                for _, record in ipairs(env.local_events) do
                    if record.name == 'phone:client:stateChanged' then n = n + 1 end
                end
                return n
            end

            env.Command('phonefix')
            env.Step(100)
            local base = announcements()

            env.Command('phone')
            env.Step(200)
            assert(announcements() > base, 'opening the phone must announce the change')

            local afterOpen = announcements()
            env.NuiCallback('appState', { app = 'quests', tab = 'active' })
            env.Step(20)
            assert(announcements() > afterOpen, 'switching pages must announce the change')

            local afterPage = announcements()
            env.Command('phonefix')
            env.Step(100)
            assert(announcements() > afterPage, 'closing the phone must announce the change')
        end)

        check('app_state_is_reported_and_sanitised', function()
            -- agent 问不到"他在看哪一栏"，除非 App 自己回吐。只收三个短 token。
            local state = env.registered_exports.GetUiState
            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)

            env.NuiCallback('appState', { app = 'quests', tab = 'active', selected = 'euro_trucking_steel' })
            env.Step(20)
            local reported = state().app
            assert(type(reported) == 'table', 'app state must reach the snapshot')
            assert(reported.id == 'quests', tostring(reported.id))
            assert(reported.tab == 'active', tostring(reported.tab))
            assert(reported.selected == 'euro_trucking_steel', tostring(reported.selected))

            env.NuiCallback('appState', { app = 'quests', tab = 'bad value!', selected = '<script>' })
            env.Step(20)
            local cleaned = state().app
            assert(cleaned.id == 'quests', 'a valid app id survives')
            assert(cleaned.tab == nil, 'a tab with spaces/punctuation is dropped, got ' .. tostring(cleaned.tab))
            assert(cleaned.selected == nil, 'a selected id with markup is dropped')

            env.Command('phonefix')
            env.Step(100)
            assert(state().app == nil, 'closing the phone must clear the app state')
        end)

        check('m_still_closes_when_the_focus_native_lies', function()
            -- 实机现象：IsNuiFocused() 恒 false。旧的 toggle 拿它当"焦点还在吗"，
            -- 于是第二次按 M 走的是"复位重开"分支 —— 手机永远关不掉、界面还闪。
            local state = env.registered_exports.GetUiState
            env.Command('phonefix')
            env.Step(100)
            env.nui.focus_native_lies = true

            env.Command('phone')
            env.Step(200)
            local opened = state()
            assert(opened.open == true, 'the first press must still open the phone')
            assert(opened.focused == true, 'focused reports what the phone holds, not the native')
            assert(opened.nui_focus_native == false, 'the lying native is reported as-is, separately')

            env.Step(400) -- 越过 300ms 去抖
            env.Command('phone')
            env.Step(200)
            local closed = state()
            assert(closed.open == false, 'a second press must close the phone even when the native lies')
            assert(closed.surface == nil, 'surface must clear on close')
            assert(env.nui.focused == false, 'NUI focus must be released')
        end)

        check('ui_state_export_reports_what_the_agent_needs', function()
            -- agent 的客户端状态探测先取这个导出：它只能回答"开着吗/哪一面/焦点归谁"，
            -- 不能带任何正文或玩家输入。
            local state = env.registered_exports and env.registered_exports.GetUiState
            assert(type(state) == 'function', 'custom-phone must export GetUiState')
            -- 前面的用例可能已经把手机开着：先 hard reset，再按一次，避免测到"关闭"。
            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)
            local snapshot = state()
            assert(type(snapshot) == 'table', 'GetUiState must return a table')
            assert(snapshot.open == true, 'an open phone must report open=true')
            assert(snapshot.surface == 'phone', 'surface must be the bound one, got ' .. tostring(snapshot.surface))
            assert(snapshot.focus_owner == 'phone', 'focus owner must be the phone, got ' .. tostring(snapshot.focus_owner))
            -- 关闭走 phonefix：它一定会 Release + Reset，不依赖 toggle 时的焦点判定
            env.Command('phonefix')
            env.Step(100)
            local after = state()
            assert(after.open == false, 'a closed phone must report open=false')
            assert(after.surface == nil, 'surface must clear on close, got ' .. tostring(after.surface))
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results, resumes = env.resumes },
        }
    end,
}
