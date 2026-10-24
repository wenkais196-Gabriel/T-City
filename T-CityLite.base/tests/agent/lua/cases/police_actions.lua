-- cases/police_actions.lua — policy contract for the P4 police actions.
-- No game server: drives AgentPolicy.Normalize/Preview/CheckPolicy directly.

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

        local env = ctx.bootstrap.Load({ load_main = false, convars = {} })
        local policy = assert(env.policy, 'policy not loaded')

        check('police actions are declared', function()
            assert(policy.ACTIONS.police_incident_create.risk == 'L1')
            assert(policy.ACTIONS.police_incident_create.requires_approval == false)
            assert(policy.ACTIONS.police_assign_unit.risk == 'L2')
            assert(policy.ACTIONS.police_assign_unit.requires_approval == true)
            assert(policy.ACTIONS.police_jail_player.risk == 'L3')
            assert(policy.ACTIONS.police_jail_player.requires_approval == true)
        end)

        check('incident create normalizes', function()
            local normalized, err = policy.Normalize('police_incident_create', {
                title = 'Shots fired', code = '911', priority = 1, details = 'near legion',
            })
            assert(normalized, err)
            assert(normalized.title == 'Shots fired')
            assert(normalized.priority == 1)
            assert(normalized.details == 'near legion')
        end)

        check('incident create rejects short title', function()
            local normalized, err = policy.Normalize('police_incident_create', { title = 'x' })
            assert(not normalized)
            assert(err and err.code == 'invalid_params')
        end)

        check('assignment normalizes and rejects bad citizenid', function()
            local normalized, err = policy.Normalize('police_assign_unit', {
                incident_id = 3, citizenid = 'ABC123',
            })
            assert(normalized, err)
            assert(normalized.incident_id == 3)
            local bad, badErr = policy.Normalize('police_assign_unit', {
                incident_id = 3, citizenid = 'bad!id',
            })
            assert(not bad)
            assert(badErr and badErr.code == 'invalid_params')
        end)

        check('jail bounds minutes', function()
            local normalized = policy.Normalize('police_jail_player', {
                citizenid = 'ABC123', minutes = 10, reason = 'assault',
            })
            assert(normalized and normalized.minutes == 10)
            local zero = policy.Normalize('police_jail_player', {
                citizenid = 'ABC123', minutes = 0, reason = 'assault',
            })
            assert(not zero)
            local high = policy.Normalize('police_jail_player', {
                citizenid = 'ABC123', minutes = 121, reason = 'assault',
            })
            assert(not high)
        end)

        check('assign and jail need an online target', function()
            local assign = policy.CheckPolicy('police_assign_unit', {
                incident_id = 3, citizenid = 'ABC123',
            }, {}, {})
            assert(assign == false)
            local jail = policy.CheckPolicy('police_jail_player', {
                citizenid = 'ABC123', minutes = 10, reason = 'assault',
            }, {}, {})
            assert(jail == false)
        end)

        check('preview exposes risk and approval', function()
            local preview = policy.Preview('police_assign_unit', {
                incident_id = 3, citizenid = 'ABC123',
            }, {}, {})
            assert(preview)
            assert(preview.risk == 'L2')
            assert(preview.requires_approval == true)
        end)

        check('police_e2e runner is L1 and test-only', function()
            assert(policy.ACTIONS.police_run_e2e.risk == 'L1')
            assert(policy.ACTIONS.police_run_e2e.requires_approval == false)
            assert(policy.ACTIONS.police_run_e2e.auto_execute == true)
            assert(policy.ACTIONS.police_run_e2e.blast_radius == 'single')
            assert(policy.WORLD_ACTIONS.police_run_e2e == true)
        end)

        check('police_e2e normalizes suite and timeout', function()
            local defaults = policy.Normalize('police_run_e2e', {})
            assert(defaults and defaults.suite == 'police_e2e')
            assert(defaults.timeout_s == nil)
            local bounded = policy.Normalize('police_run_e2e', {
                suite = 'police_e2e', timeout_s = 90,
            })
            assert(bounded and bounded.timeout_s == 90)
            local badSuite = policy.Normalize('police_run_e2e', { suite = 'smoke' })
            assert(not badSuite)
            local badTimeout = policy.Normalize('police_run_e2e', { timeout_s = 181 })
            assert(not badTimeout)
            local unknown = policy.Normalize('police_run_e2e', { citizenid = 'ABC123' })
            assert(not unknown)
        end)

        check('police_e2e runs without an online player', function()
            assert(policy.CheckPolicy('police_run_e2e', {
                suite = 'police_e2e',
            }, {}, {}) == true)
            local preview = policy.Preview('police_run_e2e', {
                suite = 'police_e2e', timeout_s = 120,
            }, {}, {})
            assert(preview)
            assert(preview.risk == 'L1')
            assert(preview.test_namespace == 'police_e2e')
            assert(preview.writes_database == true)
            assert(preview.timeout_s == 120)
        end)

        return { results = results, failed = failed }
    end,
}
