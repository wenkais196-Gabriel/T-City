-- tests/agent/lua/cases/live_api.lua — /agent/v1/live/* contract on the Lua harness.
--
-- Two fake players are projected through the same code path as production,
-- with server natives stubbed.  Asserts: envelope (no ok/data), field sets,
-- quantisation, plate masking, job filter, 404, 401, 503, cursor advance and a
-- PII scan over every response.

return {
    run = function(ctx)
        local env = ctx.bootstrap.Load({
            convars = {
                agent_live_enabled = '1',
                agent_live_token = 'live-token',
                agent_live_precision = '25',
            },
        })
        local Http = assert(_G.AgentHttp, 'server/http_api.lua was not loaded')
        local LiveApi = assert(_G.LiveApi, 'server/live_api.lua was not loaded')
        local LiveStore = assert(_G.LiveStore, 'server/live_store.lua was not loaded')
        local json = assert(_G.json)
        local Policy = assert(_G.AgentPolicy)

        local players = env.players
        env.qb.Players = players
        _G.QBCore = env.qb
        -- 客户端状态探测要求执行器资源在跑（否则回答 probe_unavailable）
        env.resource_states['custom-agent-client'] = 'started'

        -- Natives used by live_api.samplePlayer.  Position/heading/health are
        -- per source; only player 2 is in a vehicle.
        local positions = {
            [1] = { x = 123.4, y = -1040.2, z = 27.4 },
            [2] = { x = -500.0, y = 600.0, z = 30.0 },
        }
        _G.GetPlayerPed = function(source) return source end
        _G.DoesEntityExist = function() return true end
        _G.GetEntityCoords = function(ped) return positions[ped] end
        _G.GetEntityHeading = function() return 180.0 end
        _G.GetEntityHealth = function(ped) return ped == 1 and 172 or 200 end
        _G.GetPedArmour = function() return 35 end
        _G.GetVehiclePedIsIn = function(ped) return ped == 2 and 9001 or 0 end
        _G.GetEntityModel = function() return -1216765807 end
        _G.GetVehicleNumberPlateText = function() return 'TC123AB' end
        _G.GetPedInVehicleSeat = function() return 2 end
        _G.GetPlayerRoutingBucket = function(source) return source == 2 and 3 or 0 end
        _G.GetPlayerPing = function() return 42 end

        local function seedPlayer(source, citizenid, job)
            local player = env.makePlayer(source, citizenid, { cash = 340, bank = 18220, crypto = 0 })
            local data = player.PlayerData
            data.job = job
            data.gang = { name = 'none', label = 'No Gang', grade = { level = 0, name = 'none' } }
            data.metadata = {
                health = 172, armor = 35, hunger = 88, thirst = 71, stress = 12,
                isdead = false, inlaststand = false, ishandcuffed = false, injail = 0,
                fingerprint = 'FP-SECRET', walletid = 'WALLET-SECRET',
                phone = { number = '555-0100' },
            }
            -- PII that must never survive the projection.
            data.license = 'license:DEADBEEF'
            data.identifiers = { discord = 'discord:SECRET', steam = 'steam:SECRET' }
            data.charinfo = { firstname = 'Vito', lastname = 'Maretti', phone = '555-0100' }
            data.items = { { name = 'bread', count = 3, info = { serial = 'SERIAL-SECRET' } } }
            data.inventory = { bread = 3 }
            return player
        end

        seedPlayer(1, 'CID00001', {
            name = 'police', label = 'Police', grade = { level = 2, name = 'Officer' }, onduty = true,
        })
        seedPlayer(2, 'CID00002', {
            name = 'unemployed', label = 'Unemployed', grade = { level = 0, name = 'No Grades' }, onduty = false,
        })

        -- Fresh ring: the harness may have loaded live_events in earlier cases.
        LiveStore._default = nil

        local authHeaders = { Authorization = 'Bearer live-token' }

        local function makeCfg(overrides)
            local cfg = { enabled = false, token = 'agent-token', admin_token = 'admin-token' }
            for key, value in pairs(overrides or {}) do cfg[key] = value end
            return cfg
        end

        local actions = {
            Policy = function()
                return { schema_version = 1, enabled = true, actions = {}, limits = {} }
            end,
        }

        local function handle(path, headers, overrides, live)
            return Http.Handle({
                method = 'GET',
                path = path,
                headers = headers or authHeaders,
                body = '',
            }, {
                cfg = makeCfg(overrides),
                actions = actions,
                policy = Policy,
                live = live == nil and LiveApi or live,
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

        local function fail(message) error(message, 0) end

        local function assertAllowedKeys(tableValue, allowed, label)
            for key in pairs(tableValue) do
                if allowed[key] ~= true then
                    fail(('%s has unexpected field %q'):format(label, tostring(key)))
                end
            end
        end

        local PLAYER_FIELDS = {
            citizenid = true, source = true, job = true, gang = true,
            metadata = true, position = true, heading = true, bucket = true,
            ping = true, vehicle = true, last_seen_ms = true,
        }

        local FORBIDDEN_WORDS = { 'license', 'ip', 'identifier', 'phone', 'inventory' }
        local FORBIDDEN_VALUES = { 'secret', 'deadbeef', '555-0100', 'serial', 'wallet' }

        local function assertNoPII(value, label)
            local text = json.encode(value)
            assert(type(text) == 'string', label .. ': response did not encode')
            local lowered = text:lower()
            for _, word in ipairs(FORBIDDEN_WORDS) do
                if lowered:find(word, 1, true) then
                    fail(('%s leaks forbidden word %q: %s'):format(label, word, text))
                end
            end
            for _, word in ipairs(FORBIDDEN_VALUES) do
                if lowered:find(word, 1, true) then
                    fail(('%s leaks forbidden value %q: %s'):format(label, word, text))
                end
            end
        end

        local function assertNoEnvelope(response, label)
            assert(type(response.body) == 'table', label .. ': body must be a table')
            assert(response.body.ok == nil, label .. ': must not carry ok')
            assert(response.body.data == nil, label .. ': must not carry data')
            assert(response.body.schema_version == 1, label .. ': schema_version must be 1')
        end

        -- 1. list -------------------------------------------------------------
        check('players_list_envelope_and_fields', function()
            local response = handle('/agent/v1/live/players')
            assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
            assertNoEnvelope(response, 'players')
            assert(response.body.count == 2, 'expected 2 players, got ' .. tostring(response.body.count))
            assert(type(response.body.players) == 'table' and #response.body.players == 2)
            assert(type(response.body.sampled_at) == 'number')
            assert(response.body.precision_m == 25)

            local first = response.body.players[1]
            assert(first.citizenid == 'CID00001', 'list must be sorted by citizenid')
            assertAllowedKeys(first, PLAYER_FIELDS, 'player')
            for field in pairs(PLAYER_FIELDS) do
                if field ~= 'vehicle' then
                    assert(first[field] ~= nil, 'missing live field ' .. field)
                end
            end
            assert(first.position.x == 125 and first.position.y == -1050 and first.position.z == 25,
                'coarse position must be snapped to 25m')
            assert(first.metadata.health == 172 and first.metadata.armor == 35)
            assert(first.job.name == 'police' and first.job.grade == 2 and first.job.onduty == true)
            assert(first.money == nil, 'the list projection must omit balances')
            assert(first.vehicle == nil, 'player 1 is on foot, vehicle must be absent')
            assert(first.last_seen_ms ~= nil)

            local second = response.body.players[2]
            assert(second.vehicle ~= nil, 'player 2 is in a vehicle')
            assert(second.vehicle.plate == 'TC***AB', 'plate must be masked, got ' .. tostring(second.vehicle.plate))
            assertAllowedKeys(second.vehicle, { model = true, plate = true, seat = true }, 'vehicle')
            assertNoPII(response.body, 'players response')
        end)

        check('players_job_filter_and_limit', function()
            local filtered = handle('/agent/v1/live/players?job=police')
            assert(filtered.status == 200 and filtered.body.count == 1)
            assert(filtered.body.players[1].citizenid == 'CID00001')

            local limited = handle('/agent/v1/live/players?limit=1')
            assert(limited.status == 200 and limited.body.count == 1)
            assert(limited.body.players[1].citizenid == 'CID00001')

            local clamped = handle('/agent/v1/live/players?limit=999')
            assert(clamped.status == 200 and clamped.body.count == 2, 'limit must clamp, not fail')
        end)

        check('players_fine_precision', function()
            env.convars.agent_live_precision = 'fine'
            local response = handle('/agent/v1/live/players?limit=1')
            env.convars.agent_live_precision = '25'
            assert(response.status == 200)
            assert(response.body.precision_m == 0, 'fine must report precision_m=0')
            assert(response.body.players[1].position.x == 123.4, 'fine must not quantise')
        end)

        check('roster_resolves_qb_core_from_the_export', function()
            -- Regression: live_api used to read _G.QBCore, which nothing on a
            -- real server sets (main.lua keeps a local). The harness used to
            -- set the global, hiding the bug; clear it and require the export
            -- fallback to find the roster.
            local saved = _G.QBCore
            _G.QBCore = nil
            local ok, err = pcall(function()
                local response = handle('/agent/v1/live/players')
                assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
                assert(response.body.count == 2,
                    'expected 2 players via the qb-core export, got ' .. tostring(response.body.count))
                assert(_G.QBCore ~= nil, 'the resolved core must be cached on _G')
            end)
            _G.QBCore = saved
            if not ok then error(err, 0) end
        end)

        check('roster_samples_position_without_entity_exists_or_source_field', function()
            -- Server-side DoesEntityExist can be false for a remote ped and
            -- PlayerData.source is not guaranteed; both must not gate sampling.
            local savedExists = _G.DoesEntityExist
            local savedSource = players[1].PlayerData.source
            _G.DoesEntityExist = function() return false end
            players[1].PlayerData.source = nil
            local ok, err = pcall(function()
                local response = handle('/agent/v1/live/players')
                assert(response.status == 200)
                local first = response.body.players[1]
                assert(first.position ~= nil, 'position must be sampled despite DoesEntityExist=false')
                assert(first.source == 1, 'source must come from the qb-core key')
            end)
            _G.DoesEntityExist = savedExists
            players[1].PlayerData.source = savedSource
            if not ok then error(err, 0) end
        end)

        -- 2. detail -----------------------------------------------------------
        check('detail_success', function()
            local response = handle('/agent/v1/live/players/CID00002')
            assert(response.status == 200)
            assertNoEnvelope(response, 'detail')
            assert(response.body.player.citizenid == 'CID00002')
            assert(response.body.player.vehicle.plate == 'TC***AB')
            assert(response.body.player.money ~= nil, 'detail keeps balances')
            assert(response.body.players == nil)
            assertNoPII(response.body, 'detail response')
        end)

        check('detail_not_found', function()
            local response = handle('/agent/v1/live/players/NOPE999')
            assert(response.status == 404, 'expected 404, got ' .. tostring(response.status))
            assert(response.body.code == 'player_not_found')
            assert(response.body.ok == nil and response.body.data == nil)
        end)

        check('unknown_live_route_is_404', function()
            local response = handle('/agent/v1/live/nope')
            assert(response.status == 404 and response.body.code == 'not_found')
        end)

        -- 3. auth / kill switch ----------------------------------------------
        check('live_disabled_returns_503', function()
            env.convars.agent_live_enabled = '0'
            local response = handle('/agent/v1/live/players')
            env.convars.agent_live_enabled = '1'
            assert(response.status == 503 and response.body.code == 'live_disabled')
        end)

        check('missing_token_returns_503', function()
            env.convars.agent_live_token = ''
            local response = handle('/agent/v1/live/players', authHeaders, { token = '' })
            env.convars.agent_live_token = 'live-token'
            assert(response.status == 503 and response.body.code == 'live_token_not_configured')
        end)

        check('wrong_token_returns_401', function()
            local response = handle('/agent/v1/live/players', { Authorization = 'Bearer nope' })
            assert(response.status == 401 and response.body.code == 'unauthorized')
            assert(response.headers and response.headers['WWW-Authenticate'] == 'Bearer')
        end)

        check('actions_token_is_not_a_live_token', function()
            env.convars.agent_live_token = ''
            local response = handle('/agent/v1/live/players', {
                Authorization = 'Bearer agent-token',
            })
            env.convars.agent_live_token = 'live-token'
            assert(response.status == 503, 'the write token must not open the read channel')
            assert(response.body.code == 'live_token_not_configured')
        end)

        check('wrong_method_returns_405', function()
            local response = Http.Handle({
                method = 'POST',
                path = '/agent/v1/live/players',
                headers = authHeaders,
                body = '',
            }, {
                cfg = makeCfg(),
                actions = actions,
                policy = Policy,
                live = LiveApi,
            })
            assert(response.status == 405 and response.body.code == 'method_not_allowed')
            assert(response.headers and response.headers['Allow'] == 'GET')
        end)

        check('live_intercept_precedes_actions_switch', function()
            -- cfg.enabled=false is the director kill switch; live must still
            -- answer because agent_live_enabled is independent.
            local response = handle('/agent/v1/live/players', authHeaders, { enabled = false })
            assert(response.status == 200)
        end)

        check('nil_live_dependency_is_skipped', function()
            local response = handle('/agent/v1/live/players', authHeaders, { enabled = false }, false)
            assert(response.status == 503 and response.body.code == 'disabled',
                'without deps.live the existing actions switch must answer')
        end)

        check('existing_routes_unaffected', function()
            local response = handle('/agent/v1/policy', { Authorization = 'Bearer agent-token' }, { enabled = true })
            assert(response.status == 200 and response.body.schema_version == 1)
        end)

        -- 4. events -----------------------------------------------------------
        check('events_cursor_advance', function()
            LiveStore._default = nil
            local store = LiveStore.Default()
            store:Push({ type = 'player.join', citizenid = 'CID00001', at = 1730000000001, payload = { source = 1 } })
            store:Push({ type = 'money.change', citizenid = 'CID00001', at = 1730000000002,
                payload = { account = 'bank', delta = -250, operation = 'remove', reason = 'vehicle repair' } })
            store:Push({ type = 'player.job.change', citizenid = 'CID00002', at = 1730000000003,
                payload = { job = { name = 'police', grade = 2 }, prev = nil } })

            local first = handle('/agent/v1/live/events?limit=10')
            assert(first.status == 200, 'expected 200, got ' .. tostring(first.status))
            assertNoEnvelope(first, 'events')
            assert(#first.body.events == 3, 'expected 3 events, got ' .. tostring(#first.body.events))
            assert(first.body.dropped == 0)
            assert(type(first.body.next_cursor) == 'string')
            assert(first.body.next_cursor:match('^%d+:%d+$') ~= nil,
                'cursor must be epoch:seq, got ' .. tostring(first.body.next_cursor))
            assert(first.headers['X-Agent-Live-Epoch'] ~= nil)
            assert(first.headers['X-Agent-Live-Seq'] == '3')
            local event = first.body.events[1]
            assertAllowedKeys(event, { seq = true, type = true, citizenid = true, at = true, payload = true }, 'event')
            assert(event.seq == 1 and event.type == 'player.join')
            assert(event.at == 1730000000001)
            assertNoPII(first.body, 'events response')

            local cursor = first.body.next_cursor
            store:Push({ type = 'player.leave', citizenid = 'CID00002', at = 1730000000004,
                payload = { source = 2, reason = 'quit' } })

            local second = handle('/agent/v1/live/events?since=' .. cursor .. '&limit=10')
            assert(second.status == 200)
            assert(#second.body.events == 1, 'only the event after the cursor may be returned')
            assert(second.body.events[1].seq == 4 and second.body.events[1].type == 'player.leave')
            assert(second.body.next_cursor ~= cursor, 'next_cursor must advance')
        end)

        check('events_future_cursor_is_clamped', function()
            -- A cursor from the future must clamp to newest. Echoing it back
            -- would point next_cursor past every future event and strand the
            -- consumer until the ring wraps.
            local store = LiveStore.Default()
            local future = tostring(store.epoch) .. ':999999999'
            local response = handle('/agent/v1/live/events?since=' .. future)
            assert(response.status == 200, 'a future cursor must not be an error')
            assert(#response.body.events == 0)
            assert(response.body.next_cursor ~= future,
                'next_cursor must not echo a future sequence')
            assert(tonumber(response.body.next_cursor:match(':(%d+)$')) == store.seq,
                'next_cursor must clamp to the newest sequence')
        end)

        check('events_invalid_cursor', function()
            local response = handle('/agent/v1/live/events?since=not-a-cursor')
            assert(response.status == 400 and response.body.code == 'invalid_cursor')
        end)

        check('events_epoch_mismatch', function()
            local response = handle('/agent/v1/live/events?since=deadbeef:1')
            assert(response.status == 409 and response.body.code == 'cursor_epoch_mismatch')
        end)

        check('events_limit_clamped', function()
            local response = handle('/agent/v1/live/events?limit=0')
            assert(response.status == 200 and #response.body.events == 1,
                'limit=0 must clamp to 1, not fail')
        end)

        -- 5. qb-core hooks feed the same ring --------------------------------
        check('qb_hooks_emit_events', function()
            LiveStore._default = nil
            _G.LiveEvents.Reset()

            _G.TriggerEvent('QBCore:Server:PlayerLoaded', players[1])
            _G.TriggerEvent('QBCore:Server:OnJobUpdate', 1, {
                name = 'ambulance', label = 'EMS', grade = { level = 3 }, onduty = true,
            })
            _G.TriggerEvent('QBCore:Server:OnMoneyChange', 1, 'bank', -250, 'remove', 'repair')
            _G.TriggerEvent('QBCore:Server:PlayerDropped', players[1])

            local response = handle('/agent/v1/live/events?limit=20')
            assert(response.status == 200)
            local types = {}
            for _, event in ipairs(response.body.events) do types[#types + 1] = event.type end
            assert(table.concat(types, ',') == 'player.join,player.job.change,money.change,player.leave',
                'unexpected hook event sequence: ' .. table.concat(types, ','))
            assert(response.body.events[3].payload.reason == nil,
                'the free-text reason can carry a phone number and must be dropped')
            assertNoPII(response.body, 'hook events')
        end)

        -- 6. main.lua adapter wiring -----------------------------------------
        check('main_adapter_intercepts_live', function()
            -- Reload with the FiveM adapter so main.lua's SetHttpHandler deps
            -- (live = _G.LiveApi) are exercised, not just AgentHttp.Handle.
            local adapterEnv = ctx.bootstrap.Load({
                load_main = true,
                convars = {
                    agent_live_enabled = '1',
                    agent_live_token = 'live-token',
                    agent_actions_enabled = '0',
                },
            })
            _G.QBCore = adapterEnv.qb
            adapterEnv.qb.Players = adapterEnv.players
            local player = adapterEnv.makePlayer(1, 'CID00001', { cash = 1, bank = 2, crypto = 0 })
            player.PlayerData.job = { name = 'police', label = 'Police', grade = { level = 1 }, onduty = true }

            local captures = {}
            adapterEnv.http_handler({
                method = 'GET',
                path = '/agent/v1/live/players',
                headers = { Authorization = 'Bearer live-token' },
                setDataHandler = function() error('live GET must not read a body', 0) end,
            }, {
                writeHead = function(status, headers)
                    captures.status = status
                    captures.headers = headers
                end,
                send = function(payload) captures.payload = payload end,
            })

            assert(captures.status == 200, 'adapter returned ' .. tostring(captures.status))
            local body = json.decode(captures.payload)
            assert(body.schema_version == 1 and body.count == 1)
            assert(captures.headers['Content-Type']:find('application/json', 1, true) ~= nil)
        end)

        check('rate_limit_returns_429', function()
            -- Reload with a tiny bucket: earlier checks may have rebound the
            -- global FiveM stubs to a different env.
            ctx.bootstrap.Load({
                convars = {
                    agent_live_enabled = '1',
                    agent_live_token = 'live-token',
                    agent_live_rate_per_min = '1',
                    agent_live_burst = '1',
                },
            })
            local RateHttp = assert(_G.AgentHttp, 'http_api not reloaded')
            local RateLive = assert(_G.LiveApi, 'live_api not reloaded')
            RateLive._ResetRateLimit()
            local deps = {
                cfg = { enabled = false, token = 't', admin_token = 'a' },
                actions = { Policy = function() return {} end },
                policy = _G.AgentPolicy,
                live = RateLive,
            }
            local function call()
                return RateHttp.Handle({
                    method = 'GET',
                    path = '/agent/v1/live/players',
                    headers = { Authorization = 'Bearer live-token' },
                    body = '',
                }, deps)
            end
            local first = call()
            local second = call()
            assert(first.status == 200, 'the first request must pass, got ' .. tostring(first.status))
            assert(second.status == 429, 'the second request must be rate limited, got '
                .. tostring(second.status))
            assert(second.body.code == 'rate_limited', tostring(second.body.code))
            assert(second.headers and second.headers['Retry-After'],
                'a 429 must tell the caller when to retry')
        end)

        -- 3. clients / server state probes -------------------------------------
        -- 这一段的用例必须用一个新的 env：上面的 main-adapter / rate-limit 检查各自
        -- 调过 ctx.bootstrap.Load，_G 上的 stub（GetResourceState / exports）已经被
        -- 换成那个 env 的，沿用开头的 env 会读到"资源不存在、core 是另一个表"。
        local probeEnv = ctx.bootstrap.Load({
            convars = {
                agent_live_enabled = '1',
                agent_live_token = 'live-token',
                agent_live_precision = '25',
            },
        })
        probeEnv.resource_states['custom-agent-client'] = 'started'
        probeEnv.qb.Players = players
        _G.QBCore = probeEnv.qb

        local probeLive = assert(_G.LiveApi)
        local probeHttp = assert(_G.AgentHttp)
        local function probeHandle(path)
            local deps = {
                Policy = function()
                    return { schema_version = 1, enabled = true, actions = {}, limits = {} }
                end,
            }
            return probeHttp.Handle({
                method = 'GET',
                path = path,
                headers = { Authorization = 'Bearer live-token' },
                body = '',
            }, {
                cfg = { enabled = false, token = 'agent-token', admin_token = 'admin-token' },
                actions = deps,
                policy = deps.Policy,
                live = probeLive,
            })
        end

        check('clients_list_serves_snapshots', function()
            probeEnv.export_overrides['custom-agent-client'] = {
                ClientState = function(src)
                    if tonumber(src) == 1 then
                        return { v = 1, logged_in = true, phone = { open = true, surface = 'phone' } }, nil, 120
                    end
                    return nil, 'client_state_unavailable'
                end,
            }
            local response = probeHandle('/agent/v1/live/clients')
            assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
            assert(response.body.count == 1, 'only players with a snapshot are listed, got '
                .. tostring(response.body.count))
            local first = response.body.clients[1]
            assert(first.citizenid == 'CID00001', tostring(first.citizenid))
            assert(first.age_ms == 120, tostring(first.age_ms))
            assert(first.state.phone.open == true)
        end)

        check('clients_detail_404_when_state_is_missing', function()
            probeEnv.export_overrides['custom-agent-client'] = {
                ClientState = function() return nil, 'client_state_unavailable' end,
            }
            local response = probeHandle('/agent/v1/live/clients/CID00001')
            assert(response.status == 404, 'expected 404, got ' .. tostring(response.status))
            assert(response.body.code == 'client_state_unavailable', tostring(response.body.code))
        end)

        check('clients_detail_404_for_unknown_player', function()
            local response = probeHandle('/agent/v1/live/clients/NOPE999')
            assert(response.status == 404)
            assert(response.body.code == 'player_not_found', tostring(response.body.code))
        end)

        check('server_state_reports_counts', function()
            local response = probeHandle('/agent/v1/live/server')
            assert(response.status == 200, 'expected 200, got ' .. tostring(response.status))
            assert(type(response.body.resources) == 'table', 'resources block must exist')
            assert(response.body.players == 2, 'both fixture players count, got ' .. tostring(response.body.players))
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d live_api case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
