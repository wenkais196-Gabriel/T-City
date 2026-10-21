-- server/selftest.lua — pure policy/preview assertions for custom-director.
--
-- Enable once per resource start with:
--   setr agent_actions_selftest 1
--
-- Output lines start with [AGENT-ACTIONS-SELFTEST]. This file does not touch
-- the database, QBCore players, quests or client events. It is also loaded by
-- the standalone Lua test runner with `lua5.4`.

local AgentPolicy = _G.AgentPolicy
local AgentActionsSelfTest = {}

local function newCase(name, ok, detail)
    return { name = name, ok = ok and true or false, detail = detail }
end

function AgentActionsSelfTest.Run()
    if not AgentPolicy then
        return false, { newCase('policy_loaded', false, 'AgentPolicy global missing') }
    end

    local cases = {}
    local function check(name, condition, detail)
        cases[#cases + 1] = newCase(name, condition, detail)
    end

    local cfg = {
        max_money = 1000,
        daily_budget = 5000,
        max_notify_chars = 300,
        ttl_seconds = 900,
    }

    local player = {
        source = 5,
        money = { cash = 100, bank = 900, crypto = 0 },
    }
    local context = {
        player = player,
        daily_spent = 0,
        quests = {
            delivery = {
                { id = 'delivery_001', title = 'First Delivery', category = 'delivery' },
            },
        },
    }

    -- Unknown actions ---------------------------------------------------------
    local normalized, err = AgentPolicy.Normalize('drop_database', { citizenid = 'ABC12345' }, cfg)
    check('unknown_action_rejected', normalized == nil and err and err.code == 'unsupported_action',
        err and err.code or 'no error')

    -- notify ------------------------------------------------------------------
    local notify, notifyErr = AgentPolicy.Normalize('notify', {
        citizenid = 'ABC12345',
        text = 'The docks are quiet tonight.',
    }, cfg)
    check('notify_normalizes', notify ~= nil and notify.kind == 'info', notifyErr and notifyErr.message or 'ok')

    local notifyPreview = notify and AgentPolicy.Preview('notify', notify, context, cfg)
    check('notify_preview',
        notifyPreview ~= nil
            and notifyPreview.player_found == true
            and notifyPreview.text_length == 28
            and notifyPreview.kind == 'info',
        notifyPreview and ('len=' .. tostring(notifyPreview.text_length)) or 'no preview')

    local notifyPolicy, notifyPolicyErr = AgentPolicy.CheckPolicy('notify', notify, cfg, context)
    check('notify_policy_auto',
        notifyPolicy == true
            and AgentPolicy.RequiresApproval('notify') == false
            and AgentPolicy.StatusFor('notify', false) == 'approved',
        notifyPolicyErr and notifyPolicyErr.code or 'ok')

    local longText = AgentPolicy.Normalize('notify', {
        citizenid = 'ABC12345',
        text = string.rep('x', 301),
    }, cfg)
    check('notify_length_cap', longText == nil, '301-char text must be rejected')

    local controlText = AgentPolicy.Normalize('notify', {
        citizenid = 'ABC12345',
        text = 'bad\0text',
    }, cfg)
    check('notify_control_chars', controlText == nil, 'NUL must be rejected')

    local badKind = AgentPolicy.Normalize('notify', {
        citizenid = 'ABC12345',
        text = 'hello',
        kind = 'script',
    }, cfg)
    check('notify_kind_whitelist', badKind == nil, 'unknown kind must be rejected')

    local offlineNotify = AgentPolicy.CheckPolicy('notify', notify, cfg, { player = nil })
    check('notify_requires_online_player', offlineNotify == false, 'offline target must be rejected')

    -- add_money --------------------------------------------------------------
    local money, moneyErr = AgentPolicy.Normalize('add_money', {
        citizenid = 'ABC12345',
        account = 'cash',
        amount = 250,
        reason = 'director reward',
    }, cfg)
    check('money_normalizes',
        money ~= nil and money.amount == 250 and money.account == 'cash',
        moneyErr and moneyErr.message or 'ok')

    local moneyPreview = money and AgentPolicy.Preview('add_money', money, context, cfg)
    check('money_preview_before_after',
        moneyPreview ~= nil
            and moneyPreview.before == 100
            and moneyPreview.after == 350
            and moneyPreview.daily_budget == 5000
            and moneyPreview.daily_remaining == 5000,
        moneyPreview and ('before=' .. tostring(moneyPreview.before) .. ' after=' .. tostring(moneyPreview.after)) or 'no preview')

    check('money_always_requires_approval',
        AgentPolicy.RequiresApproval('add_money') == true
            and AgentPolicy.StatusFor('add_money', false) == 'pending_approval'
            and AgentPolicy.StatusFor('add_money', true) == 'proposed',
        'add_money must never auto-execute')

    local moneyPolicy, moneyPolicyErr = AgentPolicy.CheckPolicy('add_money', money, cfg, context)
    check('money_policy_ok', moneyPolicy == true, moneyPolicyErr and moneyPolicyErr.code or 'ok')

    local overCap = AgentPolicy.Normalize('add_money', {
        citizenid = 'ABC12345',
        account = 'bank',
        amount = 1001,
        reason = 'too much',
    }, cfg)
    check('money_cap', overCap == nil, 'amount above max_money must be rejected')

    local zero = AgentPolicy.Normalize('add_money', {
        citizenid = 'ABC12345',
        account = 'bank',
        amount = 0,
        reason = 'zero',
    }, cfg)
    check('money_minimum', zero == nil, 'zero must be rejected')

    local fractional = AgentPolicy.Normalize('add_money', {
        citizenid = 'ABC12345',
        account = 'bank',
        amount = 10.5,
        reason = 'fraction',
    }, cfg)
    check('money_integer', fractional == nil, 'fractional amount must be rejected')

    local badAccount = AgentPolicy.Normalize('add_money', {
        citizenid = 'ABC12345',
        account = 'black_money',
        amount = 10,
        reason = 'bad account',
    }, cfg)
    check('money_account_whitelist', badAccount == nil, 'unknown account must be rejected')

    local budgetContext = {
        player = player,
        daily_spent = 4900,
        quests = context.quests,
    }
    local budgetPolicy, budgetErr = AgentPolicy.CheckPolicy('add_money', money, cfg, budgetContext)
    check('money_daily_budget', budgetPolicy == false and budgetErr and budgetErr.code == 'daily_budget_exceeded',
        budgetErr and budgetErr.code or 'budget not enforced')

    local poorPlayerContext = {
        player = { source = 6, money = {} },
        daily_spent = 0,
        quests = context.quests,
    }
    local accountPolicy, accountErr = AgentPolicy.CheckPolicy('add_money', money, cfg, poorPlayerContext)
    check('money_account_available',
        accountPolicy == false and accountErr and accountErr.code == 'account_unavailable',
        accountErr and accountErr.code or 'account not checked')

    -- start_quest ------------------------------------------------------------
    local quest, questErr = AgentPolicy.Normalize('start_quest', {
        citizenid = 'ABC12345',
        quest_id = 'delivery_001',
    }, cfg)
    check('quest_normalizes', quest ~= nil, questErr and questErr.message or 'ok')

    local questPreview = quest and AgentPolicy.Preview('start_quest', quest, context, cfg)
    check('quest_preview_found',
        questPreview ~= nil and questPreview.quest_found == true and questPreview.quest_title == 'First Delivery',
        questPreview and tostring(questPreview.quest_found) or 'no preview')

    local questPolicy, questPolicyErr = AgentPolicy.CheckPolicy('start_quest', quest, cfg, context)
    check('quest_policy_ok', questPolicy == true, questPolicyErr and questPolicyErr.code or 'ok')
    check('quest_requires_approval',
        AgentPolicy.RequiresApproval('start_quest') == true
            and AgentPolicy.StatusFor('start_quest', false) == 'pending_approval',
        'start_quest must require approval')

    local unknownQuest, unknownQuestErr = AgentPolicy.Normalize('start_quest', {
        citizenid = 'ABC12345',
        quest_id = 'does_not_exist',
    }, cfg)
    check('quest_normalizes_unknown_id', unknownQuest ~= nil and unknownQuestErr == nil, 'id shape is valid')
    local missingQuestPolicy, missingQuestErr = AgentPolicy.CheckPolicy('start_quest', unknownQuest, cfg, context)
    check('quest_missing_rejected',
        missingQuestPolicy == false and missingQuestErr and missingQuestErr.code == 'quest_not_found',
        missingQuestErr and missingQuestErr.code or 'missing quest not rejected')

    local flatCatalog = { { id = 'flat_001', title = 'Flat' }, { id = 'flat_002', title = 'Flat 2' } }
    local flatPreview = AgentPolicy.Preview('start_quest', {
        citizenid = 'ABC12345',
        quest_id = 'flat_002',
    }, { player = player, quests = flatCatalog }, cfg)
    check('quest_catalog_flat_array', flatPreview.quest_found == true, 'flat catalog should be indexed')

    -- Envelope helpers -------------------------------------------------------
    local validAgent = AgentPolicy.NormalizeAgentId('director.local')
    check('agent_id_ok', validAgent == 'director.local', tostring(validAgent))
    local invalidAgent = AgentPolicy.NormalizeAgentId('bad agent!')
    check('agent_id_rejected', invalidAgent == nil, 'spaces/bangs must be rejected')
    local invalidKey = AgentPolicy.NormalizeIdempotencyKey('key with space')
    check('idem_key_rejected', invalidKey == nil, 'spaces must be rejected')
    check('text_length_utf8', AgentPolicy.TextLength('你好') == 2, 'utf8 length')
    check('deep_equal',
        AgentPolicy.DeepEqual({ a = 1, b = { c = 2 } }, { b = { c = 2 }, a = 1 }) == true
            and AgentPolicy.DeepEqual({ a = 1 }, { a = 2 }) == false,
        'order-independent equality')

    local failed = 0
    local prefix = '[AGENT-ACTIONS-SELFTEST]'
    for _, case in ipairs(cases) do
        if not case.ok then failed = failed + 1 end
        print(('%s %s %s%s'):format(
            prefix,
            case.ok and 'PASS' or 'FAIL',
            case.name,
            case.detail and (' - ' .. tostring(case.detail)) or ''))
    end
    print(('%s RESULT passed=%d failed=%d'):format(prefix, #cases - failed, failed))

    return failed == 0, cases
end

_G.AgentActionsSelfTest = AgentActionsSelfTest

if type(GetConvar) == 'function' and GetConvar('agent_actions_selftest', '0') == '1' then
    AgentActionsSelfTest.Run()
end

return AgentActionsSelfTest
