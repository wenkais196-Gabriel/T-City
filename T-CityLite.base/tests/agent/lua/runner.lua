-- tests/agent/lua/runner.lua — run pure-Lua cases for custom-director.
--
--   lua5.4 T-CityLite.base/tests/agent/lua/runner.lua                 # all cases
--   lua5.4 .../runner.lua --case http_contract                       # one case
--   lua5.4 .../runner.lua --case all --in in.json --out out.json     # Python
--
-- Exit codes: 0 all passed, 1 assertion failure, 2 harness error.
-- stdout is human diagnostics; --out receives structured JSON only.

local HERE = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\][^/\\]+$')) or '.'

package.path = HERE .. '/?.lua;' .. package.path
local json = require('json')

-- Keep stdout valid JSON for the pytest driver; resource diagnostics go to
-- stderr (the design explicitly forbids parsing console text as contract).
_G.print = function(...)
    local parts = {}
    for index = 1, select('#', ...) do
        parts[index] = tostring(select(index, ...))
    end
    io.stderr:write(table.concat(parts, '\t'), '\n')
end

-- No directory-listing API in plain Lua; keep this list explicit.
local CASES = { 'http_contract', 'http_adapter', 'live_rules', 'live_api' }

local function readAll(path)
    local handle = assert(io.open(path, 'rb'))
    local contents = handle:read('*a')
    handle:close()
    return contents
end

local function parseArgs(argv)
    local options = {}
    local index = 1
    while index <= #argv do
        local key = argv[index]:gsub('^%-%-', '')
        local value = argv[index + 1]
        if value and not value:match('^%-%-') then
            options[key] = value
            index = index + 2
        else
            options[key] = true
            index = index + 1
        end
    end
    return options
end

local options = parseArgs(arg)

local function writePayload(payload)
    local encoded = json.encode(payload)
    if not encoded then
        encoded = '{"ok":false,"error":"json encode failed"}'
    end
    if options.out then
        local handle = assert(io.open(options.out, 'wb'))
        handle:write(encoded)
        handle:close()
    end
    io.write(encoded, '\n')
end

local function main()
    local Bootstrap = dofile(HERE .. '/bootstrap.lua')
    local input = {}
    if options['in'] then
        input = json.decode(readAll(options['in'])) or {}
    end

    local env = Bootstrap.Load({})

    local caseNames
    if options.case == nil or options.case == 'all' or options.case == true then
        caseNames = CASES
    else
        caseNames = { tostring(options.case) }
    end

    local results = {}
    local failed = 0

    for _, name in ipairs(caseNames) do
        local path = name:find('/') and name or (HERE .. '/cases/' .. name .. '.lua')
        local handle = io.open(path, 'r')
        if not handle then
            error(('case not found: %s'):format(path), 0)
        end
        handle:close()

        local record = { name = name, ok = true }
        local ok, result = pcall(function()
            local case = assert(loadfile(path))()
            assert(type(case) == 'table' and type(case.run) == 'function',
                ('case %s has no run()'):format(name))
            return case.run({ env = env, input = input, bootstrap = Bootstrap })
        end)

        if not ok then
            record.ok = false
            record.error = tostring(result)
        elseif type(result) == 'table' then
            if result.ok == false then
                record.ok = false
                record.error = result.error or 'case reported failure'
            end
            record.data = result.data
        end

        if not record.ok then failed = failed + 1 end
        results[#results + 1] = record
    end

    if #caseNames == 1 then
        local single = results[1]
        writePayload({ ok = single.ok, data = single.data, error = single.error })
    else
        writePayload({
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
        })
    end
    return failed == 0 and 0 or 1
end

local ok, result = pcall(main)
if ok then
    os.exit(result == nil and 0 or result)
end

pcall(writePayload, { ok = false, error = 'harness: ' .. tostring(result) })
io.stderr:write('harness error: ' .. tostring(result) .. '\n')
os.exit(2)
