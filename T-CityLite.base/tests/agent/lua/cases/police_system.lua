-- cases/police_system.lua — custom-police system entry points against the
-- oxmysql stub. No game server; exercises validation, SQL shape and audits.

return {
    run = function(ctx)
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

        local env = ctx.bootstrap.Load({ load_main = false, convars = {}, db = {} })
        dofile('T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua')
        local sys = {
            CreateIncident = assert(env.exports.CreateIncidentSystem, 'CreateIncidentSystem missing'),
            AssignUnit = assert(env.exports.AssignUnitSystem, 'AssignUnitSystem missing'),
            Jail = assert(env.exports.JailSystem, 'JailSystem missing'),
        }

        check('incident create validates title', function()
            local ok, err = sys.CreateIncident('unit-test', { title = 'x' })
            assert(ok == false and err == 'invalid_title')
        end)

        check('incident create writes an audit and a row', function()
            env.mysql.reset()
            env.mysql.push({ kind = 'insert', result = 42 })
            env.mysql.push({ kind = 'insert', result = 77 })
            local res = sys.CreateIncident('unit-test', {
                title = 'Shots fired', code = '911', priority = 1, details = 'legion',
            })
            assert(res and res.id == 77, 'unexpected result')
            local log = env.mysql.log
            assert(#log == 2, ('expected 2 sql calls, got %d'):format(#log))
            assert(log[1].params[3] == 'incident.create', 'audit action')
            assert(log[1].params[2] == 'agent', 'audit actor kind')
            assert(log[2].params[5] == 'agent:unit-test', 'created_by')
        end)

        check('assign rejects a missing incident', function()
            env.mysql.reset()
            env.mysql.push({ kind = 'single', result = nil })
            local ok, err = sys.AssignUnit('unit-test', 9, 'ABC123')
            assert(ok == false and err == 'incident_not_found')
        end)

        check('assign rejects an off-duty unit', function()
            env.mysql.reset()
            env.mysql.push({ kind = 'single', result = { id = 9 } })
            env.mysql.push({ kind = 'single', result = { citizenid = 'ABC123', status = 'off_duty' } })
            local ok, err = sys.AssignUnit('unit-test', 9, 'ABC123')
            assert(ok == false and err == 'unit_off_duty')
        end)

        check('jail rejects an offline citizen', function()
            local ok, err = sys.Jail('unit-test', 'ABC123', 10, 'assault')
            assert(ok == false and err == 'citizen_offline')
        end)

        return { results = results, failed = failed }
    end,
}
