-- tests/agent/lua/cases/http_adapter.lua — FiveM adapter stream semantics.
--
-- Regression guard for the refactor: FXServer never calls req.setDataHandler
-- for requests without a body, so GET /policy, GET /actions, 404/405 and
-- missing-X-Agent-Id responses must be produced synchronously. Only routes
-- that really read a body may defer to setDataHandler.

return {
    run = function(ctx)
        local env = ctx.env

        -- main.lua registers the adapter; load it on demand so the pure
        -- http_contract case stays independent of the resource bootstrap.
        if not env.http_handler then
            env = ctx.bootstrap.Load({
                load_main = true,
                convars = {
                    agent_actions_enabled = '1',
                    agent_actions_token = 'agent-token',
                    agent_actions_admin_token = 'admin-token',
                },
            })
        end
        assert(env.http_handler, 'SetHttpHandler was not registered')

        local function call(request)
            local captures = {}
            local response = {
                writeHead = function(status, headers)
                    captures[#captures + 1] = { kind = 'head', status = status, headers = headers }
                end,
                send = function(payload)
                    captures[#captures + 1] = { kind = 'body', payload = payload }
                end,
            }
            env.http_handler(request, response)
            return captures
        end

        local function decode(captures)
            assert(#captures == 2, ('expected one response, got %d call(s)'):format(#captures))
            return captures[1].status, json.decode(captures[2].payload)
        end

        local forbidden = function()
            error('setDataHandler must not be called for a bodiless response', 0)
        end

        local results = {}
        local failed = 0

        local function golden(name, fn)
            local record = { name = name, ok = true }
            local ok, err = pcall(function()
                local status, body = fn()
                record.status = status
                record.body = body
            end)
            if not ok then
                record.ok = false
                record.error = tostring(err)
                failed = failed + 1
            end
            results[#results + 1] = record
        end

        golden('get_policy_is_synchronous', function()
            local captures = call({
                method = 'GET',
                path = '/agent/v1/policy',
                headers = { Authorization = 'Bearer agent-token' },
                setDataHandler = forbidden,
            })
            local status, body = decode(captures)
            assert(status == 200, 'status ' .. tostring(status))
            assert(body.schema_version == 1)
            assert(body.enabled == true)
            return status, { schema_version = body.schema_version, enabled = body.enabled }
        end)

        golden('get_list_is_synchronous', function()
            local captures = call({
                method = 'GET',
                path = '/agent/v1/actions',
                headers = {
                    Authorization = 'Bearer agent-token',
                    ['X-Agent-Id'] = 'agent-1',
                },
                setDataHandler = forbidden,
            })
            local status, body = decode(captures)
            assert(status == 200, 'status ' .. tostring(status))
            assert(body.count == 0)
            return status, { count = body.count }
        end)

        golden('unknown_post_is_synchronous', function()
            local captures = call({
                method = 'POST',
                path = '/agent/v1/nope',
                headers = {},
                setDataHandler = forbidden,
            })
            local status, body = decode(captures)
            assert(status == 404, 'status ' .. tostring(status))
            assert(body.code == 'not_found')
            return status, { code = body.code }
        end)

        golden('wrong_method_is_synchronous', function()
            local captures = call({
                method = 'GET',
                path = '/agent/v1/act',
                headers = {},
                setDataHandler = forbidden,
            })
            local status, body = decode(captures)
            assert(status == 405, 'status ' .. tostring(status))
            assert(captures[1].headers['Allow'] == 'POST')
            assert(body.code == 'method_not_allowed')
            return status, { code = body.code, allow = captures[1].headers['Allow'] }
        end)

        golden('missing_agent_id_is_synchronous', function()
            local captures = call({
                method = 'POST',
                path = '/agent/v1/act',
                headers = {
                    Authorization = 'Bearer agent-token',
                    ['content-length'] = '2',
                },
                setDataHandler = forbidden,
            })
            local status, body = decode(captures)
            assert(status == 400, 'status ' .. tostring(status))
            assert(body.code == 'missing_agent_id')
            return status, { code = body.code }
        end)

        golden('act_defers_until_body', function()
            local dataHandler
            local captures = call({
                method = 'POST',
                path = '/agent/v1/act',
                headers = {
                    Authorization = 'Bearer agent-token',
                    ['X-Agent-Id'] = 'agent-1',
                    ['content-length'] = '2',
                },
                setDataHandler = function(handler) dataHandler = handler end,
            })
            assert(#captures == 0, 'adapter must wait for the request body')
            assert(dataHandler, 'setDataHandler was not registered')
            dataHandler('{}')
            local status, body = decode(captures)
            assert(status == 400, 'status ' .. tostring(status))
            assert(body.code == 'bad_request')
            assert(body.error == 'type is required')

            dataHandler('{}')
            assert(#captures == 2, 'duplicate body must not send a second response')
            return status, { code = body.code, single_response = true }
        end)

        golden('oversized_content_length_early_413', function()
            local captures = call({
                method = 'POST',
                path = '/agent/v1/act',
                headers = { ['content-length'] = tostring(env.http.MAX_BODY + 1) },
                setDataHandler = forbidden,
            })
            local status, body = decode(captures)
            assert(status == 413, 'status ' .. tostring(status))
            assert(body.code == 'body_too_large')
            return status, { code = body.code }
        end)

        golden('handler_error_becomes_500', function()
            local original = env.http.Handle
            env.http.Handle = function() error('boom', 0) end
            local captures = call({
                method = 'GET',
                path = '/agent/v1/policy',
                headers = { Authorization = 'Bearer agent-token' },
                setDataHandler = forbidden,
            })
            env.http.Handle = original
            local status, body = decode(captures)
            assert(status == 500, 'status ' .. tostring(status))
            assert(body.code == 'internal_error')
            return status, { code = body.code }
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d adapter case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
