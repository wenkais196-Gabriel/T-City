-- server/apps/quests.lua — 任务 App（所有职业可见）
--
-- 数据源是 custom-quest 的两个只读导出：
--   GetAvailableQuests(source) → 这个玩家现在能接什么（含不可接的原因）
--   GetQuestDetail(source, id) → 单条任务的步骤标题
-- 接取/放弃走 TriggerQuest / AbandonQuest —— 判定权威始终在 quest_manager，
-- 这里只做「参数清洗 + 结果规范化」，不复制任何规则。
--
-- 为什么参数要在这里清洗：quest_id 完全由客户端给，直接 string.format 进日志或
-- 传给别的资源都属于把客户端输入当可信数据。这里只放行长 ≤64 的 [A-Za-z0-9_] 。

local MAX_ID_LEN = 64

local function validQuestId(value)
    if type(value) ~= 'string' then return nil end
    if #value == 0 or #value > MAX_ID_LEN then return nil end
    if not value:match('^[%w_]+$') then return nil end
    return value
end

--- 调用另一个资源的导出，失败时返回 nil（不让一次异常打掉整个手机请求）。
local function questExport(method, ...)
    local ok, result, extra = pcall(function(...)
        return exports['custom-quest'][method](exports['custom-quest'], ...)
    end, ...)
    if not ok then
        print(('[custom-phone][apps] quests %s failed: %s'):format(method, tostring(result)))
        return nil, nil
    end
    return result, extra
end

PhoneApps.Register({
    id = 'quests',
    label = '任务',
    icon = '📜',
    audience = {},  -- 平民也有平民线（quest_civilian_*），不要按职业锁死
    queries = {
        list = function(source)
            local rows = questExport('GetAvailableQuests', source)
            if type(rows) ~= 'table' then return { rows = {}, count = 0, error = 'quest_unavailable' } end
            return { rows = rows, count = #rows }
        end,
        active = function(source)
            local rows = questExport('GetActiveQuests', source)
            if type(rows) ~= 'table' then return { rows = {}, count = 0, error = 'quest_unavailable' } end
            return { rows = rows, count = #rows }
        end,
        detail = function(source, params)
            local questId = validQuestId(params and params.quest_id)
            if not questId then return { rows = {}, count = 0, error = 'bad_id' } end
            local detail, err = questExport('GetQuestDetail', source, questId)
            if type(detail) ~= 'table' then
                return { rows = {}, count = 0, error = err or 'not_found' }
            end
            return { rows = { detail }, count = 1 }
        end,
    },
    actions = {
        accept = function(source, params)
            local questId = validQuestId(params and params.quest_id)
            if not questId then return { ok = false, error = 'bad_id' } end
            local ok, message = questExport('TriggerQuest', source, questId)
            if ok == true then return { ok = true, quest_id = questId } end
            -- TriggerQuest 的第二个返回值是给玩家看的句子（例如 "Quest on cooldown for 9 more minutes"）
            return { ok = false, error = 'rejected', detail = tostring(message or '') }
        end,
        abandon = function(source, params)
            local questId = validQuestId(params and params.quest_id)
            if not questId then return { ok = false, error = 'bad_id' } end
            local ok, message = questExport('AbandonQuest', source, questId)
            if ok == true then return { ok = true, quest_id = questId } end
            return { ok = false, error = 'rejected', detail = tostring(message or '') }
        end,
    },
})

print('[phone-apps] ✅ quests app registered (audience = all jobs)')
