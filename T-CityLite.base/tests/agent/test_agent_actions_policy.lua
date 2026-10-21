-- tests/agent/test_agent_actions_policy.lua
--
-- Standalone (no FXServer/DB) tests for custom-director's pure policy layer.
-- Run from the repository root:
--
--   lua5.4 T-CityLite.base/tests/agent/test_agent_actions_policy.lua
--
-- Exit code 0 = all assertions passed. The in-resource selftest is also
-- exercised here so `setr agent_actions_selftest 1` and this runner stay in
-- sync. Nothing in this file writes to the database or touches a player.

local scriptPath = arg[0] or 'T-CityLite.base/tests/agent/test_agent_actions_policy.lua'
local root = scriptPath:match('^(.*)/T%-CityLite%.base/tests/agent/test_agent_actions_policy%.lua$')
if not root or root == '' then root = '.' end

local resourceDir = root .. '/T-CityLite.base/resources/[custom]/custom-director'
local policyPath = resourceDir .. '/server/policy.lua'
local selftestPath = resourceDir .. '/server/selftest.lua'

local okPolicy, policyOrError = pcall(dofile, policyPath)
if not okPolicy then
    io.stderr:write(('[AGENT-ACTION-TEST] FAIL load_policy %s\n'):format(tostring(policyOrError)))
    os.exit(1)
end

local AgentPolicy = policyOrError
local failed = 0
local total = 0

local function check(name, condition, detail)
    total = total + 1
    if not condition then failed = failed + 1 end
    print(('[AGENT-ACTION-TEST] %s %s%s'):format(
        condition and 'PASS' or 'FAIL',
        name,
        detail and (' - ' .. tostring(detail)) or ''))
end

-- 1. Reuse the in-resource selftest (pure policy/preview suite).
local okSelf, selfResultOrError = pcall(dofile, selftestPath)
check('load_selftest', okSelf, okSelf and nil or selfResultOrError)
if okSelf then
    local selfOk, selfCases = selfResultOrError.Run()
    check('selftest_suite', selfOk == true,
        ('%d case(s)'):format(type(selfCases) == 'table' and #selfCases or 0))
end

local cfg = {
    max_money = 1000,
    daily_budget = 5000,
    max_notify_chars = 300,
    ttl_seconds = 900,
}
local player = { source = 12, money = { cash = 250, bank = 1000, crypto = 0 } }
local context = {
    player = player,
    daily_spent = 0,
    quests = {
        courier = { { id = 'courier_01', title = 'Courier Run' } },
        story = { { id = 'story_01', title = 'Story Start' } },
    },
}

-- 2. Status/limit/catalog helpers.
check('status_filter_valid', AgentPolicy.NormalizeStatus('pending_approval') == 'pending_approval')
check('status_filter_invalid', AgentPolicy.NormalizeStatus('approved; DROP TABLE') == nil)
check('limit_default', AgentPolicy.NormalizeLimit(nil, 20, 100) == 20)
check('limit_floor', AgentPolicy.NormalizeLimit(0, 20, 100) == 1)
check('limit_cap', AgentPolicy.NormalizeLimit(999, 20, 100) == 100)

local catalogIndex = AgentPolicy.IndexQuestCatalog(context.quests)
check('catalog_nested', catalogIndex['courier_01'] ~= nil and catalogIndex['story_01'] ~= nil)
check('catalog_find', AgentPolicy.FindQuest(context.quests, 'courier_01').title == 'Courier Run')
check('catalog_missing', AgentPolicy.FindQuest(context.quests, 'nope') == nil)

-- 3. Preview/shape checks beyond the selftest.
local money = AgentPolicy.Normalize('add_money', {
    citizenid = 'ABC12345',
    account = 'bank',
    amount = 1000,
    reason = 'max cap test',
}, cfg)
check('money_cap_boundary', money ~= nil and money.amount == 1000)

local noPlayerPreview = AgentPolicy.Preview('add_money', money, { player = nil }, cfg)
check('preview_offline_player',
    noPlayerPreview.player_found == false and noPlayerPreview.account_exists == false,
    'offline preview must be explicit')

local unknownPreview, unknownPreviewErr = AgentPolicy.Preview('teleport', {}, context, cfg)
check('preview_unknown_action', unknownPreview == nil and unknownPreviewErr.code == 'unsupported_action')

local noCatalogPolicy, noCatalogErr = AgentPolicy.CheckPolicy('start_quest', {
    citizenid = 'ABC12345',
    quest_id = 'courier_01',
}, cfg, { player = player })
check('quest_requires_catalog',
    noCatalogPolicy == false and noCatalogErr.code == 'quest_not_found',
    noCatalogErr and noCatalogErr.code or 'catalog not checked')

-- 4. Envelope/idempotency primitives. The DB layer uses DeepEqual to detect
-- "same key, different action/params" conflicts; JSON key order must not matter.
local paramsA = { citizenid = 'ABC12345', account = 'cash', amount = 250, reason = 'reward' }
local paramsB = { reason = 'reward', amount = 250, account = 'cash', citizenid = 'ABC12345' }
check('idempotency_same_params', AgentPolicy.DeepEqual(paramsA, paramsB) == true)
check('idempotency_different_amount',
    AgentPolicy.DeepEqual(paramsA, { citizenid = 'ABC12345', account = 'cash', amount = 251, reason = 'reward' }) == false)
check('idempotency_key_charset', AgentPolicy.NormalizeIdempotencyKey('beat-1/run.2') == 'beat-1/run.2')
check('idempotency_key_whitespace', AgentPolicy.NormalizeIdempotencyKey('beat 1') == nil)
check('agent_id_length_cap', AgentPolicy.NormalizeAgentId(string.rep('a', 65)) == nil)
check('citizenid_shape', AgentPolicy.NormalizeCitizenId('SIM001_ab12') == 'SIM001_ab12')
check('reason_no_control', AgentPolicy.NormalizeReason('ok\1bad', 128) == nil)

-- 5. Extra normalization invariants.
local extraFields = AgentPolicy.Normalize('notify', {
    citizenid = 'ABC12345',
    text = 'hello',
    beat_id = 'beat_ignored',
}, cfg)
check('unknown_param_fields_dropped', extraFields ~= nil and extraFields.beat_id == nil)

check('text_length_ascii', AgentPolicy.TextLength('abc') == 3)
check('text_length_utf8', AgentPolicy.TextLength('你好') == 2)

print(('[AGENT-ACTION-TEST] RESULT total=%d failed=%d'):format(total, failed))
os.exit(failed == 0 and 0 or 1)
