-- 输入路径（栈）：世界 → 手机 → App → 输入框，Esc 每次返回一层。
return {
    name = 'input_path',
    run = function(ctx)
        local results = {}
        local failed = 0
        local function check(name, fn)
            local ok, err = pcall(fn)
            results[#results + 1] = { name = name, ok = ok, error = (not ok) and tostring(err) or nil }
            if not ok then failed = failed + 1 end
        end

        local env = ctx.bootstrap.Load({
            resource = '[custom]/custom-ui',
            files = { 'client/main.lua' },
        })
        local Input = {
            Push = env.registered_exports.Push,
            Pop = env.registered_exports.Pop,
            Top = env.registered_exports.Top,
            Path = env.registered_exports.Path,
            IsTaken = env.registered_exports.IsTaken,
            Owns = env.registered_exports.Owns,
            Reset = env.registered_exports.ResetInput,
            IsMenuOpen = env.registered_exports.IsMenuOpen,
        }

        check('nothing_taken_by_default', function()
            assert(Input.IsTaken() == false, 'an untouched client has no UI on top')
            assert(Input.Top() == nil, 'no top frame')
            assert(Input.IsMenuOpen() == false, 'legacy flag stays false')
        end)

        check('push_and_pop_walk_the_path', function()
            assert(Input.Push({ id = 'phone' }) == true, 'phone frame')
            assert(Input.Push({ id = 'phone:mdt' }) == true, 'app frame')
            assert(Input.Push({ id = 'phone:mdt/search', kind = 'text' }) == true, 'text frame')
            env.Step(10)
            local path = Input.Path()
            assert(#path == 3, 'three frames, got ' .. #path)
            assert(path[1] == 'phone' and path[2] == 'phone:mdt' and path[3] == 'phone:mdt/search',
                'path order is bottom -> top')
            assert(Input.Owns('phone:mdt/search'), 'top owns only itself, not the app')
            assert(not Input.Owns('phone'), 'the shell does not own while a child is on top')

            -- Esc 一次退一层
            assert(Input.Pop() == 'phone:mdt/search', 'first pop is the text frame')
            assert(#Input.Path() == 2, 'back to the app')
            assert(Input.Pop('phone:mdt') == 'phone:mdt', 'pop by id')
            assert(#Input.Path() == 1, 'back to the phone')
            assert(Input.Owns('phone'), 'phone owns again')
            assert(Input.Pop() == 'phone', 'closing the phone pops the last frame')
            assert(Input.IsTaken() == false, 'input goes back to the game')
        end)

        check('opening_the_same_frame_twice_is_idempotent', function()
            Input.Push({ id = 'phone' })
            Input.Push({ id = 'phone' })
            assert(#Input.Path() == 1, 'no nesting for the same id')
            Input.Push({ id = 'phone:mdt' })
            Input.Push({ id = 'phone' })
            assert(#Input.Path() == 1, 'reopening an ancestor collapses back to it')
            Input.Reset()
        end)

        check('top_frame_decides_the_control_whitelist', function()
            -- 定点黑名单：允许的控制根本不会被禁（比"全禁再放开"省，
            -- DisableAllControlActions 每帧遍历几百个控制，实机会卡）。
            Input.Reset()
            env.disabled_controls = {}
            Input.Push({ id = 'phone', allow = { 30, 31 } })
            env.Step(20)
            assert(Input.Top().id == 'phone', 'phone on top')
            assert(env.disabled_controls[30] == nil, 'walk controls must stay usable')
            assert(env.disabled_controls[31] == nil, 'walk controls must stay usable')
            assert(env.disabled_controls[24] == true, 'attack is blocked while the UI is up')
            assert(env.disabled_controls[174] == true, 'the phone menu group is blocked')

            -- 上层换了，白名单也要跟着换
            env.disabled_controls = {}
            Input.Push({ id = 'phone:mdt', allow = { 27 } })
            env.Step(20)
            assert(env.disabled_controls[27] == nil, 'the new top frame brings its own allow list')
            assert(env.disabled_controls[30] == true, 'walking is blocked when not allowed')
            Input.Reset()
        end)

        check('reset_returns_input_to_the_game', function()
            Input.Push({ id = 'phone' })
            Input.Push({ id = 'phone:mdt' })
            Input.Reset()
            assert(Input.IsTaken() == false, 'reset clears every frame')
            assert(#Input.Path() == 0, 'empty path')
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
        }
    end,
}
