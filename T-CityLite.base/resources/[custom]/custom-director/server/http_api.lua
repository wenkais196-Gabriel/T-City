-- server/http_api.lua — pure, synchronous HTTP surface for custom-director.
--
-- This file deliberately has no FiveM, MySQL, QBCore or `req`/`res` dependency.
-- It can be loaded by plain Lua 5.4 and driven from tests:
--
--   AgentHttp.Handle({ method=, path=, headers=, body= },
--                    { cfg=, actions=, policy= })
--     -> { status=, body=, headers= }
--
-- The order of checks is part of the contract (see
-- docs/agent/design/05-test-and-eval.md §4.1):
--   1 disabled 503, 2 token 503, 3 route 404, 4 method 405,
--   5 admin token 503, 6 admin auth 401, 7 agent auth 401,
--   8 /policy 200, 9 X-Agent-Id 400, 10 body 400/413, 11 dispatch.
--
-- server/main.lua keeps only the FiveM adapter and calls Handle().

local AgentHttp = {}
_G.AgentHttp = AgentHttp

AgentHttp.MAX_BODY = 16 * 1024
AgentHttp.DEFAULT_LIST_LIMIT = 20
AgentHttp.MAX_LIST_LIMIT = 100

local MAX_HTTP_BODY = AgentHttp.MAX_BODY
local DEFAULT_LIST_LIMIT = AgentHttp.DEFAULT_LIST_LIMIT
local MAX_LIST_LIMIT = AgentHttp.MAX_LIST_LIMIT

-- ---------------------------------------------------------------------------
-- Request parsing helpers
-- ---------------------------------------------------------------------------

local function splitPath(rawPath)
    local queryPos = rawPath:find('?', 1, true)
    if not queryPos then return rawPath, '' end
    return rawPath:sub(1, queryPos - 1), rawPath:sub(queryPos + 1)
end

local function urlDecode(value)
    value = value:gsub('+', ' ')
    return (value:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function parseQuery(query)
    local result = {}
    for pair in query:gmatch('[^&]+') do
        local equals = pair:find('=', 1, true)
        local key, value
        if equals then
            key = pair:sub(1, equals - 1)
            value = pair:sub(equals + 1)
        else
            key = pair
            value = ''
        end
        key = urlDecode(key)
        if key ~= '' then result[key] = urlDecode(value) end
    end
    return result
end

-- Takes the headers table (not the req object) so it is usable in tests.
function AgentHttp.GetHeader(headers, name)
    if type(headers) ~= 'table' then return nil end
    name = tostring(name):lower()
    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == name then
            if type(value) == 'table' then return value[1] end
            return value
        end
    end
    return nil
end

local function bearerToken(headers, policy)
    local authorization = AgentHttp.GetHeader(headers, 'authorization')
    if type(authorization) ~= 'string' then return nil end
    local token = authorization:match('^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$')
    if not token then return nil end
    return policy.Trim(token)
end

local function secureEquals(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then return false end
    if #a == 0 or #b == 0 then return false end
    local diff = #a == #b and 0 or 1
    local maxLength = math.max(#a, #b)
    for index = 1, maxLength do
        local byteA = index <= #a and a:byte(index) or 0
        local byteB = index <= #b and b:byte(index) or 0
        diff = diff | (byteA ~ byteB)
    end
    return diff == 0
end

-- Shared with server/live_api.lua, which is loaded before this file and only
-- dereferences AgentHttp at request time (manifest order: live_* then http_api).
AgentHttp.SplitPath = splitPath
AgentHttp.ParseQuery = parseQuery
AgentHttp.SecureEquals = secureEquals
AgentHttp.BearerToken = bearerToken

-- ---------------------------------------------------------------------------
-- Routes and result mapping
-- ---------------------------------------------------------------------------

function AgentHttp.MatchRoute(path)
    if path == '/agent/v1/act' then
        return { name = 'act', method = 'POST' }
    end
    if path == '/agent/v1/policy' then
        return { name = 'policy', method = 'GET' }
    end
    if path == '/agent/v1/actions' then
        return { name = 'list', method = 'GET' }
    end

    local id = path:match('^/agent/v1/actions/(%d+)$')
    if id then return { name = 'get', method = 'GET', id = tonumber(id) } end

    id = path:match('^/agent/v1/actions/(%d+)/approve$')
    if id then return { name = 'approve', method = 'POST', id = tonumber(id) } end

    id = path:match('^/agent/v1/actions/(%d+)/reject$')
    if id then return { name = 'reject', method = 'POST', id = tonumber(id) } end

    return nil
end

local function httpStatusForResult(result)
    if result.ok then
        if result.status == 'pending_approval' then return 202 end
        return 200
    end

    local code = result.code
    if code == 'disabled' then return 503 end
    if code == 'not_found' then return 404 end
    if code == 'expired' then return 410 end
    if code == 'idempotency_conflict' or code == 'invalid_status' or code == 'execution_failed' then
        return 409
    end
    if code == 'db_error' or code == 'quest_catalog_unavailable' then return 500 end
    return 400
end

-- ---------------------------------------------------------------------------
-- Body decoding (header checks stay in Handle; stream reading in main.lua)
-- ---------------------------------------------------------------------------

-- Returns decoded, errorCode, errorMessage. `json` is a FiveM global in
-- production and provided by the test harness as well.
function AgentHttp.DecodeBody(body)
    if type(body) ~= 'string' then
        return nil, 'missing_body', 'request body must be text'
    end
    if #body > MAX_HTTP_BODY then
        return nil, 'body_too_large', 'request body too large'
    end
    if body == '' then
        return nil, 'bad_request', 'request body is empty'
    end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' then
        return nil, 'bad_request', 'request body must be valid JSON'
    end
    for key in pairs(decoded) do
        if type(key) ~= 'string' then
            return nil, 'bad_request', 'request body must be a JSON object'
        end
    end
    return decoded
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function handleAct(actions, policy, body, agentId)
    local actionType = body.type
    if type(actionType) ~= 'string' then
        return 400, { error = 'type is required', code = 'bad_request' }
    end

    local args = body.args
    if args == nil then args = {} end
    if type(args) ~= 'table' then
        return 400, { error = 'args must be an object', code = 'bad_request' }
    end

    local dryRun = body.dry_run
    if dryRun == nil then dryRun = false end
    if type(dryRun) ~= 'boolean' then
        return 400, { error = 'dry_run must be a boolean', code = 'bad_request' }
    end

    local result = actions.Propose(agentId, actionType, args, body.idempotency_key, dryRun)
    return httpStatusForResult(result), result
end

local function handleAdminAction(actions, policy, body, route)
    local approver, approverErr = policy.NormalizeApprover(body.approver)
    if not approver then
        return 400, { error = approverErr.message, code = approverErr.code }
    end

    local result
    if route.name == 'approve' then
        result = actions.Approve(route.id, approver)
    else
        local reason = nil
        if body.reason ~= nil then
            local reasonErr
            reason, reasonErr = policy.NormalizeReason(body.reason, 255)
            if not reason then
                return 400, { error = reasonErr.message, code = reasonErr.code }
            end
        end
        result = actions.Reject(route.id, approver, reason)
    end

    local statusCode = httpStatusForResult(result)
    if not result.ok and result.status == 'rejected' and statusCode == 400 then
        statusCode = 409
    end
    return statusCode, result
end

-- Validates the body envelope exactly like the old readJsonBody() did.
-- Returns decoded, errorStatus, errorBody, needsBody.
--
-- `request.body == nil` means "the adapter has not read the stream yet": the
-- header checks run synchronously and a body-needing route returns
-- needsBody=true instead of a premature 400. Tests always pass a string.
local function decodeRequest(request)
    local headers = request.headers
    local contentLength = tonumber(AgentHttp.GetHeader(headers, 'content-length'))
    local transferEncoding = AgentHttp.GetHeader(headers, 'transfer-encoding')
    local isChunked = type(transferEncoding) == 'string'
        and transferEncoding:lower():find('chunked', 1, true) ~= nil

    if (contentLength == nil or contentLength == 0) and not isChunked then
        return nil, 400, { error = 'request body required', code = 'missing_body' }
    end
    if contentLength and contentLength > MAX_HTTP_BODY then
        return nil, 413, { error = 'request body too large', code = 'body_too_large' }
    end
    if request.body == nil then
        return nil, nil, nil, true
    end

    local decoded, errCode, errMessage = AgentHttp.DecodeBody(request.body)
    if not decoded then
        return nil, errCode == 'body_too_large' and 413 or 400, { error = errMessage, code = errCode }
    end
    return decoded
end

function AgentHttp.Handle(request, deps)
    local cfg = deps.cfg
    local actions = deps.actions
    local policy = deps.policy
    local headers = request.headers

    -- Live perception owns /agent/v1/live/* only. It is checked before the
    -- actions kill switch so the two switches stay independent; deps.live is
    -- nil in tests/embedders that do not inject the module.
    local live = deps.live
    if type(live) == 'table' and type(live.TryHandle) == 'function' then
        local ok, response = pcall(live.TryHandle, request, cfg)
        if not ok then
            return { status = 500, body = { error = 'internal server error', code = 'internal_error' } }
        end
        if response ~= nil then return response end
    end

    if not cfg.enabled then
        return { status = 503, body = { error = 'agent actions are disabled', code = 'disabled' } }
    end
    if cfg.token == '' then
        return {
            status = 503,
            body = { error = 'agent token is not configured', code = 'agent_token_not_configured' },
        }
    end

    local method = tostring(request.method or ''):upper()
    local path, query = splitPath(tostring(request.path or '/'))
    local route = AgentHttp.MatchRoute(path)
    if not route then
        return { status = 404, body = { error = 'not found', code = 'not_found' } }
    end
    if route.method ~= method then
        return {
            status = 405,
            body = { error = 'method not allowed', code = 'method_not_allowed' },
            headers = { ['Allow'] = route.method },
        }
    end

    -- Admin endpoints use a separate token. The agent token cannot approve.
    if route.name == 'approve' or route.name == 'reject' then
        if cfg.admin_token == '' then
            return {
                status = 503,
                body = { error = 'admin token is not configured', code = 'admin_token_not_configured' },
            }
        end
        if not secureEquals(bearerToken(headers, policy), cfg.admin_token) then
            return {
                status = 401,
                body = { error = 'unauthorized', code = 'unauthorized' },
                headers = { ['WWW-Authenticate'] = 'Bearer' },
            }
        end
        local body, errStatus, errBody, needsBody = decodeRequest(request)
        if needsBody then return { need_body = true } end
        if not body then return { status = errStatus, body = errBody } end
        local statusCode, result = handleAdminAction(actions, policy, body, route)
        return { status = statusCode, body = result }
    end

    if not secureEquals(bearerToken(headers, policy), cfg.token) then
        return {
            status = 401,
            body = { error = 'unauthorized', code = 'unauthorized' },
            headers = { ['WWW-Authenticate'] = 'Bearer' },
        }
    end

    if route.name == 'policy' then
        return { status = 200, body = actions.Policy() }
    end

    local agentId = policy.NormalizeAgentId(AgentHttp.GetHeader(headers, 'x-agent-id'))
    if not agentId then
        return {
            status = 400,
            body = { error = 'X-Agent-Id header is required', code = 'missing_agent_id' },
        }
    end

    if route.name == 'act' then
        local body, errStatus, errBody, needsBody = decodeRequest(request)
        if needsBody then return { need_body = true } end
        if not body then return { status = errStatus, body = errBody } end
        local statusCode, result = handleAct(actions, policy, body, agentId)
        return { status = statusCode, body = result }
    end

    if route.name == 'get' then
        local action, err = actions.Get(route.id)
        if err then
            return { status = 500, body = { error = 'database unavailable', code = 'db_error' } }
        end
        if not action or action.agent_id ~= agentId then
            return { status = 404, body = { error = 'action not found', code = 'not_found' } }
        end
        return { status = 200, body = { action = action } }
    end

    if route.name == 'list' then
        local queryParams = parseQuery(query)
        local status = nil
        if queryParams.status ~= nil then
            local statusErr
            status, statusErr = policy.NormalizeStatus(queryParams.status)
            if not status then
                return { status = 400, body = { error = statusErr.message, code = 'bad_request' } }
            end
        end
        local limit = policy.NormalizeLimit(queryParams.limit, DEFAULT_LIST_LIMIT, MAX_LIST_LIMIT)
        local actionsList, err = actions.List(status, limit, agentId)
        if not actionsList then
            return { status = 500, body = { error = 'database unavailable', code = 'db_error' } }
        end
        return { status = 200, body = { actions = actionsList, count = #actionsList } }
    end

    return { status = 404, body = { error = 'not found', code = 'not_found' } }
end

return AgentHttp
