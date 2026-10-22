-- tests/agent/lua/cases/http_contract.lua — golden HTTP contract for custom-director.
--
-- Each golden drives AgentHttp.Handle() with a fake actions layer (the HTTP
-- contract is what is under test here, not the DB) and asserts status plus the
-- key response fields. The runner turns these records into JSON for pytest.

return {
    run = function(ctx)
        local Http = assert(_G.AgentHttp, 'server/http_api.lua was not loaded')
        local Policy = assert(_G.AgentPolicy, 'server/policy.lua was not loaded')

        local baseCfg = {
            enabled = true,
            token = 'agent-token',
            admin_token = 'admin-token',
            max_money = 1000,
            daily_budget = 5000,
            max_notify_chars = 300,
            ttl_seconds = 900,
        }

        local function makeCfg(overrides)
            local result = {}
            for key, value in pairs(baseCfg) do result[key] = value end
            for key, value in pairs(overrides or {}) do result[key] = value end
            return result
        end

        -- Fake action broker. It records calls; ids are deterministic.
        local function makeActions(log)
            local store = { rows = {}, nextId = 1 }
            local actions = {}

            function actions.Policy()
                return {
                    schema_version = 1,
                    enabled = true,
                    actions = {},
                    limits = { max_money = 1000 },
                }
            end

            function actions.Propose(agentId, actionType, params, key, dryRun)
                log.propose = {
                    agent_id = agentId,
                    action_type = actionType,
                    params = params,
                    key = key,
                    dry_run = dryRun,
                }
                local id = store.nextId
                store.nextId = store.nextId + 1
                local status = dryRun and 'proposed' or 'pending_approval'
                store.rows[#store.rows + 1] = {
                    id = id,
                    agent_id = agentId,
                    action_type = actionType,
                    status = status,
                }
                return { ok = true, id = id, status = status }
            end

            function actions.Get(id)
                return store.rows[tonumber(id)], nil
            end

            function actions.List(status, limit, agentId)
                log.list = { status = status, limit = limit, agent_id = agentId }
                return {
                    { id = 1, agent_id = agentId, status = status or 'pending_approval' },
                }
            end

            function actions.Approve(id, approver)
                log.approve = { id = id, approver = approver }
                return { ok = true, id = tonumber(id), status = 'approved', approved_by = approver }
            end

            function actions.Reject(id, approver, reason)
                log.reject = { id = id, approver = approver, reason = reason }
                return { ok = true, id = tonumber(id), status = 'rejected', approved_by = approver }
            end

            return actions
        end

        local function handle(request, cfgOverrides, log)
            return Http.Handle(request, {
                cfg = makeCfg(cfgOverrides),
                actions = makeActions(log or {}),
                policy = Policy,
            })
        end

        local function bearer(token)
            return { ['Authorization'] = 'Bearer ' .. token }
        end

        local function merge(base, extra)
            local result = {}
            for key, value in pairs(base or {}) do result[key] = value end
            for key, value in pairs(extra or {}) do result[key] = value end
            return result
        end

        local results = {}
        local failed = 0

        local function golden(name, expectedStatus, expectedCode, build, check)
            local record = {
                name = name,
                expected_status = expectedStatus,
                expected_code = expectedCode,
                ok = true,
            }
            local ok, err = pcall(function()
                local response = build()
                record.status = response.status
                record.body = response.body
                record.headers = response.headers or {}
                assert(response.status == expectedStatus,
                    ('expected status %s, got %s'):format(tostring(expectedStatus), tostring(response.status)))
                if expectedCode ~= nil then
                    assert(type(response.body) == 'table' and response.body.code == expectedCode,
                        ('expected code %s, got %s'):format(
                            tostring(expectedCode),
                            type(response.body) == 'table' and tostring(response.body.code) or 'nil'))
                end
                if check then check(response) end
            end)
            if not ok then
                record.ok = false
                record.error = tostring(err)
                failed = failed + 1
            end
            results[#results + 1] = record
        end

        -- 1. Kill switch.
        golden('disabled_returns_503', 503, 'disabled', function()
            return Http.Handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = {},
                body = '',
            }, {
                cfg = makeCfg({ enabled = false }),
                actions = makeActions({}),
                policy = Policy,
            })
        end, function(response)
            assert(response.body.error == 'agent actions are disabled')
        end)

        -- 2. Empty agent token.
        golden('empty_token_returns_503', 503, 'agent_token_not_configured', function()
            return handle({
                method = 'GET',
                path = '/agent/v1/policy',
                headers = bearer('agent-token'),
            }, { token = '' })
        end)

        -- 3. Unknown path is checked before authentication (information leak locked).
        golden('unknown_path_before_auth', 404, 'not_found', function()
            return handle({
                method = 'GET',
                path = '/agent/v1/does-not-exist',
                headers = {},
            })
        end, function(response)
            assert((response.headers or {})['WWW-Authenticate'] == nil)
        end)

        -- 4. Wrong method is checked before authentication and advertises Allow.
        golden('wrong_method_returns_405', 405, 'method_not_allowed', function()
            return handle({
                method = 'GET',
                path = '/agent/v1/act',
                headers = {},
            })
        end, function(response)
            assert(response.headers['Allow'] == 'POST',
                'Allow header must advertise POST, got ' .. tostring(response.headers['Allow']))
        end)

        -- 5. Admin endpoint without an admin token configured.
        golden('admin_route_without_admin_token', 503, 'admin_token_not_configured', function()
            return handle({
                method = 'POST',
                path = '/agent/v1/actions/1/approve',
                headers = merge(bearer('agent-token'), { ['Content-Length'] = '2' }),
                body = '{}',
            }, { admin_token = '' })
        end)

        -- 6. Admin bearer rejected with WWW-Authenticate.
        golden('admin_wrong_bearer_returns_401', 401, 'unauthorized', function()
            return handle({
                method = 'POST',
                path = '/agent/v1/actions/1/approve',
                headers = merge(bearer('wrong-admin'), { ['Content-Length'] = '2' }),
                body = '{}',
            })
        end, function(response)
            assert(response.headers['WWW-Authenticate'] == 'Bearer')
        end)

        -- 7. Agent bearer rejected on /policy.
        golden('agent_wrong_bearer_returns_401', 401, 'unauthorized', function()
            return handle({
                method = 'GET',
                path = '/agent/v1/policy',
                headers = bearer('wrong-agent'),
            })
        end, function(response)
            assert(response.headers['WWW-Authenticate'] == 'Bearer')
        end)

        -- 8. /policy succeeds and returns the policy document.
        golden('policy_returns_200', 200, nil, function()
            return handle({
                method = 'GET',
                path = '/agent/v1/policy',
                headers = bearer('agent-token'),
            })
        end, function(response)
            assert(response.body.schema_version == 1, 'schema_version must be 1')
            assert(response.body.enabled == true, 'enabled must be true')
            assert((response.headers or {})['WWW-Authenticate'] == nil)
        end)

        -- 9. X-Agent-Id is required after authentication.
        golden('missing_agent_id_returns_400', 400, 'missing_agent_id', function()
            return handle({
                method = 'GET',
                path = '/agent/v1/actions',
                headers = bearer('agent-token'),
            })
        end, function(response)
            assert(response.body.error == 'X-Agent-Id header is required')
        end)

        -- 9b. A pinned agent identity wins over the self-declared header.
        golden('configured_agent_id_is_used_without_header', 200, nil, function()
            log = {}
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['Content-Length'] = tostring(91),
                }),
                body = '{"type":"notify","args":{"citizenid":"ABC12345","text":"hi"},'
                    .. '"dry_run":true,"idempotency_key":"cfg-1"}',
            }, { agent_id = 'director.pinned' }, log)
        end, function(response)
            assert(log.propose and log.propose.agent_id == 'director.pinned',
                'the configured agent id must be used: ' .. tostring(log.propose and log.propose.agent_id))
        end)

        -- 9c. A conflicting header is rejected instead of being trusted.
        golden('configured_agent_id_rejects_mismatched_header', 400, 'agent_id_mismatch', function()
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['X-Agent-Id'] = 'spoofed.agent',
                    ['Content-Length'] = tostring(91),
                }),
                body = '{"type":"notify","args":{"citizenid":"ABC12345","text":"hi"},'
                    .. '"dry_run":true,"idempotency_key":"cfg-2"}',
            }, { agent_id = 'director.pinned' })
        end)

        -- 10. Malformed JSON is a bad_request.
        golden('invalid_json_returns_400', 400, 'bad_request', function()
            local body = '{'
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['X-Agent-Id'] = 'agent-1',
                    ['Content-Length'] = tostring(#body),
                }),
                body = body,
            })
        end, function(response)
            assert(response.body.error == 'request body must be valid JSON')
        end)

        -- 11. JSON arrays are not objects (numeric key at the top level).
        golden('non_object_body_returns_400', 400, 'bad_request', function()
            local body = '[1,2]'
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['X-Agent-Id'] = 'agent-1',
                    ['Content-Length'] = tostring(#body),
                }),
                body = body,
            })
        end, function(response)
            assert(response.body.error == 'request body must be a JSON object')
        end)

        -- 12. Content-Length over 16 KiB is rejected before body parsing.
        golden('content_length_over_limit_returns_413', 413, 'body_too_large', function()
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['X-Agent-Id'] = 'agent-1',
                    ['Content-Length'] = tostring(Http.MAX_BODY + 1),
                }),
                body = '',
            })
        end)

        -- 13. act dry_run happy path: 200 (proposed, not pending_approval).
        golden('act_dry_run_returns_200', 200, nil, function()
            local body = '{"type":"notify","args":{"citizenid":"ABC12345","text":"hi"},"dry_run":true}'
            local log = {}
            local response = handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['X-Agent-Id'] = 'agent-1',
                    ['Content-Length'] = tostring(#body),
                }),
                body = body,
            }, nil, log)
            assert(log.propose ~= nil, 'Propose was not called')
            assert(log.propose.agent_id == 'agent-1')
            assert(log.propose.action_type == 'notify')
            assert(log.propose.dry_run == true)
            assert(log.propose.params.citizenid == 'ABC12345')
            return response
        end, function(response)
            assert(response.body.ok == true)
            assert(response.body.status == 'proposed')
            assert(response.body.id == 1)
        end)

        -- 14. Missing Content-Length (and not chunked) is missing_body.
        golden('missing_content_length_returns_400', 400, 'missing_body', function()
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), { ['X-Agent-Id'] = 'agent-1' }),
                body = '{}',
            })
        end, function(response)
            assert(response.body.error == 'request body required')
        end)

        -- 15. Agent token cannot approve (role separation).
        golden('agent_token_cannot_approve', 401, 'unauthorized', function()
            local body = '{"approver":"alice"}'
            return handle({
                method = 'POST',
                path = '/agent/v1/actions/1/approve',
                headers = merge(bearer('agent-token'), { ['Content-Length'] = tostring(#body) }),
                body = body,
            })
        end)

        -- 16. Admin approve happy path.
        golden('admin_approve_returns_200', 200, nil, function()
            local body = '{"approver":"alice"}'
            local log = {}
            local response = handle({
                method = 'POST',
                path = '/agent/v1/actions/1/approve',
                headers = merge(bearer('admin-token'), { ['Content-Length'] = tostring(#body) }),
                body = body,
            }, nil, log)
            assert(log.approve ~= nil, 'Approve was not called')
            assert(log.approve.id == 1)
            assert(log.approve.approver == 'alice')
            return response
        end, function(response)
            assert(response.body.status == 'approved')
            assert(response.body.approved_by == 'alice')
        end)

        -- 17. Trailing slash does not match (strict routes), checked before auth.
        golden('trailing_slash_returns_404', 404, 'not_found', function()
            return handle({
                method = 'POST',
                path = '/agent/v1/actions/1/approve/',
                headers = {},
            })
        end)

        -- 18. A JSON array at the top level is accepted only as an empty table
        -- by the existing decoder; the action envelope still rejects it.
        -- This locks the pre-refactor behaviour (see design §4.4 note in the PR).
        golden('empty_array_reaches_act_envelope', 400, 'bad_request', function()
            local body = '[]'
            return handle({
                method = 'POST',
                path = '/agent/v1/act',
                headers = merge(bearer('agent-token'), {
                    ['X-Agent-Id'] = 'agent-1',
                    ['Content-Length'] = tostring(#body),
                }),
                body = body,
            })
        end, function(response)
            assert(response.body.error == 'type is required')
        end)

        -- 19. list route success uses the agent id and returns count.
        golden('list_returns_rows_for_agent', 200, nil, function()
            local log = {}
            local response = handle({
                method = 'GET',
                path = '/agent/v1/actions?limit=999',
                headers = merge(bearer('agent-token'), { ['X-Agent-Id'] = 'agent-1' }),
            }, nil, log)
            assert(log.list ~= nil, 'List was not called')
            assert(log.list.agent_id == 'agent-1')
            assert(log.list.limit == Http.MAX_LIST_LIMIT)
            return response
        end, function(response)
            assert(response.body.count == 1)
            assert(type(response.body.actions) == 'table')
            assert(response.body.actions[1].id == 1)
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d golden case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
