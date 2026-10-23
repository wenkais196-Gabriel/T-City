-- tests/agent/lua/bootstrap.lua — load custom-director into a stubbed FiveM env.
--
-- Usage:
--   local env = dofile('.../bootstrap.lua').Load({
--       convars = { agent_actions_enabled = '1' },
--       load_main = false,
--   })
--
-- The resource root is found from TCITY_ROOT when set, otherwise by walking up
-- from this file until T-CityLite.base/resources/.../policy.lua exists.

local HERE = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\][^/\\]+$')) or '.'

local Bootstrap = {}

local function findRepoRoot()
    local fromEnv = os.getenv('TCITY_ROOT')
    if type(fromEnv) == 'string' and fromEnv ~= '' then return fromEnv end
    local directory = HERE
    for _ = 1, 8 do
        local probe = directory
            .. '/T-CityLite.base/resources/[custom]/custom-director/server/policy.lua'
        local handle = io.open(probe, 'r')
        if handle then
            handle:close()
            return directory
        end
        local parent = directory:match('^(.*)[/\\][^/\\]+$')
        if not parent or parent == '' or parent == directory then break end
        directory = parent
    end
    return '.'
end

function Bootstrap.Load(options)
    options = options or {}
    package.path = table.concat({
        HERE .. '/?.lua',
        HERE .. '/stubs/?.lua',
        package.path,
    }, ';')

    for _, moduleName in ipairs({ 'fivem', 'qbcore', 'mysql' }) do
        package.loaded[moduleName] = nil
    end

    local env = {
        convars = {},
        exports = {},
        events = {},
        event_handlers = {},
        client_events = {},
        timers = {},
        notifications = {},
        money_log = {},
        log = {},
        commands = {},
        ace = {},
        http_handlers = {},
        resource_name = options.resource_name,
        resource_states = options.resource_states or {},
        peds = options.peds or {},
        now = options.now or 0,
    }
    _G.TCITY = env

    for name, value in pairs(options.convars or {}) do
        env.convars[name] = tostring(value)
    end

    require('fivem')(env)
    require('qbcore')(env)
    require('mysql')(env, options.db)
    require('json')

    local resourceDir = findRepoRoot()
        .. '/T-CityLite.base/resources/[custom]/custom-director'

    local function loadServerFile(name)
        local path = resourceDir .. '/server/' .. name
        local handle, openError = io.open(path, 'r')
        if not handle then
            error(('cannot open %s: %s'):format(path, tostring(openError)), 0)
        end
        handle:close()
        return dofile(path)
    end

    env.policy = loadServerFile('policy.lua') or _G.AgentPolicy
    env.live_rules = loadServerFile('live_rules.lua') or _G.LiveRules
    env.live_store = loadServerFile('live_store.lua') or _G.LiveStore
    env.live_events = loadServerFile('live_events.lua') or _G.LiveEvents
    env.live_api = loadServerFile('live_api.lua') or _G.LiveApi
    env.http = loadServerFile('http_api.lua') or _G.AgentHttp

    -- custom-agent-client (effect channel): shared rules plus the server
    -- executor. Client scripts are not loaded in the Lua harness.
    if options.agent_client then
        local clientDir = findRepoRoot()
            .. '/T-CityLite.base/resources/[custom]/custom-agent-client'
        env.resource_name = options.resource_name or 'custom-agent-client'
        env.effect_rules = dofile(clientDir .. '/shared/effect_rules.lua') or _G.EffectRules
        dofile(clientDir .. '/server/main.lua')
    end

    if options.load_main then
        env.selftest = loadServerFile('selftest.lua')
        loadServerFile('main.lua')
    end

    env.actions = _G.AgentActions
    return env
end

return Bootstrap
