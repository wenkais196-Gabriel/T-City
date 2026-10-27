-- tests/agent/lua/client_bootstrap.lua — load a *client* script into the stub env.
--
-- Usage:
--   local Client = dofile('.../client_bootstrap.lua')
--   local env = Client.Load({
--       resource = '[custom]/custom-phone',
--       files = { 'config.lua', 'client/main.lua' },
--   })
--
-- The manifest order matters: files are loaded in the order given, then
-- onClientResourceStart is fired, which is when FiveM makes key mappings and
-- late bindings legal. Anything the resource touches before that is a real
-- startup-order bug and will surface as a thread error.

local HERE = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\][^/\\]+$')) or '.'

local Client = {}

local function findRepoRoot(resource, firstFile)
    local fromEnv = os.getenv('TCITY_ROOT')
    if type(fromEnv) == 'string' and fromEnv ~= '' then return fromEnv end
    local probeTail = 'T-CityLite.base/resources/' .. resource .. '/' .. firstFile
    local function probe(directory)
        local handle = io.open(directory .. '/' .. probeTail, 'r')
        if handle then
            handle:close()
            return true
        end
        return false
    end
    -- Walk up from this file, then fall back to the process working directory
    -- (that is what `cd E:/T-City && lua5.4 T-CityLite.base/...` gives us).
    local directory = HERE
    for _ = 1, 8 do
        if probe(directory) then return directory end
        local parent = directory:match('^(.*)[/\\][^/\\]+$')
        if not parent or parent == '' or parent == directory then break end
        directory = parent
    end
    if probe('.') then return '.' end
    error('client bootstrap: cannot locate repository root for ' .. probeTail, 0)
end

function Client.Load(options)
    options = assert(options, 'Client.Load requires options')
    local resource = assert(options.resource, 'options.resource is required')
    local files = assert(options.files, 'options.files is required')

    package.path = table.concat({
        HERE .. '/?.lua',
        HERE .. '/stubs/?.lua',
        package.path,
    }, ';')

    package.loaded['client'] = nil
    local json = require('json') -- same encoder the other harness uses

    local resourceName = options.resource_name
        or resource:match('([^/]+)$')
        or resource

    local env = {
        resource_name = resourceName,
        clock = options.clock,
        anim_load_delay = options.anim_load_delay,
        frame_ms = options.frame_ms,
        resume_budget = options.resume_budget,
        now = options.now,
    }
    _G.TCITY = env
    require('client')(env)

    -- 客户端 convar（/phoneui、devcmd 桥都靠它门控）。以前 Load 不收这个选项，
    -- 于是"convar 关闭时什么都不做"的用例其实是靠 GetConvar 为 nil 崩溃通过的。
    env.convars = env.convars or {}
    for name, value in pairs(options.convars or {}) do
        env.convars[name] = tostring(value)
    end

    -- Server callbacks the client expects to exist. A test registers only the
    -- ones it cares about; the rest land in env.missing_callbacks.
    for name, handler in pairs(options.server_callbacks or {}) do
        env.server_callbacks[name] = handler
    end
    for name, overrides in pairs(options.export_overrides or {}) do
        env.export_overrides[name] = overrides
    end

    local root = findRepoRoot(resource, files[1])
    local base = root .. '/T-CityLite.base/resources/' .. resource

    env.loaded_files = {}
    for _, relative in ipairs(files) do
        local path = base .. '/' .. relative
        local chunk, err = loadfile(path)
        if not chunk then
            error(('client bootstrap: %s'):format(err), 0)
        end
        chunk()
        env.loaded_files[#env.loaded_files + 1] = relative
    end

    -- FiveM fires onClientResourceStart once every client script has loaded.
    env.StartResource()
    env.json = json
    return env
end

return Client
