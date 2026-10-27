-- tests/agent/lua/stubs/client.lua — headless FiveM *client* runtime for the harness.
--
-- Why this exists: every client-side bug we hit (WASD frozen after close, a
-- visible phone without a cursor, an effect executed with no session, a NUI
-- card that never renders) came from one of five mechanisms. All five are
-- modelled here, so they can be asserted without a GPU, a game build or a
-- player:
--
--   1. coroutine scheduling + virtual clock   -> Wait()/CreateThread semantics
--   2. NUI focus state machine                -> SetNuiFocus / KeepInput
--   3. NUI message + callback channel         -> SendNUIMessage / RegisterNUICallback
--   4. net events (server -> client)          -> RegisterNetEvent
--   5. native availability / entity handles   -> nil-guards, anim load timeouts
--
-- Everything observable is recorded on env. A native that is *not* modelled
-- stays nil, so calling it raises "attempt to call a nil value" inside the
-- thread and lands in env.thread_errors — an unmodelled native is a finding,
-- not a silent pass.

return function(env)
    env.nui = env.nui or { focused = false, cursor = false, keepInput = false, calls = {} }
    env.nui_messages = env.nui_messages or {}
    env.nui_callbacks = env.nui_callbacks or {}
    env.net_handlers = env.net_handlers or {}
    env.event_handlers = env.event_handlers or {}
    env.commands = env.commands or {}
    env.key_mappings = env.key_mappings or {}
    env.server_events = env.server_events or {}
    env.local_events = env.local_events or {}
    env.convars = env.convars or {}
    env.executed_commands = env.executed_commands or {}
    env.notifications = env.notifications or {}
    env.log = env.log or {}
    env.console = env.console or {}
    env.server_callbacks = env.server_callbacks or {}
    env.missing_callbacks = env.missing_callbacks or {}
    env.threads = env.threads or {}
    env.thread_errors = env.thread_errors or {}
    env.disabled_controls = env.disabled_controls or {}
    env.controls_pressed = env.controls_pressed or {}
    env.raw_keys = env.raw_keys or {}
    env.anims_loaded = env.anims_loaded or {}
    env.effects = env.effects or {}
    env.help_text = env.help_text or {}
    env.coords_log = env.coords_log or {}
    env.clear_ped_tasks_calls = env.clear_ped_tasks_calls or 0
    env.now = env.now or 0
    env.resumes = env.resumes or 0
    env.resume_budget = env.resume_budget or 200000
    env.ped = env.ped or 500
    env.vehicle = env.vehicle or 0
    env.waypoint = env.waypoint
    env.anim = env.anim
    env.entity_coords = env.entity_coords or {}
    env.frame_ms = env.frame_ms or 1
    env.clock = env.clock or { hour = 12, minute = 0, dayOfWeek = 0 }

    local FRAME_MS = env.frame_ms

    -- ----------------------------------------------------------------------
    -- Scheduler: virtual clock, coroutine threads, Wait()
    -- ----------------------------------------------------------------------

    local function schedule(co, wake, label)
        env.threads[#env.threads + 1] = { co = co, wake = wake, label = label }
    end

    local function runDue()
        local ran = true
        while ran do
            ran = false
            for index = #env.threads, 1, -1 do
                local thread = env.threads[index]
                if thread.wake <= env.now then
                    table.remove(env.threads, index)
                    env.resumes = env.resumes + 1
                    if env.resumes > env.resume_budget then
                        error(('runaway client thread (%s): resume budget %d exceeded at t=%dms')
                            :format(thread.label or 'anonymous', env.resume_budget, env.now), 0)
                    end
                    env.current_thread = thread
                    local ok, err = coroutine.resume(thread.co)
                    env.current_thread = nil
                    if not ok then
                        env.thread_errors[#env.thread_errors + 1] = tostring(err)
                    elseif coroutine.status(thread.co) ~= 'dead' then
                        env.threads[#env.threads + 1] = thread
                    end
                    ran = true
                end
            end
        end
    end

    function env.Spawn(fn, delayMs, label)
        local co = coroutine.create(fn)
        schedule(co, env.now + (delayMs or 0), label)
        return co
    end

    function env.Step(ms)
        local target = env.now + (ms or 0)
        runDue()
        local guard = 0
        while true do
            guard = guard + 1
            if guard > 100000 then
                error('client scheduler: no progress during Step(' .. tostring(ms) .. ')', 0)
            end
            local next_wake
            for _, thread in ipairs(env.threads) do
                if thread.wake <= target and (next_wake == nil or thread.wake < next_wake) then
                    next_wake = thread.wake
                end
            end
            if not next_wake then break end
            if next_wake > env.now then env.now = next_wake end
            runDue()
        end
        if target > env.now then env.now = target end
        return env.now
    end

    local function dispatchInto(list, args, label)
        for _, handler in ipairs(list or {}) do
            env.Spawn(function()
                handler(table.unpack(args, 1, args.n))
            end, 0, label)
        end
    end

    -- server -> client net event (RegisterNetEvent)
    function env.Emit(name, ...)
        local args = table.pack(...)
        dispatchInto(env.net_handlers[name], args, 'net:' .. tostring(name))
        -- legacy shape: RegisterNetEvent(name) + AddEventHandler(name, fn)
        dispatchInto(env.event_handlers[name], args, 'net:' .. tostring(name))
        -- 在一个线程里触发事件时不能重入调度：runDue() 会切走/切回当前协程，
        -- 把 env.current_thread 清掉，随后外层线程调用 Wait 就会报
        -- "Wait() called outside a client thread"。真机上事件是排队投递的，
        -- 所以这里只入队，交给外层调度。
        if env.current_thread then return end
        runDue()
    end

    -- client-local event (AddEventHandler + TriggerEvent)
    function env.EmitLocal(name, ...)
        local args = table.pack(...)
        dispatchInto(env.event_handlers[name], args, 'local:' .. tostring(name))
        if env.current_thread then return end
        runDue()
    end

    function env.StartResource()
        env.EmitLocal('onClientResourceStart', env.resource_name)
    end

    function env.StopResource()
        env.EmitLocal('onResourceStop', env.resource_name)
    end

    function env.Command(name, ...)
        local handler = env.commands[name]
        if not handler then error(('no client command registered: %s'):format(name), 0) end
        local args = table.pack(...)
        env.Spawn(function()
            handler(0, table.unpack(args, 1, args.n))
        end, 0, 'command:' .. name)
        runDue()
        return true
    end

    function env.NuiCallback(name, data)
        local handler = env.nui_callbacks[name]
        if not handler then error(('no NUI callback registered: %s'):format(name), 0) end
        local result = { called = false }
        local function respond(payload)
            result.called = true
            result.payload = payload
        end
        env.Spawn(function()
            handler(data, respond)
        end, 0, 'nui:' .. name)
        runDue()
        return result
    end

    function env.NuiActions()
        local actions = {}
        for _, record in ipairs(env.nui_messages) do
            actions[#actions + 1] = record.msg and (record.msg.action or record.msg.type) or '?'
        end
        return actions
    end

    function env.Count(actions, wanted)
        local total = 0
        for _, action in ipairs(actions) do
            if action == wanted then total = total + 1 end
        end
        return total
    end

    function _G.Wait(ms)
        local thread = env.current_thread
        if not thread then error('Wait() called outside a client thread', 0) end
        local delta = ms
        if delta == nil or delta == 0 then delta = FRAME_MS end
        thread.wake = env.now + delta
        coroutine.yield()
    end

    -- ----------------------------------------------------------------------
    -- Threads / timers
    -- ----------------------------------------------------------------------

    function _G.CreateThread(fn) return env.Spawn(fn, 0, 'thread') end
    function _G.CitizenThread(fn) return env.Spawn(fn, 0, 'thread') end
    function _G.SetTimeout(ms, fn) return env.Spawn(fn, ms or 0, 'timeout') end

    _G.Citizen = {
        Wait = _G.Wait,
        CreateThread = _G.CreateThread,
        SetTimeout = _G.SetTimeout,
        InvokeNative = function() end,
    }

    -- ----------------------------------------------------------------------
    -- NUI channel
    -- ----------------------------------------------------------------------

    function _G.SetNuiFocus(hasFocus, hasCursor)
        hasFocus = hasFocus and true or false
        hasCursor = hasCursor and true or false
        env.nui.calls[#env.nui.calls + 1] = { at = env.now, focus = hasFocus, cursor = hasCursor }
        env.nui.focused = hasFocus
        env.nui.cursor = hasCursor
    end

    function _G.SetNuiFocusKeepInput(keep)
        env.nui.keepInput = keep and true or false
        env.nui.keepInputCalls = (env.nui.keepInputCalls or 0) + 1
    end

    -- 真机上这两个原生会撒谎（恒 false，见 nui-debug-playbook），桩要能复现：
    -- 置 env.nui.focus_native_lies = true 后引擎口径与真实焦点脱钩。
    function _G.IsNuiFocused()
        if env.nui.focus_native_lies then return false end
        return env.nui.focused
    end
    function _G.IsNuiFocusKeepingInput()
        if env.nui.focus_native_lies then return false end
        return env.nui.keepInput
    end

    -- 客户端也能读 convar（/phoneui、devcmd 桥都靠它门控）。
    -- 以前客户端桩没有这个全局：调用即 nil，用例"convar 关闭时什么都不做"因此
    -- 是靠崩溃通过的，看起来绿。
    function _G.GetConvar(name, default)
        local value = env.convars[name]
        if value == nil then return default end
        return tostring(value)
    end

    -- 客户端控制台命令（custom-agent-client 的 devcmd 桥用）
    function _G.ExecuteCommand(command)
        env.executed_commands = env.executed_commands or {}
        env.executed_commands[#env.executed_commands + 1] = command
    end

    function _G.SendNUIMessage(message)
        env.nui_messages[#env.nui_messages + 1] = { at = env.now, msg = message }
    end

    function _G.RegisterNUICallback(name, handler)
        env.nui_callbacks[name] = handler
    end

    function _G.RegisterRawNuiCallback(name, handler)
        env.nui_callbacks[name] = handler
    end

    -- ----------------------------------------------------------------------
    -- Events
    -- ----------------------------------------------------------------------

    function _G.RegisterNetEvent(name, handler)
        env.net_handlers[name] = env.net_handlers[name] or {}
        if handler then
            table.insert(env.net_handlers[name], handler)
        end
    end

    function _G.AddEventHandler(name, handler)
        env.event_handlers[name] = env.event_handlers[name] or {}
        table.insert(env.event_handlers[name], handler)
    end

    function _G.RemoveEventHandler() end

    function _G.TriggerServerEvent(name, ...)
        env.server_events[#env.server_events + 1] = { at = env.now, name = name, args = { ... } }
    end

    function _G.TriggerEvent(name, ...)
        env.local_events[#env.local_events + 1] = { at = env.now, name = name, args = { ... } }
        env.Emit(name, ...)
    end

    function _G.RegisterCommand(name, handler, restricted)
        env.commands[name] = handler
        env.command_restricted = env.command_restricted or {}
        env.command_restricted[name] = restricted and true or false
    end

    function _G.RegisterKeyMapping(command, description, inputGroup, key)
        env.key_mappings[command] = {
            description = description, group = inputGroup, key = key,
        }
    end

    function _G.GetCurrentResourceName() return env.resource_name or 'unknown' end

    -- ----------------------------------------------------------------------
    -- Natives used by our client files
    -- ----------------------------------------------------------------------

    function _G.GetGameTimer() return env.now end
    function _G.PlayerPedId() return env.ped end
    function _G.PlayerId() return 1 end
    function _G.GetPlayerPed() return env.ped end
    function _G.DoesEntityExist() return true end
    function _G.GetEntityCoords(entity)
        local coords = env.entity_coords[entity] or env.entity_coords.default
        if coords then return coords end
        return _G.vector3(0.0, 0.0, 0.0)
    end
    function _G.GetEntitySpeed() return 0.0 end
    function _G.GetEntityHeading() return 0.0 end
    function _G.GetVehiclePedIsIn() return env.vehicle or 0 end
    -- 状态探针用到的原生（custom-agent-client 的 collectState）：
    -- 以前没桩，pcall 吞掉错误 => 探针在 harness 里从来没被真正执行过。
    if rawget(_G, 'GetVehicleClass') == nil then
        function _G.GetVehicleClass() return env.vehicle_class or 0 end
    end
    if rawget(_G, 'GetEntityHealth') == nil then
        function _G.GetEntityHealth() return env.ped_health or 200 end
    end
    if rawget(_G, 'IsEntityDead') == nil then
        function _G.IsEntityDead() return env.ped_dead == true end
    end
    if rawget(_G, 'GetActiveScreenResolution') == nil then
        function _G.GetActiveScreenResolution()
            return env.screen_w or 1920, env.screen_h or 1080
        end
    end

    function _G.SetPedCoordsKeepVehicle(ped, x, y, z)
        env.coords_log[#env.coords_log + 1] = { mode = 'keep_vehicle', x = x, y = y, z = z }
    end

    function _G.SetEntityCoords(ped, x, y, z)
        env.coords_log[#env.coords_log + 1] = { mode = 'teleport', x = x, y = y, z = z }
    end

    function _G.SetEntityHeading() end

    -- animation dictionary loading: env.anim_load_delay > 0 models a real
    -- client where the asset is not resident yet and the request can time out.
    function _G.RequestAnimDict(dict)
        if (env.anim_load_delay or 0) <= 0 then
            env.anims_loaded[dict] = true
            return
        end
        env.Spawn(function()
            Wait(env.anim_load_delay)
            env.anims_loaded[dict] = true
        end, 0, 'anim:' .. tostring(dict))
    end

    function _G.HasAnimDictLoaded(dict) return env.anims_loaded[dict] == true end
    function _G.HasAnimSetLoaded(dict) return env.anims_loaded[dict] == true end

    function _G.TaskPlayAnim(ped, dict, clip)
        env.anim = { ped = ped, dict = dict, clip = clip }
    end

    function _G.IsEntityPlayingAnim(ped, dict, clip)
        local anim = env.anim
        return anim ~= nil and anim.dict == dict and anim.clip == clip
    end

    function _G.ClearPedTasks()
        env.anim = nil
        env.clear_ped_tasks_calls = env.clear_ped_tasks_calls + 1
    end

    function _G.StopAnimTask()
        env.anim = nil
        env.clear_ped_tasks_calls = env.clear_ped_tasks_calls + 1
    end

    function _G.StartScreenEffect(name, duration, looped)
        env.effects[#env.effects + 1] = { name = name, duration = duration, looped = looped }
    end

    function _G.BeginTextCommandDisplayHelp() env.help_text.command = true end
    function _G.AddTextComponentSubstringPlayerName(text) env.help_text.text = text end
    function _G.EndTextCommandDisplayHelp(_, _, _, timeout)
        env.help_text.timeout = timeout
        env.help_text.shown = true
    end

    function _G.SetNewWaypoint(x, y) env.waypoint = { x = x, y = y } end
    function _G.SetWaypointOff() env.waypoint = nil end

    function _G.DisableControlAction(_, control) env.disabled_controls[control] = true end

    -- 原始按键（键盘）：按 VK 码判断，和 GTA 的控制映射无关 ——
    -- 玩家真按方向键时轮询不到控制号，只能靠这个（真机踩过）。
    function _G.IsRawKeyDown(vk) return env.raw_keys[vk] == true end

    function _G.IsDisabledControlJustPressed(_, control)
        if env.controls_pressed[control] then
            env.controls_pressed[control] = nil
            return true
        end
        return false
    end

    function _G.IsControlJustPressed(_, control)
        if env.controls_pressed[control] then
            env.controls_pressed[control] = nil
            return true
        end
        return false
    end

    function _G.GetClockHours() return env.clock.hour end
    function _G.GetClockMinutes() return env.clock.minute end
    function _G.GetClockDayOfWeek() return env.clock.dayOfWeek end
    function _G.GetLocalTime() return 2026, 10, 26, env.clock.hour, env.clock.minute, 0 end
    function _G.GetWeatherTypeTransition() return 916995460 end -- CLEAR

    function _G.GetGamePool() return {} end
    function _G.NetworkGetEntityFromNetworkId() return 0 end
    function _G.NetworkGetNetworkIdFromEntity() return 0 end

    -- vectors: the client files do `#(a - b)`, so __len must return a number.
    local function makeVector(x, y, z)
        return setmetatable({ x = x or 0.0, y = y or 0.0, z = z or 0.0 }, {
            __sub = function(a, b)
                return makeVector(a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0))
            end,
            __add = function(a, b)
                return makeVector(a.x + b.x, a.y + b.y, (a.z or 0.0) + (b.z or 0.0))
            end,
            __len = function(v)
                local z = v.z or 0.0
                return math.sqrt(v.x * v.x + v.y * v.y + z * z)
            end,
        })
    end

    _G.vector2 = function(x, y) return makeVector(x, y, 0.0) end
    _G.vector3 = function(x, y, z) return makeVector(x, y, z) end
    _G.vec3 = _G.vector3

    -- surface.lua reads the viewport to decide whether the tablet even fits.
    _G.GetActiveScreenResolution = function() return 1920, 1080 end
    _G.GetScreenResolution = function() return 1920, 1080 end
    -- surface.lua treats 'in a vehicle' as one of the intent signals.
    -- Default: on foot; a case can override env.ped_vehicle to flip it.
    _G.IsPedInAnyVehicle = function() return env.ped_vehicle == true end

    -- ----------------------------------------------------------------------
    -- exports / QBCore / LocalPlayer
    -- ----------------------------------------------------------------------

    env.export_overrides = env.export_overrides or {}

    local function exportObject(resource)
        return setmetatable({}, {
            __index = function(_, functionName)
                return function(_, ...)
                    if resource == 'qb-core' and functionName == 'GetCoreObject' then
                        return env.qb
                    end
                    if resource == 'core-framework' and functionName == 'LoadAnimDict' then
                        -- 复刻 core-framework/shared/util.lua：RequestAnimDict + 等到超时。
                        -- 桩不实现它，默认兜底会直接回 true，动画超时用例就永远看不到 failed。
                        local dict, timeoutMs = ...
                        if type(dict) ~= 'string' or dict == '' then return false end
                        if HasAnimDictLoaded(dict) then return true end
                        RequestAnimDict(dict)
                        local deadline = GetGameTimer() + (tonumber(timeoutMs) or 5000)
                        while not HasAnimDictLoaded(dict) do
                            if GetGameTimer() > deadline then return false end
                            Wait(10)
                        end
                        return true
                    end
                    local overrides = env.export_overrides[resource]
                    if type(overrides) == 'table' and type(overrides[functionName]) == 'function' then
                        return overrides[functionName](...)
                    end
                    env.log[#env.log + 1] = {
                        export = tostring(resource) .. ':' .. tostring(functionName),
                        args = { ... },
                    }
                    return true
                end
            end,
        })
    end

    _G.exports = setmetatable({}, {
        __index = function(_, resource)
            local object = exportObject(resource)
            rawset(_, resource, object)
            return object
        end,
        -- 真 FiveM 的 exports 是可调用的：exports('Name', fn) 注册、exports['res']:Name() 调用。
        -- 桩原来只实现了后者，于是任何 `exports('X', fn)` 都会 'attempt to call a table value'。
        __call = function(_, name, fn)
            if type(name) ~= 'string' or type(fn) ~= 'function' then return end
            env.registered_exports = env.registered_exports or {}
            env.registered_exports[name] = fn
        end,
    })

    env.qb = env.qb or {
        Functions = {
            Notify = function(text, kind, duration)
                env.notifications[#env.notifications + 1] = {
                    at = env.now, text = text, kind = kind, duration = duration,
                }
            end,
            -- Real signature: TriggerCallback(name, cb, ...). If no handler is
            -- registered the callback is never invoked, which is exactly the
            -- "NUI waits forever" failure mode we want to be able to assert.
            TriggerCallback = function(name, cb, ...)
                local handler = env.server_callbacks[name]
                if not handler then
                    env.missing_callbacks[#env.missing_callbacks + 1] = name
                    return
                end
                local ok, result = pcall(handler, ...)
                if not ok then
                    env.thread_errors[#env.thread_errors + 1] = 'callback ' .. name .. ': ' .. tostring(result)
                    return
                end
                cb(result)
            end,
            -- main.lua gates opening the phone on a loaded character (citizenid),
            -- so the stub must expose both the call and a resolved character.
            GetPlayerData = function() return env.qb.PlayerData end,
        },
        PlayerData = {
            citizenid = 'CID00001',
            money = { cash = 0, bank = 0 },
            metadata = {},
            job = { name = 'unemployed', grade = { level = 0 }, onduty = false },
        },
        Config = {},
        Shared = {},
    }

    local state = { values = {} }
    function state.set(self, key, value)
        self.values[key] = value
    end
    setmetatable(state, {
        __index = function(self, key)
            return rawget(self, 'values')[key]
        end,
    })
    _G.LocalPlayer = { state = state, Ped = env.ped }

    -- ----------------------------------------------------------------------
    -- Console: keep stdout valid JSON for the pytest driver.
    -- ----------------------------------------------------------------------

    _G.print = function(...)
        local parts = {}
        for index = 1, select('#', ...) do
            parts[index] = tostring(select(index, ...))
        end
        local line = table.concat(parts, '\t')
        env.console[#env.console + 1] = line
        io.stderr:write(line, '\n')
    end

    return env
end
