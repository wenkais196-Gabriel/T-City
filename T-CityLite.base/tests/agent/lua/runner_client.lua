-- tests/agent/lua/runner_client.lua — headless client-side cases.
--
--   lua5.4 T-CityLite.base/tests/agent/lua/runner_client.lua
--   lua5.4 .../runner_client.lua --case phone_focus
--   lua5.4 .../runner_client.lua --case all --out out.json
--
-- Same contract as runner.lua: stdout carries JSON only (diagnostics go to
-- stderr), exit 0 = all passed, 1 = assertion failure, 2 = harness error.

local HERE = (debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\][^/\\]+$')) or '.'

package.path = HERE .. '/?.lua;' .. package.path
local json = require('json')

local CASES = {
    'phone_focus',
    'agent_effects',
}

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
    local Client = dofile(HERE .. '/client_bootstrap.lua')
    local input = {}
    if options['in'] then
        input = json.decode(readAll(options['in'])) or {}
    end

    local caseNames
    if options.case == nil or options.case == 'all' or options.case == true then
        caseNames = CASES
    else
        caseNames = { tostring(options.case) }
    end

    local results = {}
    local failed = 0

    for _, name in ipairs(caseNames) do
        local path = HERE .. '/cases_client/' .. name .. '.lua'
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
            return case.run({ input = input, bootstrap = Client })
        end)

        if not ok then
            record.ok = false
            record.error = tostring(result)
        elseif type(result) == 'table' then
            if result.ok == false then
                record.ok = false
                record.error = result.error or 'case reported failure'
                -- surface the individual failing checks, not just "failed"
                local details = {}
                for _, item in ipairs((result.data or {}).cases or {}) do
                    if item.ok == false then
                        details[#details + 1] = item.name .. ': ' .. tostring(item.error)
                    end
                end
                if #details > 0 then record.error = table.concat(details, ' | ') end
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
