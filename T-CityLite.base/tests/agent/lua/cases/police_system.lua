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
        -- p2_system 的审计走 PoliceAudit（唯一写者）。这个文件以前没加载它，
        -- 于是 'incident create writes an audit' 这条检查其实一直在抛 nil 索引，
        -- 而 runner 当时不认 failed 字段，红不起来（见 runner.lua 的修正）。
        dofile('T-CityLite.base/resources/[custom]/custom-police/server/audit.lua')
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

        -- CreateIncident 自 FIT-11 起改成"先审计 → 委托 PoliceIncidents.InsertRow"，
        -- 不再自己拼 SQL；所以这里测审计 + 委托参数 + 返回形状，SQL 形状归 p0 自己的测试。
        check('incident create audits first and delegates to the p0 writer', function()
            local before = #(env.mysql.log or {})
            local seen = {}
            PoliceIncidents = PoliceIncidents or {}
            local original = PoliceIncidents.InsertRow
            PoliceIncidents.InsertRow = function(createdBy, data, options)
                seen.createdBy, seen.title, seen.audit = createdBy, data.title, options and options.audit
                return { id = 77, code = '911', title = data.title, status = 'open' }
            end
            local ok, res = pcall(function()
                return sys.CreateIncident('unit-test', {
                    title = 'Shots fired', code = '911', priority = 1, details = 'legion',
                })
            end)
            PoliceIncidents.InsertRow = original
            assert(ok, tostring(res))
            assert(type(res) == 'table' and res.id == 77, 'unexpected result')

            -- 审计先写，而且写者跳过自己那条（options.audit = false）
            local auditRow = nil
            for index = #(env.mysql.log or {}), before + 1, -1 do
                local params = env.mysql.log[index].params or {}
                if params[3] == 'incident.create' then auditRow = params break end
            end
            assert(auditRow, 'no incident.create audit row')
            assert(auditRow[2] == 'agent', 'audit actor kind must be agent')
            assert(seen.audit == false, 'delegate must be told not to audit again')
            assert(seen.createdBy == 'agent:unit-test', 'created_by must be prefixed, got ' .. tostring(seen.createdBy))
        end)

        -- AssignUnit 自 FIT-11 起不再自己写 SQL，而是委托
        -- exports['custom-police']:AssignUnitSystemForAgent；所以这里测的是
        -- "委托 + 错误码透传"，不再是 SQL 形状（旧断言早已对不上实现）。
        check('assign delegates to the system helper and passes the reason through', function()
            env.exports.AssignUnitSystemForAgent = function(incidentId, citizenid, actorId)
                assert(incidentId == 9, 'incident id must be forwarded')
                assert(citizenid == 'ABC123', 'citizenid must be forwarded')
                assert(actorId == 'unit-test', 'actor must be forwarded')
                return false, 'incident_not_found'
            end
            local ok, err = sys.AssignUnit('unit-test', 9, 'ABC123')
            assert(ok == false and err == 'incident_not_found')
            env.exports.AssignUnitSystemForAgent = nil
        end)

        check('assign returns the helper result table on success', function()
            env.exports.AssignUnitSystemForAgent = function()
                return { ok = true, id = 9 }
            end
            local res = sys.AssignUnit('unit-test', 9, 'ABC123')
            assert(type(res) == 'table' and res.id == 9)
            env.exports.AssignUnitSystemForAgent = nil
        end)

        check('jail rejects an offline citizen', function()
            local ok, err = sys.Jail('unit-test', 'ABC123', 10, 'assault')
            assert(ok == false and err == 'citizen_offline')
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
