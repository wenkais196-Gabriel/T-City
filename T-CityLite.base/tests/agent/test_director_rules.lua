-- tests/agent/test_director_rules.lua
--
-- Standalone (no FXServer/DB) tests for the pure director rule table (#31).
-- Run from the repository root:
--
--   lua5.4 T-CityLite.base/tests/agent/test_director_rules.lua
--
-- Exit code 0 = all assertions passed. Nothing here reads player data, writes
-- to the database or starts a quest.

local scriptPath = arg[0] or 'T-CityLite.base/tests/agent/test_director_rules.lua'
local root = scriptPath:match('^(.*)/T%-CityLite%.base/tests/agent/test_director_rules%.lua$')
if not root or root == '' then root = '.' end

local dirCandidates = {
    root .. '/T-CityLite.base/resources/[custom]/custom-director',
    'T-CityLite.base/resources/[custom]/custom-director',
    'resources/[custom]/custom-director',
    '../resources/[custom]/custom-director',
}

local resourceDir = nil
for _, dir in ipairs(dirCandidates) do
    local handle = io.open(dir .. '/server/director_rules.lua', 'r')
    if handle then
        handle:close()
        resourceDir = dir
        break
    end
end

if not resourceDir then
    io.stderr:write('[DIRECTOR-RULES-TEST] FAIL load_rules resource directory not found\n')
    os.exit(1)
end

local okRules, rulesOrError = pcall(dofile, resourceDir .. '/server/director_rules.lua')
if not okRules then
    io.stderr:write(('[DIRECTOR-RULES-TEST] FAIL load_rules %s\n'):format(tostring(rulesOrError)))
    os.exit(1)
end

local DirectorRules = rulesOrError
local failed = 0
local total = 0

local function check(name, condition, detail)
    total = total + 1
    if not condition then failed = failed + 1 end
    print(('[DIRECTOR-RULES-TEST] %s %s%s'):format(
        condition and 'PASS' or 'FAIL',
        name,
        detail and (' - ' .. tostring(detail)) or ''))
end

local function readFile(path)
    local handle = io.open(path, 'r')
    if not handle then return nil end
    local content = handle:read('*a')
    handle:close()
    return content
end

-- ---------------------------------------------------------------------------
-- 1. Safe rule map
-- ---------------------------------------------------------------------------

local civilianCh1 = { quest_id = 'civilian_ch1_first_dollar', step_id = 'step_decision' }

check('civilian_ch1_to_ch2',
    DirectorRules.followUpQuest('quest.completed', civilianCh1) == 'civilian_ch2_startup_struggle')
check('police_ch1_to_ch2',
    DirectorRules.followUpQuest('quest.completed', { quest_id = 'police_ch1_first_shift' })
        == 'police_ch2_corruption_web')

-- ch1 requires role=civilian, ch2 requires role=gang_member: not a guaranteed
-- natural follow-up, so the rule is deliberately omitted.
check('cartel_ch1_omitted',
    DirectorRules.followUpQuest('quest.completed', { quest_id = 'cartel_ch1_first_blood' }) == nil)

check('unknown_event_type',
    DirectorRules.followUpQuest('quest.started', civilianCh1) == nil
        and DirectorRules.followUpQuest('story.choice', civilianCh1) == nil)
check('unknown_completed_quest',
    DirectorRules.followUpQuest('quest.completed', { quest_id = 'civilian_ch1_made_up' }) == nil)

-- ---------------------------------------------------------------------------
-- 2. Tolerant payload extraction
-- ---------------------------------------------------------------------------

check('extract_table', DirectorRules.extractCompletedQuest(civilianCh1) == 'civilian_ch1_first_dollar')
check('extract_json_string',
    DirectorRules.extractCompletedQuest('{"quest_id":"civilian_ch1_first_dollar","step_id":"step_decision"}')
        == 'civilian_ch1_first_dollar')
check('extract_json_string_whitespace',
    DirectorRules.extractCompletedQuest(
        '{ "quest_id" : "civilian_ch1_first_dollar", "metadata": { "k": 1 } }')
        == 'civilian_ch1_first_dollar')
check('extract_missing_field', DirectorRules.extractCompletedQuest({ step_id = 'x' }) == nil)
check('extract_malformed_string', DirectorRules.extractCompletedQuest('not json') == nil)
check('extract_empty_string', DirectorRules.extractCompletedQuest('') == nil)
check('extract_nil', DirectorRules.extractCompletedQuest(nil) == nil)
check('extract_number', DirectorRules.extractCompletedQuest(42) == nil)

check('follow_up_json_payload',
    DirectorRules.followUpQuest('quest.completed',
        '{"quest_id":"civilian_ch1_first_dollar"}') == 'civilian_ch2_startup_struggle')

-- ---------------------------------------------------------------------------
-- 3. Stable idempotency key
-- ---------------------------------------------------------------------------

local key = DirectorRules.idempotencyKey(42, 'quest.completed', 'civilian_ch2_startup_struggle')
check('idempotency_key_exact',
    key == 'director:event:42:quest.completed:civilian_ch2_startup_struggle',
    key)
check('idempotency_key_stable',
    DirectorRules.idempotencyKey(42, 'quest.completed', 'civilian_ch2_startup_struggle') == key)
check('idempotency_key_event_changes',
    DirectorRules.idempotencyKey(43, 'quest.completed', 'civilian_ch2_startup_struggle') ~= key)
check('idempotency_key_quest_changes',
    DirectorRules.idempotencyKey(42, 'quest.completed', 'police_ch2_corruption_web') ~= key)
check('idempotency_key_fits_broker_cap', #key <= 128, ('len=%d'):format(#key))
check('idempotency_key_nil', DirectorRules.idempotencyKey(nil, 'quest.completed', 'x') == nil)
check('idempotency_key_empty_type', DirectorRules.idempotencyKey(1, '', 'x') == nil)
check('idempotency_key_empty_target', DirectorRules.idempotencyKey(1, 'quest.completed', '') == nil)

-- ---------------------------------------------------------------------------
-- 4. Source guardrails: propose only, never approve/execute
-- ---------------------------------------------------------------------------

local directorSource = readFile(resourceDir .. '/server/director.lua')
check('director_source_readable', directorSource ~= nil)
if directorSource then
    check('director_uses_agent_actions_propose',
        directorSource:find('AgentActions%.Propose', 1) ~= nil)
    check('director_never_calls_approve',
        directorSource:find('Approve', 1) == nil)
    check('director_exports_run_once',
        directorSource:find("exports%('RunOnce'", 1) ~= nil)
end

print(('[DIRECTOR-RULES-TEST] RESULT total=%d failed=%d'):format(total, failed))
os.exit(failed == 0 and 0 or 1)
