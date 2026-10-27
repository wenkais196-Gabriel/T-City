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
                'client/core/nav.lua',
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

        check('keyboard_uses_raw_keys_not_control_ids', function()
            -- 玩家真按方向键时 GTA 不会把它落到 172-175 那组手机控制上（keepInput 下轮询
            -- 不到），只有 agent 注入的按键才会进 CEF —— 不读原始按键就是"agent 能用
            -- 键盘、人不能用"。
            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)

            local function navs()
                local out = {}
                for _, record in ipairs(env.nui_messages) do
                    local msg = record.msg or {}
                    if msg.action == 'phone:nav' then out[#out + 1] = msg end
                end
                return out
            end

            local function press(vk)
                env.raw_keys[vk] = true
                env.Step(16)
                env.raw_keys[vk] = nil
                env.Step(16)
            end

            press(0x28) -- ArrowDown
            local moves = 0
            for _, msg in ipairs(navs()) do
                if msg.kind == 'move' and msg.dir == 'down' then moves = moves + 1 end
            end
            assert(moves == 1, 'one hardware press emits exactly one move, got ' .. tostring(moves))

            press(0x0D) -- Enter
            press(0x08) -- Backspace
            press(0x22) -- PageDown
            press(0x23) -- End

            local acts, backs, paged, edge = 0, 0, false, false
            for _, msg in ipairs(navs()) do
                if msg.kind == 'activate' then acts = acts + 1 end
                if msg.kind == 'back' then backs = backs + 1 end
                if msg.kind == 'page' and msg.dir == 'down' then paged = true end
                if msg.kind == 'edge' and msg.dir == 'last' then edge = true end
            end
            assert(acts == 1, 'Enter emits one activate, got ' .. tostring(acts))
            assert(backs == 1, 'Backspace emits one back, got ' .. tostring(backs))
            assert(paged, 'PageDown emits page/down')
            assert(edge, 'End emits edge/last')

            -- 下一条用例断言"任何输入之前没有 nav 消息"，这里把记录清干净
            env.nui_messages = {}
        end)

        check('focus_hint_tells_the_agent_what_is_selected', function()
            -- agent 看不见 DOM：没有这条只能盲按方向键（真机踩过：Tab 直接落在
            -- "分享"上，想输的样子完全对不上）。
            local state = env.registered_exports.GetUiState
            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)
            env.NuiCallback('uiFocus', { label = 'Search contacts...' })
            env.Step(20)
            assert(state().focus == 'Search contacts...', 'focus label must round-trip')

            env.NuiCallback('uiFocus', { label = '   ' })
            env.Step(20)
            assert(state().focus == nil, 'blank labels are not a focus')

            env.NuiCallback('uiFocus', { label = '任务' })
            env.Step(20)
            assert(state().focus == '任务', 'CJK labels must survive')

            env.Command('phonefix')
            env.Step(100)
            assert(state().focus == nil, 'closing must clear the focus hint')
        end)

        check('switching_surface_keeps_the_page', function()
            -- 换形态不是退出：人还看着同一页，appState 不该被清掉，
            -- 否则 agent 在 /tablet 之后立刻读成 app=nil（真机踩过）。
            local state = env.registered_exports.GetUiState
            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)
            env.NuiCallback('appState', { app = 'quests', tab = 'active', selected = 'cold_chain_delivery' })
            env.Step(20)

            -- 换形态时重开必须带 reason='switch'：NUI 靠它决定回桌面还是留页。
            local reopenReason = nil
            for _, record in ipairs(env.nui_messages) do
                local msg = record.msg or {}
                if msg.action == 'phone:open' then reopenReason = msg.reason end
            end
            assert(reopenReason ~= 'command', 'the reopen after a switch must not look like a fresh command')

            env.Command('tablet')
            env.Step(400)
            local after = state()
            for _, record in ipairs(env.nui_messages) do
                local msg = record.msg or {}
                if msg.action == 'phone:open' then reopenReason = msg.reason end
            end
            assert(reopenReason == 'switch', 'the reopen must carry reason=switch, got ' .. tostring(reopenReason))
            assert(after.surface == 'tablet', 'surface must switch, got ' .. tostring(after.surface))
            assert(type(after.app) == 'table', 'the app page must survive a surface switch')
            assert(after.app.id == 'quests' and after.app.tab == 'active',
                'id/tab must survive, got ' .. tostring(after.app.id) .. '/' .. tostring(after.app.tab))

            -- 真正的关闭仍然清空
            env.Command('phonefix')
            env.Step(100)
            assert(state().app == nil, 'a hard reset must clear the page')
        end)

        check('keyboard_and_gamepad_navigation_reaches_the_nui', function()
            -- 浏览器原生 Tab 在游戏里拿不到键（GTA 占了），所以方向/确认/返回由 Lua
            -- 轮询控制后发给 NUI；同一套动作键盘与手柄共用。
            local function navs()
                local out = {}
                for _, record in ipairs(env.nui_messages) do
                    local msg = record.msg or {}
                    if msg.action == 'phone:nav' then out[#out + 1] = msg end
                end
                return out
            end

            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)
            assert(#navs() == 0, 'no nav messages before any input')

            env.controls_pressed[173] = true -- down
            env.Step(40)
            env.controls_pressed[176] = true -- accept
            env.Step(40)
            env.controls_pressed[177] = true -- cancel
            env.Step(40)

            local seen = navs()
            assert(#seen == 3, 'expected move/activate/back, got ' .. tostring(#seen))
            assert(seen[1].kind == 'move' and seen[1].dir == 'down', 'first is a down move')
            assert(seen[2].kind == 'activate', 'second is activate')
            assert(seen[3].kind == 'back', 'third is back')

            -- 关屏后必须停止轮询：否则会继续吞方向键
            env.Command('phonefix')
            env.Step(100)
            local before = #navs()
            env.controls_pressed[173] = true
            env.Step(60)
            assert(#navs() == before, 'closed phone must not emit nav messages')
        end)

        check('phoneui_is_off_by_default', function()
            -- 真机 OS 光标被 GTA 锁在屏幕角上（SetCursorPos 无效），合成点击进不了手机，
            -- 所以 agent 用消息导航；但这条命令必须在生产默认关闭。
            -- 打开后的行为由 NUI 场景证明（phone:navigate → 任务 App）。
            local function navigations()
                local n = 0
                for _, record in ipairs(env.nui_messages) do
                    local msg = record.msg or {}
                    if msg.action == 'phone:navigate' then n = n + 1 end
                end
                return n
            end

            env.Command('phonefix')
            env.Step(100)
            env.Command('phone')
            env.Step(200)

            env.Command('phoneui', 'quests')
            env.Step(50)
            assert(navigations() == 0, 'convar off: /phoneui must do nothing')

            env.Command('phoneui', '../etc/passwd')
            env.Step(50)
            assert(navigations() == 0, 'convar off: nothing may reach NUI, whatever the argument')
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
