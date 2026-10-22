-- policy.lua — pure validation, preview and policy helpers for custom-director.
--
-- This file deliberately has no FiveM, MySQL, QBCore or fs/native dependency.
-- It can be loaded by plain Lua 5.4 (see tests/agent/test_agent_actions_policy.lua)
-- and by the resource (server/policy.lua listed in fxmanifest.lua).
--
-- All functions are server-side only. Nothing here trusts a client.

local AgentPolicy = {}

-- ---------------------------------------------------------------------------
-- Action registry
-- ---------------------------------------------------------------------------
-- L1 表现类：notify（自动执行）
-- L3 任务类：start_quest（需人工审批）
-- L3 职业类：set_job（需人工审批）
-- L4 经济类：add_money（需人工审批 + 每日预算）
-- L4 物品类：grant_item（需人工审批，不计入 add_money 每日预算）
AgentPolicy.ACTIONS = {
    notify = {
        risk = 'L1',
        requires_approval = false,
        auto_execute = true,
    },
    add_money = {
        risk = 'L4',
        requires_approval = true,
        auto_execute = false,
    },
    start_quest = {
        risk = 'L3',
        requires_approval = true,
        auto_execute = false,
    },
    set_job = {
        risk = 'L3',
        requires_approval = true,
        auto_execute = false,
    },
    grant_item = {
        risk = 'L4',
        requires_approval = true,
        auto_execute = false,
    },
}

AgentPolicy.STATUSES = {
    proposed = true,
    pending_approval = true,
    approved = true,
    executed = true,
    rejected = true,
    failed = true,
}

AgentPolicy.NOTIFY_KINDS = {
    info = true,
    success = true,
    warning = true,
    error = true,
    primary = true,
}

AgentPolicy.ACCOUNTS = {
    cash = true,
    bank = true,
    crypto = true,
}

-- Safe defaults, mirrored by the convars in server/main.lua.
AgentPolicy.DEFAULTS = {
    max_money = 1000,
    daily_budget = 5000,
    max_notify_chars = 300,
    max_item_amount = 50,
    ttl_seconds = 900,
}

local function fail(code, message)
    return nil, { code = code, message = message }
end

local function failBool(code, message)
    return false, { code = code, message = message }
end

function AgentPolicy.Error(code, message)
    return { code = code, message = message }
end

-- ---------------------------------------------------------------------------
-- Primitive helpers
-- ---------------------------------------------------------------------------

function AgentPolicy.Trim(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

function AgentPolicy.TextLength(value)
    if type(value) ~= 'string' then return 0 end
    if utf8 and utf8.len then
        local ok, length = pcall(utf8.len, value)
        if ok and length then return length end
    end
    return #value
end

function AgentPolicy.HasUnsafeControlChars(value)
    if type(value) ~= 'string' then return true end
    for i = 1, #value do
        local byte = value:byte(i)
        if (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) or byte == 127 then
            return true
        end
    end
    return false
end

-- Strict variant for single-line audit fields: rejects tab/LF/CR as well.
function AgentPolicy.HasControlChars(value)
    if type(value) ~= 'string' then return true end
    for i = 1, #value do
        local byte = value:byte(i)
        if byte < 32 or byte == 127 then return true end
    end
    return false
end

local function cleanString(value, field, maxLength, pattern)
    if type(value) ~= 'string' then
        return fail('invalid_params', ('%s must be a string'):format(field))
    end
    local cleaned = AgentPolicy.Trim(value)
    if #cleaned == 0 then
        return fail('invalid_params', ('%s is required'):format(field))
    end
    if #cleaned > maxLength then
        return fail('invalid_params', ('%s exceeds %d characters'):format(field, maxLength))
    end
    if pattern and not cleaned:match(pattern) then
        return fail('invalid_params', ('%s has invalid characters'):format(field))
    end
    if AgentPolicy.HasUnsafeControlChars(cleaned) then
        return fail('invalid_params', ('%s contains control characters'):format(field))
    end
    return cleaned
end

-- Reject anything outside the action's documented schema. Existing actions
-- keep their historical "unknown keys are dropped" behaviour; set_job and
-- grant_item opt into this stricter check.
local function rejectUnknownFields(params, allowed, actionType)
    for key in pairs(params) do
        if not allowed[key] then
            return { code = 'invalid_params', message = ('unknown field %s for %s'):format(
                tostring(key), actionType) }
        end
    end
    return nil
end

function AgentPolicy.DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for key, value in pairs(a) do
        if not AgentPolicy.DeepEqual(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Identity / envelope validation
-- ---------------------------------------------------------------------------

function AgentPolicy.NormalizeAgentId(value)
    return cleanString(value, 'agent_id', 64, '^[%w_%.:%-]+$')
end

function AgentPolicy.NormalizeIdempotencyKey(value)
    return cleanString(value, 'idempotency_key', 128, '^[%g]+$')
end

function AgentPolicy.NormalizeApprover(value)
    return cleanString(value, 'approver', 64)
end

function AgentPolicy.NormalizeReason(value, maxLength)
    if value == nil then return nil end
    return cleanString(value, 'reason', maxLength or 128)
end

function AgentPolicy.NormalizeCitizenId(value)
    return cleanString(value, 'citizenid', 11, '^[%w_%-]+$')
end

function AgentPolicy.NormalizeStatus(value)
    if value == nil then return nil end
    if type(value) ~= 'string' then
        return fail('invalid_params', 'status must be a string')
    end
    local status = AgentPolicy.Trim(value):lower()
    if not AgentPolicy.STATUSES[status] then
        return fail('invalid_params', 'unknown status filter')
    end
    return status
end

function AgentPolicy.NormalizeLimit(value, defaultLimit, maxLimit)
    local limit = tonumber(value)
    if not limit or limit ~= limit then limit = defaultLimit end
    limit = math.floor(limit)
    if limit < 1 then limit = 1 end
    if limit > maxLimit then limit = maxLimit end
    return limit
end

-- ---------------------------------------------------------------------------
-- Action argument validation / normalization
-- ---------------------------------------------------------------------------
-- Returns normalized params (only known fields) or nil, {code, message}.
function AgentPolicy.Normalize(actionType, params, cfg)
    cfg = cfg or {}
    local maxMoney = cfg.max_money or AgentPolicy.DEFAULTS.max_money
    local maxNotifyChars = cfg.max_notify_chars or AgentPolicy.DEFAULTS.max_notify_chars
    local maxItemAmount = cfg.max_item_amount or AgentPolicy.DEFAULTS.max_item_amount

    if type(actionType) ~= 'string' or not AgentPolicy.ACTIONS[actionType] then
        return fail('unsupported_action', 'unsupported action type')
    end
    if type(params) ~= 'table' then
        return fail('invalid_params', 'args must be a JSON object')
    end
    for key in pairs(params) do
        if type(key) ~= 'string' then
            return fail('invalid_params', 'args must be a JSON object, not an array')
        end
    end

    local citizenid, err = AgentPolicy.NormalizeCitizenId(params.citizenid)
    if not citizenid then return nil, err end

    if actionType == 'notify' then
        if type(params.text) ~= 'string' then
            return fail('invalid_params', 'text must be a string')
        end
        if AgentPolicy.HasUnsafeControlChars(params.text) then
            return fail('invalid_params', 'text contains control characters')
        end
        local textLength = AgentPolicy.TextLength(params.text)
        if textLength < 1 then
            return fail('invalid_params', 'text is required')
        end
        if textLength > maxNotifyChars then
            return fail('text_too_long', ('text exceeds %d characters'):format(maxNotifyChars))
        end

        local kind = 'info'
        if params.kind ~= nil then
            if type(params.kind) ~= 'string' then
                return fail('invalid_params', 'kind must be a string')
            end
            kind = params.kind:lower()
            if not AgentPolicy.NOTIFY_KINDS[kind] then
                return fail('invalid_params', 'kind must be info, success, warning, error or primary')
            end
        end

        return {
            citizenid = citizenid,
            text = params.text,
            kind = kind,
        }
    end

    if actionType == 'add_money' then
        if type(params.account) ~= 'string' then
            return fail('invalid_params', 'account must be a string')
        end
        local account = params.account:lower()
        if not AgentPolicy.ACCOUNTS[account] then
            return fail('invalid_account', 'account must be cash, bank or crypto')
        end

        local amount = params.amount
        if type(amount) ~= 'number' or amount ~= amount or amount == math.huge or amount == -math.huge then
            return fail('invalid_params', 'amount must be a finite number')
        end
        if amount ~= math.floor(amount) then
            return fail('invalid_params', 'amount must be a whole number')
        end
        if amount < 1 then
            return fail('invalid_params', 'amount must be at least 1')
        end
        if amount > maxMoney then
            return fail('money_cap_exceeded', ('amount exceeds per-action cap of %d'):format(maxMoney))
        end

        local reason, reasonErr = cleanString(params.reason, 'reason', 128)
        if not reason then return nil, reasonErr end

        return {
            citizenid = citizenid,
            account = account,
            amount = math.tointeger(amount) or amount,
            reason = reason,
        }
    end

    if actionType == 'start_quest' then
        local questId, questErr = cleanString(params.quest_id, 'quest_id', 64, '^[%w_%.:%-]+$')
        if not questId then return nil, questErr end
        return {
            citizenid = citizenid,
            quest_id = questId,
        }
    end

    if actionType == 'set_job' then
        local unknownErr = rejectUnknownFields(params, {
            citizenid = true,
            job = true,
            grade = true,
        }, 'set_job')
        if unknownErr then return nil, unknownErr end

        local job, jobErr = cleanString(params.job, 'job', 64, '^[A-Za-z0-9_.%-]+$')
        if not job then return nil, jobErr end

        local grade = params.grade
        if grade == nil then grade = 0 end
        if type(grade) ~= 'number' or grade ~= grade or grade == math.huge or grade == -math.huge then
            return fail('invalid_params', 'grade must be a finite integer')
        end
        if grade ~= math.floor(grade) then
            return fail('invalid_params', 'grade must be a whole number')
        end
        if grade < 0 or grade > 100 then
            return fail('invalid_params', 'grade must be between 0 and 100')
        end

        return {
            citizenid = citizenid,
            job = job:lower(),
            grade = math.tointeger(grade) or grade,
        }
    end

    if actionType == 'grant_item' then
        local unknownErr = rejectUnknownFields(params, {
            citizenid = true,
            item = true,
            amount = true,
            reason = true,
        }, 'grant_item')
        if unknownErr then return nil, unknownErr end

        local item, itemErr = cleanString(params.item, 'item', 64, '^[A-Za-z0-9_.:%-]+$')
        if not item then return nil, itemErr end

        local amount = params.amount
        if type(amount) ~= 'number' or amount ~= amount or amount == math.huge or amount == -math.huge then
            return fail('invalid_params', 'amount must be a finite number')
        end
        if amount ~= math.floor(amount) then
            return fail('invalid_params', 'amount must be a whole number')
        end
        if amount < 1 then
            return fail('invalid_params', 'amount must be at least 1')
        end
        if amount > maxItemAmount then
            return fail('invalid_params', ('amount exceeds per-action cap of %d'):format(maxItemAmount))
        end

        local reason, reasonErr = cleanString(params.reason, 'reason', 128)
        if not reason then return nil, reasonErr end
        if AgentPolicy.HasControlChars(reason) then
            return fail('invalid_params', 'reason contains control characters')
        end

        return {
            citizenid = citizenid,
            item = item,
            amount = math.tointeger(amount) or amount,
            reason = reason,
        }
    end

    return fail('unsupported_action', 'unsupported action type')
end

-- ---------------------------------------------------------------------------
-- Quest catalog helpers (custom-quest GetQuestCatalog shape)
-- ---------------------------------------------------------------------------
-- GetCategorizedList() returns { [category] = { {id=...}, ... } }.  Be tolerant
-- of a flat array or a quest map so this keeps working if the export changes.
function AgentPolicy.IndexQuestCatalog(catalog)
    local index = {}
    if type(catalog) ~= 'table' then return index end

    local function consider(quest)
        if type(quest) == 'table' and type(quest.id) == 'string' and quest.id ~= '' then
            index[quest.id] = quest
        end
    end

    consider(catalog)
    for _, value in pairs(catalog) do
        if type(value) == 'table' then
            if type(value.id) == 'string' then
                consider(value)
            else
                for _, quest in ipairs(value) do
                    consider(quest)
                end
            end
        end
    end
    return index
end

function AgentPolicy.FindQuest(catalog, questId)
    if type(questId) ~= 'string' then return nil end
    return AgentPolicy.IndexQuestCatalog(catalog)[questId]
end

-- ---------------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------------
-- Pure: callers gather live player/quest context.
-- ctx = {
--   player = { source = number, money = { cash=, bank=, crypto= },
--              job = PlayerData.job, item_count = number } | nil,
--   quests = GetQuestCatalog() result | nil,
--   jobs = QBCore.Shared.Jobs | nil,
--   items = QBCore.Shared.Items | nil,
--   daily_spent = number (add_money only, excluding the row being approved)
-- }
function AgentPolicy.Preview(actionType, params, ctx, cfg)
    local definition = AgentPolicy.ACTIONS[actionType]
    if not definition then
        return fail('unsupported_action', 'unsupported action type')
    end
    if type(params) ~= 'table' then
        return fail('invalid_params', 'args must be a JSON object')
    end
    ctx = ctx or {}
    cfg = cfg or {}

    local player = ctx.player
    local preview = {
        action_type = actionType,
        risk = definition.risk,
        requires_approval = definition.requires_approval,
        citizenid = params.citizenid,
        player_found = player ~= nil,
    }
    if player then
        preview.player_source = tonumber(player.source) or nil
    end

    if actionType == 'notify' then
        preview.text_length = AgentPolicy.TextLength(params.text)
        preview.kind = params.kind
        return preview
    end

    if actionType == 'add_money' then
        preview.account = params.account
        preview.amount = params.amount

        local before = nil
        if type(player) == 'table' and type(player.money) == 'table' then
            before = player.money[params.account]
        end
        if type(before) == 'number' then
            preview.account_exists = true
            preview.before = before
            preview.after = before + params.amount
        else
            preview.account_exists = false
        end

        local dailyBudget = cfg.daily_budget or AgentPolicy.DEFAULTS.daily_budget
        local dailySpent = tonumber(ctx.daily_spent) or 0
        preview.daily_budget = dailyBudget
        preview.daily_spent = dailySpent
        preview.daily_remaining = math.max(0, dailyBudget - dailySpent)
        preview.daily_remaining_after = math.max(0, preview.daily_remaining - params.amount)
        return preview
    end

    if actionType == 'start_quest' then
        preview.quest_id = params.quest_id
        local quest = nil
        if ctx.quests then
            quest = AgentPolicy.FindQuest(ctx.quests, params.quest_id)
        end
        preview.quest_found = quest ~= nil
        if quest then
            preview.quest_title = quest.title
            preview.quest_category = quest.category
        end
        return preview
    end

    if actionType == 'set_job' then
        preview.job = params.job
        preview.grade = params.grade
        local current = nil
        if type(player) == 'table' then current = player.job end
        if type(current) == 'table' then
            preview.before = {
                job = current.name,
                grade = current.grade and current.grade.level or 0,
            }
        end
        return preview
    end

    if actionType == 'grant_item' then
        preview.item = params.item
        preview.amount = params.amount
        preview.reason = params.reason
        if type(player) == 'table' then
            preview.before = tonumber(player.item_count) or 0
        end
        return preview
    end

    return fail('unsupported_action', 'unsupported action type')
end

-- ---------------------------------------------------------------------------
-- Runtime policy (preview is advisory; this is the gate)
-- ---------------------------------------------------------------------------
function AgentPolicy.CheckPolicy(actionType, params, cfg, ctx)
    local definition = AgentPolicy.ACTIONS[actionType]
    if not definition then
        return failBool('unsupported_action', 'unsupported action type')
    end
    if type(params) ~= 'table' then
        return failBool('invalid_params', 'args must be a JSON object')
    end
    cfg = cfg or {}
    ctx = ctx or {}

    if not ctx.player then
        return failBool('player_not_found', 'target player is not online')
    end

    if actionType == 'notify' then
        local maxChars = cfg.max_notify_chars or AgentPolicy.DEFAULTS.max_notify_chars
        local length = AgentPolicy.TextLength(params.text)
        if length < 1 then
            return failBool('invalid_params', 'text is required')
        end
        if length > maxChars then
            return failBool('text_too_long', ('text exceeds %d characters'):format(maxChars))
        end
        return true
    end

    if actionType == 'add_money' then
        if type(params.amount) ~= 'number' or params.amount < 1 then
            return failBool('invalid_params', 'amount is invalid')
        end
        local maxMoney = cfg.max_money or AgentPolicy.DEFAULTS.max_money
        if params.amount > maxMoney then
            return failBool('money_cap_exceeded', ('amount exceeds per-action cap of %d'):format(maxMoney))
        end
        if type(ctx.player.money) ~= 'table' or type(ctx.player.money[params.account]) ~= 'number' then
            return failBool('account_unavailable', 'target player does not have that account')
        end

        local dailyBudget = cfg.daily_budget or AgentPolicy.DEFAULTS.daily_budget
        local dailySpent = tonumber(ctx.daily_spent) or 0
        if dailySpent + params.amount > dailyBudget then
            return failBool('daily_budget_exceeded', ('daily budget exceeded (%d + %d > %d)'):format(
                dailySpent, params.amount, dailyBudget))
        end
        return true
    end

    if actionType == 'start_quest' then
        local found = ctx.quest_found
        if found == nil and ctx.quests then
            found = AgentPolicy.FindQuest(ctx.quests, params.quest_id) ~= nil
        end
        if not found then
            return failBool('quest_not_found', 'quest does not exist in the catalog')
        end
        return true
    end

    if actionType == 'set_job' then
        local jobDefinition = nil
        if type(ctx.jobs) == 'table' then jobDefinition = ctx.jobs[params.job] end
        if type(jobDefinition) ~= 'table' then
            return failBool('job_not_found', 'job does not exist in QBCore.Shared.Jobs')
        end
        local grades = jobDefinition.grades
        if type(grades) == 'table' and grades[tostring(params.grade)] == nil then
            return failBool('grade_not_found', ('grade %s does not exist for job %s'):format(
                tostring(params.grade), tostring(params.job)))
        end
        return true
    end

    if actionType == 'grant_item' then
        local itemDefinition = nil
        if type(ctx.items) == 'table' then itemDefinition = ctx.items[params.item] end
        if type(itemDefinition) ~= 'table' then
            return failBool('item_not_found', 'item does not exist in QBCore.Shared.Items')
        end
        return true
    end

    return failBool('unsupported_action', 'unsupported action type')
end

-- ---------------------------------------------------------------------------
-- Status helpers
-- ---------------------------------------------------------------------------
function AgentPolicy.RequiresApproval(actionType)
    local definition = AgentPolicy.ACTIONS[actionType]
    return definition ~= nil and definition.requires_approval == true
end

function AgentPolicy.StatusFor(actionType, dryRun)
    if dryRun then return 'proposed' end
    if AgentPolicy.RequiresApproval(actionType) then return 'pending_approval' end
    return 'approved'
end

function AgentPolicy.IsValidStatus(status)
    return type(status) == 'string' and AgentPolicy.STATUSES[status] == true
end

AgentPolicy._VERSION = 1

_G.AgentPolicy = AgentPolicy
return AgentPolicy
