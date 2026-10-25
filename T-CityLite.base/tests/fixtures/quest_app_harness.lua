-- tests/fixtures/quest_app_harness.lua
-- 桩好 PhoneApps / custom-quest 导出，dofile 手机任务 App，跑一组用例。
__out = {}
local function emit(name, value)
    __out[#__out + 1] = string.format("%s|%s", name, tostring(value))
end

__calls = { trigger = 0, abandon = 0, list = 0, detail = 0 }
__state = {
    quests_export_missing = false,
    list_rows = { { id = 'q_a', title = 'A', available = true }, { id = 'q_b', title = 'B', available = false, reason = 'police' } },
    trigger_ok = true,
    trigger_message = 'Quest on cooldown for 9 more minutes',
    detail = { id = 'q_a', title = 'A', steps = { { index = 1, title = 'reach' } } },
}

PhoneApps = {
    registered = nil,
    Register = function(def) PhoneApps.registered = def return true end,
}

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource ~= 'custom-quest' then return nil end
        if __state.quests_export_missing then return nil end
        return {
            GetAvailableQuests = function(_, _) __calls.list = __calls.list + 1 return __state.list_rows end,
            GetActiveQuests = function(_, _) return {} end,
            GetQuestDetail = function(_, _, questId) __calls.detail = __calls.detail + 1 return __state.detail end,
            TriggerQuest = function(_, _, questId)
                __calls.trigger = __calls.trigger + 1
                if __state.trigger_ok then return true, 'Quest started' end
                return false, __state.trigger_message
            end,
            AbandonQuest = function(_, _, questId) __calls.abandon = __calls.abandon + 1 return true end,
        }
    end,
})

dofile('__APP__')

local reg = PhoneApps.registered
emit('registered', reg ~= nil)
emit('id', reg and reg.id)
emit('audience_is_open', reg and reg.audience and next(reg.audience) == nil)
emit('has_queries', reg and reg.queries and reg.queries.list ~= nil and reg.queries.active ~= nil and reg.queries.detail ~= nil)
emit('has_actions', reg and reg.actions and reg.actions.accept ~= nil and reg.actions.abandon ~= nil)

-- list 正常
__state.quests_export_missing = false
local list = reg.queries.list(1, {})
emit('list_count', list and list.count)
emit('list_rows_len', list and list.rows and #list.rows)

-- list 时导出不可用
__state.quests_export_missing = true
local broken = reg.queries.list(1, {})
emit('list_unavailable_error', broken and broken.error)
emit('list_unavailable_count', broken and broken.count)
__state.quests_export_missing = false

-- detail 非法 id：不能透传给下游
local before = __calls.detail
local badDetail = reg.queries.detail(1, { quest_id = 'bad id with spaces' })
emit('detail_bad_id_error', badDetail and badDetail.error)
emit('detail_bad_id_no_downstream_call', __calls.detail == before)

-- accept 正常
__state.trigger_ok = true
local okAccept = reg.actions.accept(1, { quest_id = 'q_a' })
emit('accept_ok', okAccept and okAccept.ok)
emit('accept_echoes_id', okAccept and okAccept.quest_id)

-- accept 被拒：把下游句子带回去
__state.trigger_ok = false
local rejected = reg.actions.accept(1, { quest_id = 'q_b' })
emit('accept_rejected_ok', rejected and rejected.ok)
emit('accept_rejected_error', rejected and rejected.error)
emit('accept_rejected_detail', rejected and rejected.detail)

-- accept 非法 id：不调用 TriggerQuest
local triggerBefore = __calls.trigger
local badAccept = reg.actions.accept(1, { quest_id = string.rep('x', 200) })
emit('accept_long_id_error', badAccept and badAccept.error)
emit('accept_long_id_no_downstream_call', __calls.trigger == triggerBefore)

-- abandon
local ab = reg.actions.abandon(1, { quest_id = 'q_a' })
emit('abandon_ok', ab and ab.ok)

print(table.concat(__out, "\n"))
