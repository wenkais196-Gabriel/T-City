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
    max_announce_chars = 300,
    max_item_amount = 50,
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

-- 6. set_job normalization / preview / policy.
local setJob = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'Police',
    grade = 2,
}, cfg)
check('set_job_normalizes_lowercase',
    setJob ~= nil and setJob.job == 'police' and setJob.grade == 2)

local setJobDefault = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'police',
}, cfg)
check('set_job_grade_default', setJobDefault ~= nil and setJobDefault.grade == 0)

local jobBadChars, jobBadCharsErr = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'police!',
}, cfg)
check('set_job_invalid_chars',
    jobBadChars == nil and jobBadCharsErr.code == 'invalid_params',
    jobBadCharsErr and jobBadCharsErr.code or 'accepted')

local jobTooLong = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = string.rep('a', 65),
}, cfg)
check('set_job_length_cap', jobTooLong == nil)

local jobGradeHigh, jobGradeHighErr = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'police',
    grade = 101,
}, cfg)
check('set_job_grade_range',
    jobGradeHigh == nil and jobGradeHighErr.code == 'invalid_params')

local jobGradeFraction = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'police',
    grade = 2.5,
}, cfg)
check('set_job_grade_integer', jobGradeFraction == nil)

local jobGradeString = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'police',
    grade = '2',
}, cfg)
check('set_job_grade_type', jobGradeString == nil)

local jobUnknownField = AgentPolicy.Normalize('set_job', {
    citizenid = 'ABC12345',
    job = 'police',
    reason = 'smuggled field',
}, cfg)
check('set_job_unknown_field_rejected', jobUnknownField == nil)

local jobPlayer = {
    source = 12,
    money = { cash = 250, bank = 1000, crypto = 0 },
    job = { name = 'unemployed', grade = { level = 0 } },
    item_count = 2,
}
local jobContext = {
    player = jobPlayer,
    jobs = {
        police = {
            label = 'Police',
            grades = {
                ['0'] = { name = 'Cadet', payment = 30 },
                ['2'] = { name = 'Officer', payment = 50 },
            },
        },
    },
}

local jobPreview = AgentPolicy.Preview('set_job', setJob, jobContext, cfg)
check('set_job_preview_before',
    jobPreview.before.job == 'unemployed' and jobPreview.before.grade == 0)

local jobPolicy, jobPolicyErr = AgentPolicy.CheckPolicy('set_job', setJob, cfg, jobContext)
check('set_job_policy_ok', jobPolicy == true, jobPolicyErr and jobPolicyErr.code or 'ok')

local missingJob, missingJobErr = AgentPolicy.CheckPolicy('set_job', {
    citizenid = 'ABC12345',
    job = 'ghostjob',
    grade = 0,
}, cfg, jobContext)
check('set_job_missing_job', missingJob == false)
check('set_job_missing_job_code', missingJobErr.code == 'job_not_found',
    missingJobErr and missingJobErr.code or 'no error')

local missingGrade, missingGradeErr = AgentPolicy.CheckPolicy('set_job', {
    citizenid = 'ABC12345',
    job = 'police',
    grade = 7,
}, cfg, jobContext)
check('set_job_missing_grade',
    missingGrade == false and missingGradeErr.code == 'grade_not_found',
    missingGradeErr and missingGradeErr.code or 'accepted')

check('set_job_requires_approval',
    AgentPolicy.RequiresApproval('set_job') == true
        and AgentPolicy.StatusFor('set_job', false) == 'pending_approval')

-- 7. grant_item normalization / preview / policy.
local grantItem = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 10,
    reason = 'director reward',
}, cfg)
check('grant_item_normalizes',
    grantItem ~= nil and grantItem.item == 'bread'
        and grantItem.amount == 10 and grantItem.reason == 'director reward')

local badItemName, badItemErr = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread!',
    amount = 1,
    reason = 'bad',
}, cfg)
check('grant_item_invalid_item',
    badItemName == nil and badItemErr.code == 'invalid_params')

local zeroItem, zeroItemErr = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 0,
    reason = 'zero',
}, cfg)
check('grant_item_amount_zero',
    zeroItem == nil and zeroItemErr.code == 'invalid_params')

local overCapItem, overCapItemErr = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 51,
    reason = 'too many',
}, cfg)
check('grant_item_amount_over_cap',
    overCapItem == nil and overCapItemErr.code == 'invalid_params',
    overCapItemErr and overCapItemErr.code or 'accepted')

local boundaryItem = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 50,
    reason = 'boundary',
}, cfg)
check('grant_item_amount_cap_boundary', boundaryItem ~= nil and boundaryItem.amount == 50)

local customCap = { max_item_amount = 7 }
local customCapOk = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 7,
    reason = 'custom cap',
}, customCap)
check('grant_item_uses_cfg_cap', customCapOk ~= nil and customCapOk.amount == 7)
local customCapOver = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 8,
    reason = 'custom cap',
}, customCap)
check('grant_item_cfg_cap_enforced', customCapOver == nil)

local missingReason, missingReasonErr = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 1,
}, cfg)
check('grant_item_reason_required',
    missingReason == nil and missingReasonErr.code == 'invalid_params')

local controlReason = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 1,
    reason = 'bad\nreason',
}, cfg)
check('grant_item_reason_control_chars', controlReason == nil)

local fractionalItem = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 1.5,
    reason = 'fraction',
}, cfg)
check('grant_item_amount_integer', fractionalItem == nil)

local itemUnknownField = AgentPolicy.Normalize('grant_item', {
    citizenid = 'ABC12345',
    item = 'bread',
    amount = 1,
    reason = 'reward',
    slot = 2,
}, cfg)
check('grant_item_unknown_field_rejected', itemUnknownField == nil)

local itemContext = {
    player = jobPlayer,
    items = {
        bread = { name = 'bread', label = 'Bread' },
    },
}

local itemPreview = AgentPolicy.Preview('grant_item', grantItem, itemContext, cfg)
check('grant_item_preview_before', itemPreview.before == 2 and itemPreview.amount == 10)

local itemPolicy, itemPolicyErr = AgentPolicy.CheckPolicy('grant_item', grantItem, cfg, itemContext)
check('grant_item_policy_ok', itemPolicy == true, itemPolicyErr and itemPolicyErr.code or 'ok')

local missingItem, missingItemErr = AgentPolicy.CheckPolicy('grant_item', {
    citizenid = 'ABC12345',
    item = 'ghostitem',
    amount = 1,
    reason = 'reward',
}, cfg, itemContext)
check('grant_item_missing_item',
    missingItem == false and missingItemErr.code == 'item_not_found',
    missingItemErr and missingItemErr.code or 'accepted')

check('grant_item_requires_approval',
    AgentPolicy.RequiresApproval('grant_item') == true
        and AgentPolicy.StatusFor('grant_item', false) == 'pending_approval')

-- 8. announce (L2 world broadcast).
local announce = AgentPolicy.Normalize('announce', {
    message = 'Server restart in 5 minutes',
    kind = 'warning',
}, cfg)
check('announce_normalizes',
    announce ~= nil and announce.kind == 'warning'
        and announce.message == 'Server restart in 5 minutes')

local announceDefault = AgentPolicy.Normalize('announce', { message = 'hello' }, cfg)
check('announce_kind_defaults_to_info',
    announceDefault ~= nil and announceDefault.kind == 'info')

local announcePreview = AgentPolicy.Preview('announce', announce, {}, cfg)
check('announce_preview_shape',
    announcePreview.kind == 'warning'
        and announcePreview.length == AgentPolicy.TextLength(announce.message)
        and announcePreview.preview == announce.message)

local longAnnounce = AgentPolicy.Preview('announce', {
    message = string.rep('x', 60),
    kind = 'info',
}, {}, cfg)
check('announce_preview_truncates_to_40',
    longAnnounce.preview == string.rep('x', 40) and longAnnounce.length == 60)

local badAnnounceKind, badAnnounceKindErr = AgentPolicy.Normalize('announce', {
    message = 'hello',
    kind = 'script',
}, cfg)
check('announce_kind_whitelist',
    badAnnounceKind == nil and badAnnounceKindErr.code == 'invalid_params')

local longAnnounceText, longAnnounceErr = AgentPolicy.Normalize('announce', {
    message = string.rep('x', 301),
}, cfg)
check('announce_length_cap',
    longAnnounceText == nil and longAnnounceErr.code == 'text_too_long')

local controlAnnounce = AgentPolicy.Normalize('announce', {
    message = 'bad\0text',
}, cfg)
check('announce_control_chars', controlAnnounce == nil)

local announceUnknownField = AgentPolicy.Normalize('announce', {
    message = 'hello',
    citizenid = 'ABC12345',
}, cfg)
check('announce_unknown_field_rejected', announceUnknownField == nil)

local customAnnounceCfg = { max_announce_chars = 5 }
local customAnnounce = AgentPolicy.Normalize('announce', { message = 'hello' }, customAnnounceCfg)
check('announce_uses_cfg_cap', customAnnounce ~= nil)
local overCustomAnnounce = AgentPolicy.Normalize('announce', { message = 'helloo' }, customAnnounceCfg)
check('announce_cfg_cap_enforced', overCustomAnnounce == nil)

local announcePolicy, announcePolicyErr = AgentPolicy.CheckPolicy('announce', announce, cfg, {})
check('announce_policy_allows_no_players', announcePolicy == true,
    announcePolicyErr and announcePolicyErr.code or 'ok')

-- 9. set_weather (L2 world state).
local weather = AgentPolicy.Normalize('set_weather', { weather = 'rain' }, cfg)
check('set_weather_normalizes_uppercase', weather ~= nil and weather.weather == 'RAIN')

local badWeather, badWeatherErr = AgentPolicy.Normalize('set_weather', {
    weather = 'SANDSTORM',
}, cfg)
check('set_weather_enum_whitelist',
    badWeather == nil and badWeatherErr.code == 'invalid_params')

local weatherUnknownField = AgentPolicy.Normalize('set_weather', {
    weather = 'RAIN',
    citizenid = 'ABC12345',
}, cfg)
check('set_weather_unknown_field_rejected', weatherUnknownField == nil)

local weatherPreview = AgentPolicy.Preview('set_weather', weather, { weather = 'CLEAR' }, cfg)
check('set_weather_preview_before',
    weatherPreview.weather == 'RAIN' and weatherPreview.before == 'CLEAR')

local weatherPolicy, weatherPolicyErr = AgentPolicy.CheckPolicy('set_weather', weather, cfg, {
    weather_sync = true,
})
check('set_weather_policy_ok', weatherPolicy == true,
    weatherPolicyErr and weatherPolicyErr.code or 'ok')

local weatherStopped, weatherStoppedErr = AgentPolicy.CheckPolicy('set_weather', weather, cfg, {})
check('set_weather_requires_weathersync',
    weatherStopped == false and weatherStoppedErr.code == 'weather_sync_unavailable')

-- 10. set_time_of_day (L2 world state).
local timeOfDay = AgentPolicy.Normalize('set_time_of_day', { hour = 22 }, cfg)
check('set_time_normalizes_default_minute',
    timeOfDay ~= nil and timeOfDay.hour == 22 and timeOfDay.minute == 0)

local explicitTime = AgentPolicy.Normalize('set_time_of_day', {
    hour = 7,
    minute = 30,
}, cfg)
check('set_time_normalizes_explicit_minute',
    explicitTime ~= nil and explicitTime.hour == 7 and explicitTime.minute == 30)

local hourHigh = AgentPolicy.Normalize('set_time_of_day', { hour = 24 }, cfg)
local hourLow = AgentPolicy.Normalize('set_time_of_day', { hour = -1 }, cfg)
check('set_time_hour_range', hourHigh == nil and hourLow == nil)

local minuteHigh = AgentPolicy.Normalize('set_time_of_day', { hour = 12, minute = 60 }, cfg)
local minuteLow = AgentPolicy.Normalize('set_time_of_day', { hour = 12, minute = -1 }, cfg)
check('set_time_minute_range', minuteHigh == nil and minuteLow == nil)

local fractionalHour = AgentPolicy.Normalize('set_time_of_day', { hour = 1.5 }, cfg)
check('set_time_hour_integer', fractionalHour == nil)

local timeUnknownField = AgentPolicy.Normalize('set_time_of_day', {
    hour = 12,
    frozen = true,
}, cfg)
check('set_time_unknown_field_rejected', timeUnknownField == nil)

local timePreview = AgentPolicy.Preview('set_time_of_day', timeOfDay, {}, cfg)
check('set_time_preview', timePreview.hour == 22 and timePreview.minute == 0)

local timePolicy, timePolicyErr = AgentPolicy.CheckPolicy('set_time_of_day', timeOfDay, cfg, {
    weather_sync = true,
})
check('set_time_policy_ok', timePolicy == true,
    timePolicyErr and timePolicyErr.code or 'ok')

local timeStopped, timeStoppedErr = AgentPolicy.CheckPolicy('set_time_of_day', timeOfDay, cfg, {})
check('set_time_requires_weathersync',
    timeStopped == false and timeStoppedErr.code == 'weather_sync_unavailable')

check('world_actions_approval_metadata',
    AgentPolicy.ACTIONS.announce.risk == 'L2'
        and AgentPolicy.ACTIONS.set_weather.risk == 'L2'
        and AgentPolicy.ACTIONS.set_time_of_day.risk == 'L2'
        and AgentPolicy.ACTIONS.announce.blast_radius == 'world'
        and AgentPolicy.ACTIONS.set_weather.blast_radius == 'world'
        and AgentPolicy.ACTIONS.set_time_of_day.blast_radius == 'world'
        and AgentPolicy.ACTIONS.announce.requires_approval == true
        and AgentPolicy.ACTIONS.set_weather.requires_approval == true
        and AgentPolicy.ACTIONS.set_time_of_day.requires_approval == true
        and AgentPolicy.ACTIONS.announce.auto_execute == false
        and AgentPolicy.ACTIONS.set_weather.auto_execute == false
        and AgentPolicy.ACTIONS.set_time_of_day.auto_execute == false)

print(('[AGENT-ACTION-TEST] RESULT total=%d failed=%d'):format(total, failed))
os.exit(failed == 0 and 0 or 1)
