-- tests/agent/lua/stubs/fivem.lua — minimal FiveM server runtime for the harness.
--
-- Everything is recorded on env (the _G.TCITY table). Timers are queued and
-- only run on an explicit env.Drain(), Wait() is a hard error, and client
-- events are recorded but never delivered.

return function(env)
    env.exports = env.exports or {}
    env.events = env.events or {}
    env.event_handlers = env.event_handlers or {}
    env.client_events = env.client_events or {}
    env.timers = env.timers or {}
    env.commands = env.commands or {}
    env.ace = env.ace or {}
    env.http_handlers = env.http_handlers or {}
    env.notifications = env.notifications or {}
    env.money_log = env.money_log or {}
    env.log = env.log or {}
    env.convars = env.convars or {}
    env.invoking_resource = env.invoking_resource

    local function exportObject(resource)
        if resource == 'qb-core' then
            return {
                GetCoreObject = function()
                    return env.qb
                end,
            }
        end
        return setmetatable({}, {
            __index = function(_, functionName)
                return function(_, ...)
                    env.log[#env.log + 1] = {
                        export = tostring(resource) .. ':' .. tostring(functionName),
                        args = { ... },
                    }
                    return true
                end
            end,
        })
    end

    -- exports(name, fn) *and* exports['qb-core']:GetCoreObject().
    local exportTable = setmetatable({}, {
        __call = function(_, name, fn)
            if type(name) == 'string' and type(fn) == 'function' then
                env.exports[name] = fn
            end
            return fn
        end,
        __index = function(_, name)
            return exportObject(name)
        end,
    })
    _G.exports = exportTable

    local function addHandler(name, handler)
        if type(name) ~= 'string' or type(handler) ~= 'function' then return end
        env.event_handlers[name] = env.event_handlers[name] or {}
        table.insert(env.event_handlers[name], handler)
    end

    function _G.AddEventHandler(name, handler)
        addHandler(name, handler)
    end

    function _G.RegisterNetEvent(name, handler)
        addHandler(name, handler)
    end

    function _G.TriggerEvent(name, ...)
        local handlers = env.event_handlers[name]
        if not handlers then return end
        local args = { ... }
        for _, handler in ipairs(handlers) do
            handler(table.unpack(args))
        end
    end

    function _G.TriggerClientEvent(name, target, ...)
        env.client_events[#env.client_events + 1] = {
            event = name,
            target = target,
            args = { ... },
        }
    end

    function _G.GetConvar(name, default)
        local value = env.convars[name]
        if value == nil then return default end
        return tostring(value)
    end

    function _G.SetConvar(name, value)
        env.convars[name] = value
    end

    local function queueTimer(delay, fn)
        env.timers[#env.timers + 1] = { delay = tonumber(delay) or 0, fn = fn }
        return #env.timers
    end

    function _G.SetTimeout(delay, fn)
        return queueTimer(delay, fn)
    end

    function _G.CreateThread(fn)
        return queueTimer(0, fn)
    end

    function _G.Wait()
        error('Wait() is not supported in the harness; use env.Drain()', 0)
    end

    function _G.SetHttpHandler(handler)
        env.http_handlers[#env.http_handlers + 1] = handler
        env.http_handler = handler
    end

    function _G.RegisterCommand(name, handler, restricted)
        env.commands[name] = { handler = handler, restricted = restricted }
    end

    function _G.IsPlayerAceAllowed(source, ace)
        return env.ace[tostring(source) .. ':' .. tostring(ace)] == true
            or env.ace[tostring(ace)] == true
    end

    function _G.GetInvokingResource()
        return env.invoking_resource
    end

    function _G.GetCurrentResourceName()
        return 'custom-director'
    end

    function _G.StopResource()
        return true
    end

    local function newPromise(executor)
        local state = 'pending'
        local value, failure

        local function resolve(result)
            if state ~= 'pending' then return end
            state = 'resolved'
            value = result
        end

        local function reject(reason)
            if state ~= 'pending' then return end
            state = 'rejected'
            failure = reason
        end

        local promise = {}

        function promise:next(handler)
            if state == 'resolved' and type(handler) == 'function' then
                local ok, result = pcall(handler, value)
                if ok then
                    value = result
                else
                    state, failure = 'rejected', result
                end
            end
            return self
        end

        function promise:await()
            if state == 'rejected' then error(failure, 0) end
            return value
        end

        function promise:resolve(result)
            resolve(result)
            return self
        end

        function promise:reject(reason)
            reject(reason)
            return self
        end

        local ok, err = pcall(executor, resolve, reject)
        if not ok then reject(err) end
        return promise
    end

    _G.promise = {
        new = newPromise,
        resolve = function(value)
            return newPromise(function(resolve) resolve(value) end)
        end,
        reject = function(reason)
            return newPromise(function(_, reject) reject(reason) end)
        end,
    }

    _G.Citizen = {
        CreateThread = _G.CreateThread,
        SetTimeout = _G.SetTimeout,
        Wait = _G.Wait,
        Await = function(value)
            if type(value) == 'table' and type(value.await) == 'function' then
                return value:await()
            end
            return value
        end,
    }

    function env.Drain(limit)
        local budget = tonumber(limit) or 1000
        local ran = 0
        while #env.timers > 0 and ran < budget do
            local timer = table.remove(env.timers, 1)
            ran = ran + 1
            timer.fn()
        end
        return ran
    end

    function env.ClearTimers()
        env.timers = {}
    end

    return env
end
