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
    env.resource_states = env.resource_states or {}
    env.peds = env.peds or {}
    env.entity_coords = env.entity_coords or {}
    env.entity_headings = env.entity_headings or {}
    env.entity_forward = env.entity_forward or {}
    env.created_entities = env.created_entities or {}
    env.vehicles = env.vehicles or {}
    env.vehicle_plates = env.vehicle_plates or {}
    env.vehicle_in_use = env.vehicle_in_use or {}
    env.entity_models = env.entity_models or {}
    env.deleted_entities = env.deleted_entities or {}
    env.hashes = env.hashes or {}
    env.player_buckets = env.player_buckets or {}
    env.next_entity_id = env.next_entity_id or 500
    env.entity_exists_override = env.entity_exists_override
    env.plate_readback_override = env.plate_readback_override
    env.now = env.now or 0
    env.invoking_resource = env.invoking_resource
    env.export_overrides = env.export_overrides or {}

    local function exportObject(resource)
        if resource == 'core-framework' then
            -- 限流 owner 迁到 core-framework 之后，效果通道每次派发都要过这个导出。
            -- 忠实复刻 core-framework/server/rate_limit.lua：首次调用就扣一个令牌，
            -- 拒绝时回 retry_after_ms（毫秒）。返回 true 的空壳会让 retry_after 断言
            -- 永远通过、限流本身不可测；直接挂在代理表上则要吞掉冒号调用传进来的 self。
            env.rate_buckets = env.rate_buckets or {}
            local core = exportObject('__core_framework_defaults')
            local function tokenBucket(...)
                local args = { ... }
                if type(args[1]) == 'table' then table.remove(args, 1) end
                local key, ratePerMinute, burst = args[1], args[2], args[3]
                if type(key) ~= 'string' or key == '' then return true, 0 end
                ratePerMinute = math.max(tonumber(ratePerMinute) or 0, 1)
                burst = math.max(tonumber(burst) or 1, 1)
                local now = type(env.now) == 'number' and env.now or 0
                local refillPerMs = ratePerMinute / 60000
                local bucket = env.rate_buckets[key]
                if not bucket then
                    env.rate_buckets[key] = { tokens = burst - 1, updatedAt = now }
                    return true, 0
                end
                local elapsed = math.max(0, now - (bucket.updatedAt or now))
                if elapsed > 0 then
                    bucket.tokens = math.min(burst, bucket.tokens + elapsed * refillPerMs)
                    bucket.updatedAt = now
                end
                if bucket.tokens < 1 then
                    return false, math.ceil((1 - bucket.tokens) / refillPerMs)
                end
                bucket.tokens = bucket.tokens - 1
                return true, 0
            end
            core.RateLimitTokenBucket = tokenBucket
            return core
        end
        if resource == 'qb-core' then
            return {
                GetCoreObject = function()
                    -- A real server hands out an independent object per call
                    -- (see cases/live_roster_refresh.lua); qb_provider lets a
                    -- case reproduce that instead of a single shared table.
                    if env.qb_provider then return env.qb_provider() end
                    return env.qb
                end,
            }
        end
        return setmetatable({}, {
            __index = function(_, functionName)
                return function(_, ...)
                    local overrides = env.export_overrides[resource]
                    if type(overrides) == 'table' and type(overrides[functionName]) == 'function' then
                        return overrides[functionName](...)
                    end
                    -- 本 env 里真的注册过的导出要被调用，而不是一律返回 true：
                    -- 之前 core-framework 的 ConvarString/ConvarInt 也走这条兜底，
                    -- 于是每个读 convar 的开关都拿到 true，`== '1'` 永远为假 →
                    -- 功能被当成关闭（HTTP 适配器全 503），测试却"没报错"。
                    local registered = env.exports[functionName]
                    if type(registered) == 'function' then
                        return registered(...)
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

    env.convars = env.convars or {}

    function _G.GetConvar(name, default)
        local value = env.convars[name]
        if value == nil then return default end
        return tostring(value)
    end

    function _G.SetConvar(name, value)
        env.convars[name] = value
    end

    -- Stable ids so ClearTimeout() keeps working after earlier timers drain.
    local nextTimerId = 0
    local function queueTimer(delay, fn)
        nextTimerId = nextTimerId + 1
        env.timers[#env.timers + 1] = { id = nextTimerId, delay = tonumber(delay) or 0, fn = fn }
        return nextTimerId
    end

    function _G.SetTimeout(delay, fn)
        return queueTimer(delay, fn)
    end

    function _G.ClearTimeout(timerId)
        for index, timer in ipairs(env.timers) do
            if timer.id == timerId then
                table.remove(env.timers, index)
                return true
            end
        end
        return false
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
        return env.resource_name or 'custom-director'
    end

    -- 资源枚举：env.resource_list 是名字数组（按引擎的 find-index 顺序），
    -- 起没起仍由 env.resource_states 决定。
    function _G.GetNumResources()
        local list = env.resource_list
        if type(list) ~= 'table' then return 0 end
        return #list
    end

    function _G.GetResourceByFindIndex(index)
        local list = env.resource_list
        if type(list) ~= 'table' then return nil end
        local position = (tonumber(index) or -1) + 1
        return list[position]
    end

    function _G.GetResourceState(name)
        return env.resource_states[name] or 'missing'
    end

    function _G.GetPlayerPed(source)
        return env.peds[tonumber(source) or source] or 0
    end

    -- Routing-bucket natives used by custom-director's set_bucket executor.
    -- Buckets are session state only; the harness keeps them in memory.
    function _G.GetPlayerRoutingBucket(source)
        return env.player_buckets[tonumber(source) or source] or 0
    end

    function _G.SetPlayerRoutingBucket(source, bucket)
        env.player_buckets[tonumber(source) or source] = tonumber(bucket) or bucket
        return true
    end

    function _G.GetEntityCoords(ped)
        return env.entity_coords[tonumber(ped) or ped] or { x = 0.0, y = 0.0, z = 0.0 }
    end

    -- Vehicle-in-use lookup for custom-director's delete_vehicle executor.
    -- env.vehicle_in_use[ped] = entity; missing or 0 means "not in a vehicle".
    function _G.GetVehiclePedIsIn(ped, lastVehicle)
        local id = tonumber(ped) or ped
        local entity = env.vehicle_in_use[id]
        if entity == nil then return 0 end
        return tonumber(entity) or entity
    end

    function _G.GetEntityModel(entity)
        local id = tonumber(entity) or entity
        if env.entity_models[id] ~= nil then return env.entity_models[id] end
        for _, vehicle in ipairs(env.vehicles) do
            if vehicle.entity == id and vehicle.model then
                return GetHashKey(tostring(vehicle.model))
            end
        end
        return 0
    end

    function _G.GetGameTimer()
        return tonumber(env.now) or 0
    end

    -- Vehicle spawn/verification natives used by custom-director's
    -- spawn_vehicle executor. env.hashes overrides a model hash (0 = unknown);
    -- env.entity_exists_override forces the bounded-wait timeout path.
    function _G.GetHashKey(model)
        local key = tostring(model)
        if env.hashes[key] ~= nil then
            return tonumber(env.hashes[key]) or 0
        end
        local hash = 0
        for index = 1, #key do
            hash = (hash * 31 + key:byte(index)) % 2147483647
        end
        return hash == 0 and 1 or hash
    end

    function _G.GetEntityHeading(ped)
        return env.entity_headings[tonumber(ped) or ped] or 0.0
    end

    function _G.GetEntityForwardVector(ped)
        return env.entity_forward[tonumber(ped) or ped] or { x = 1.0, y = 0.0, z = 0.0 }
    end

    local function recordVehicle(native, model, vehtype, x, y, z, heading)
        env.next_entity_id = env.next_entity_id + 1
        local entity = env.next_entity_id
        env.vehicles[#env.vehicles + 1] = {
            entity = entity,
            native = native,
            model = model,
            vehtype = vehtype,
            x = x,
            y = y,
            z = z,
            heading = heading,
        }
        env.created_entities[entity] = true
        return entity
    end

    function _G.CreateVehicleServerSetter(model, vehtype, x, y, z, heading)
        return recordVehicle('server_setter', model, vehtype, x, y, z, heading)
    end

    function _G.CreateVehicle(model, x, y, z, heading)
        return recordVehicle('create_vehicle', model, nil, x, y, z, heading)
    end

    function _G.DoesEntityExist(entity)
        if env.entity_exists_override ~= nil then
            return env.entity_exists_override == true
        end
        return env.created_entities[tonumber(entity) or entity] == true
    end

    function _G.DeleteEntity(entity)
        env.deleted_entities[#env.deleted_entities + 1] = entity
        env.created_entities[tonumber(entity) or entity] = nil
        return true
    end

    function _G.SetVehicleNumberPlateText(entity, plate)
        env.vehicle_plates[tonumber(entity) or entity] = plate
        return true
    end

    function _G.GetVehicleNumberPlateText(entity)
        if env.plate_readback_override ~= nil then return env.plate_readback_override end
        return env.vehicle_plates[tonumber(entity) or entity] or ''
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

        -- Yield a pending promise so a coroutine-driven caller (clientExec)
        -- suspends until settle() resolves it; that is what Citizen.Await
        -- does inside FXServer.
        function promise:await()
            if state == 'rejected' then error(failure, 0) end
            while state == 'pending' do
                if not coroutine.isyieldable() then
                    error('await on a pending promise outside a coroutine', 0)
                end
                coroutine.yield()
            end
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

        if type(executor) == 'function' then
            local ok, err = pcall(executor, resolve, reject)
            if not ok then reject(err) end
        end
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
