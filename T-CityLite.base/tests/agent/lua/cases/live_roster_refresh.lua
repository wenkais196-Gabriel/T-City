-- tests/agent/lua/cases/live_roster_refresh.lua — the roster must follow the server.
--
-- Regression for a real-server bug: live_api cached the QBCore object it got
-- from the qb-core export on first use, and every later request reused that
-- frozen copy.  On this fork one export call does not hand out the same object
-- twice, so a player who joined after the first sample stayed invisible until
-- the resource was restarted (`count=0` next to a live roster of 1).
--
-- The stub here reproduces that shape: `env.qb_provider` returns a brand new
-- table on every call, closing over whichever roster table is current.  The
-- old caching implementation keeps the first wrapper and therefore keeps the
-- first roster; the fixed implementation re-reads the export per request.

return {
    run = function(ctx)
        local env = ctx.bootstrap.Load({
            convars = {
                agent_live_enabled = '1',
                agent_live_token = 'live-token',
                agent_live_precision = '1',
            },
        })
        local Http = assert(_G.AgentHttp, 'server/http_api.lua was not loaded')
        local LiveApi = assert(_G.LiveApi, 'server/live_api.lua was not loaded')
        local LiveStore = assert(_G.LiveStore, 'server/live_store.lua was not loaded')

        LiveStore._default = nil

        -- Production shape: every export call builds its own object, and the
        -- inner roster table itself is replaced as players come and go, so a
        -- cached wrapper keeps pointing at the roster of the first sample.
        local roster = {}
        env.qb_provider = function()
            return {
                Players = roster,
                Functions = env.qb.Functions,
                Shared = env.qb.Shared,
                Config = env.qb.Config,
            }
        end
        -- Do not pre-seed the global: the fix must not depend on it.
        _G.QBCore = nil

        _G.GetPlayerPed = function(source) return source end
        _G.GetEntityCoords = function(ped) return { x = 100.0 + ped, y = 200.0, z = 30.0 } end
        _G.GetEntityHeading = function() return 90.0 end
        _G.GetEntityHealth = function() return 200 end
        _G.GetPedArmour = function() return 0 end
        _G.GetVehiclePedIsIn = function() return 0 end
        _G.GetPlayerRoutingBucket = function() return 0 end
        _G.GetPlayerPing = function() return 20 end

        local function actions()
            return {
                Policy = function()
                    return { schema_version = 1, enabled = true, actions = {}, limits = {} }
                end,
            }
        end

        local function handle(path)
            local deps = actions()
            return Http.Handle({
                method = 'GET',
                path = path,
                headers = { Authorization = 'Bearer live-token' },
                body = '',
            }, {
                cfg = { enabled = false, token = 'agent-token', admin_token = 'admin-token' },
                actions = deps,
                policy = deps.Policy,
                live = LiveApi,
            })
        end

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

        roster[1] = env.makePlayer(1, 'CID00001')

        check('first_sample_sees_the_loaded_player', function()
            local response = handle('/agent/v1/live/players')
            assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
            assert(response.body.count == 1,
                'expected 1 player, got ' .. tostring(response.body.count))
        end)

        check('roster_follows_a_player_who_joins_after_the_first_sample', function()
            roster = { env.makePlayer(1, 'CID00001'), env.makePlayer(2, 'CID00002') }
            local response = handle('/agent/v1/live/players')
            assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
            assert(response.body.count == 2,
                'the late join must be visible without restarting the resource, got '
                .. tostring(response.body.count))
            local seen = {}
            for _, player in ipairs(response.body.players) do seen[player.citizenid] = true end
            assert(seen['CID00002'], 'the late joiner is missing from the projection')
        end)

        check('roster_stops_reporting_a_player_who_leaves', function()
            roster = { env.makePlayer(1, 'CID00001') }
            local response = handle('/agent/v1/live/players')
            assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
            assert(response.body.count == 1,
                'a departed player must disappear from the sample, got '
                .. tostring(response.body.count))
        end)

        check('detail_route_finds_the_player_from_the_current_roster', function()
            roster = { env.makePlayer(1, 'CID00001'), env.makePlayer(2, 'CID00002') }
            local response = handle('/agent/v1/live/players/CID00002')
            assert(response.status == 200, 'expected 200 for a live citizenid, got '
                .. tostring(response.status))
            assert(response.body.player ~= nil, 'the detail body must carry a player')
            assert(response.body.player.citizenid == 'CID00002',
                tostring(response.body.player.citizenid))
        end)

        check('resolved_core_is_still_mirrored_on_g_for_live_events', function()
            -- live_events.lua reads _G.QBCore; the fix keeps writing it, but it
            -- must never be the source of truth again.
            handle('/agent/v1/live/players')
            assert(type(_G.QBCore) == 'table', 'the resolved core must stay available on _G')
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d live_roster_refresh case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
