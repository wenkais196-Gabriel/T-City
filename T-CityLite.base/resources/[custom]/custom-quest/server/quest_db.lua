-- quest_db.lua — 任务系统数据库操作层
--
-- 所有 player_quests / quest_cooldowns / quest_event_log 的 CRUD
-- 统一使用 oxmysql 异步接口

QuestDB = QuestDB or {}

-- 🔒 Security: 调试日志开关
local QUEST_DEBUG = GetConvar('quest_debug', 'false') == 'true'

-- ==============================================================
-- player_quests 表操作
-- ==============================================================

--- 创建任务记录（接取任务时）
---@param citizenid string
---@param questId string
---@param firstStep string|nil 第一个步骤 ID
function QuestDB.CreateQuest(citizenid, questId, firstStep)
    if not MySQL then return end
    MySQL.Async.insert(
        'INSERT INTO player_quests (citizenid, quest_id, status, current_step, progress_data, started_at) VALUES (?, ?, ?, ?, ?, NOW())',
        { citizenid, questId, 'in_progress', firstStep, '{}' },
        function(insertId)
            if insertId then
                if QUEST_DEBUG then
                    print(('[quest-db] 📝 Quest started: %s → %s (id=%d)'):format(citizenid, questId, insertId))
                end
            end
        end
    )
end

--- 获取玩家活跃任务列表
---@param citizenid string
---@param cb function 回调: function(quests)
function QuestDB.GetActiveQuests(citizenid, cb)
    if not MySQL then if cb then cb({}) end; return end
    MySQL.Async.fetchAll(
        'SELECT quest_id, status, current_step, progress_data, started_at, completion_count FROM player_quests WHERE citizenid = ? AND status IN (?, ?) ORDER BY started_at DESC',
        { citizenid, 'in_progress', 'not_started' },
        function(results)
            if cb then cb(results or {}) end
        end
    )
end

--- 获取单个任务进度
---@param citizenid string
---@param questId string
---@param cb function
function QuestDB.GetQuestProgress(citizenid, questId, cb)
    if not MySQL then if cb then cb(nil) end; return end
    MySQL.Async.fetchAll(
        'SELECT quest_id, status, current_step, progress_data, started_at, completed_at, completion_count FROM player_quests WHERE citizenid = ? AND quest_id = ? ORDER BY started_at DESC LIMIT 1',
        { citizenid, questId },
        function(results)
            if cb then cb(results and results[1] or nil) end
        end
    )
end

--- 更新任务进度
---@param citizenid string
---@param questId string
---@param newStep string|nil 新步骤 ID
---@param progressData string|nil JSON 字符串
function QuestDB.UpdateProgress(citizenid, questId, newStep, progressData)
    if not MySQL then return end
    MySQL.Async.execute(
        'UPDATE player_quests SET current_step = ?, progress_data = ? WHERE citizenid = ? AND quest_id = ? AND status = ?',
        { newStep, progressData or '{}', citizenid, questId, 'in_progress' }
    )
end

--- 完成任务
---@param citizenid string
---@param questId string
function QuestDB.CompleteQuest(citizenid, questId)
    if not MySQL then return end
    MySQL.Async.execute(
        'UPDATE player_quests SET status = ?, completed_at = NOW(), completion_count = completion_count + 1 WHERE citizenid = ? AND quest_id = ? AND status = ?',
        { 'completed', citizenid, questId, 'in_progress' }
    )
end

--- 标记任务失败
---@param citizenid string
---@param questId string
---@param reason string|nil
function QuestDB.FailQuest(citizenid, questId, reason)
    if not MySQL then return end
    MySQL.Async.execute(
        'UPDATE player_quests SET status = ?, failed_at = NOW(), progress_data = ? WHERE citizenid = ? AND quest_id = ? AND status = ?',
        { 'failed', json.encode({ fail_reason = reason }), citizenid, questId, 'in_progress' }
    )
end

--- 放弃任务
---@param citizenid string
---@param questId string
function QuestDB.AbandonQuest(citizenid, questId)
    if not MySQL then return end
    MySQL.Async.execute(
        'UPDATE player_quests SET status = ? WHERE citizenid = ? AND quest_id = ? AND status = ?',
        { 'abandoned', citizenid, questId, 'in_progress' }
    )
end

--- 获取任务完成次数
---@param citizenid string
---@param questId string
---@param cb function
function QuestDB.GetCompletionCount(citizenid, questId, cb)
    if not MySQL then if cb then cb(0) end; return end
    MySQL.Async.fetchScalar(
        'SELECT MAX(completion_count) FROM player_quests WHERE citizenid = ? AND quest_id = ?',
        { citizenid, questId },
        function(count)
            if cb then cb(count or 0) end
        end
    )
end

-- ==============================================================
-- quest_cooldowns 表操作
-- ==============================================================

--- 检查任务是否在冷却中
---@param citizenid string
---@param questId string
---@param cb function 回调: function(isOnCooldown, remainingSeconds)
function QuestDB.CheckCooldown(citizenid, questId, cb)
    if not MySQL then if cb then cb(false, 0) end; return end
    MySQL.Async.fetchScalar(
        'SELECT UNIX_TIMESTAMP(expires_at) - UNIX_TIMESTAMP(NOW()) FROM quest_cooldowns WHERE citizenid = ? AND quest_id = ? AND expires_at > NOW()',
        { citizenid, questId },
        function(remaining)
            if remaining and remaining > 0 then
                if cb then cb(true, remaining) end
            else
                if cb then cb(false, 0) end
            end
        end
    )
end

--- 设置任务冷却
---@param citizenid string
---@param questId string
---@param cooldownHours number 冷却小时数
function QuestDB.SetCooldown(citizenid, questId, cooldownHours)
    if not MySQL then return end
    MySQL.Async.execute(
        'INSERT INTO quest_cooldowns (citizenid, quest_id, expires_at) VALUES (?, ?, DATE_ADD(NOW(), INTERVAL ? HOUR)) ON DUPLICATE KEY UPDATE expires_at = DATE_ADD(NOW(), INTERVAL ? HOUR), completion_count = completion_count + 1',
        { citizenid, questId, cooldownHours, cooldownHours }
    )
end

--- 获取玩家所有冷却状态
---@param citizenid string
---@param cb function
function QuestDB.GetAllCooldowns(citizenid, cb)
    if not MySQL then if cb then cb({}) end; return end
    MySQL.Async.fetchAll(
        'SELECT quest_id, UNIX_TIMESTAMP(expires_at) - UNIX_TIMESTAMP(NOW()) AS remaining FROM quest_cooldowns WHERE citizenid = ? AND expires_at > NOW()',
        { citizenid },
        function(results)
            local cooldowns = {}
            if results then
                for _, row in ipairs(results) do
                    cooldowns[row.quest_id] = row.remaining
                end
            end
            if cb then cb(cooldowns) end
        end
    )
end

-- ==============================================================
-- quest_event_log 表操作
-- ==============================================================

--- 记录任务事件
---@param citizenid string
---@param questId string
---@param eventType string 'trigger' | 'advance' | 'complete' | 'fail' | 'abandon'
---@param stepId string|nil
---@param metadata table|nil
function QuestDB.LogEvent(citizenid, questId, eventType, stepId, metadata)
    if not MySQL then return end
    local metaJson = metadata and json.encode(metadata) or '{}'
    MySQL.Async.execute(
        'INSERT INTO quest_event_log (citizenid, quest_id, step_id, event_type, metadata, created_at) VALUES (?, ?, ?, ?, ?, NOW())',
        { citizenid, questId, stepId, eventType, metaJson }
    )
end

-- ==============================================================
-- 批量查询
-- ==============================================================

--- 检查玩家是否存在特定状态的某个任务
---@param citizenid string
---@param questId string
---@param status string
---@param cb function
function QuestDB.HasQuestWithStatus(citizenid, questId, status, cb)
    if not MySQL then if cb then cb(false) end; return end
    MySQL.Async.fetchScalar(
        'SELECT COUNT(*) FROM player_quests WHERE citizenid = ? AND quest_id = ? AND status = ?',
        { citizenid, questId, status },
        function(count)
            if cb then cb((count or 0) > 0) end
        end
    )
end

-- ==============================================================
-- v0.7.0: 每日/每周任务限制
-- ==============================================================

--- 检查玩家每日/每周任务完成次数
---@param citizenid string
---@param questId string
---@param limitType string 'daily' | 'weekly' | 'lifetime'
---@param cb function 回调: function(isUnderLimit, currentCount, maxLimit)
function QuestDB.CheckDailyLimit(citizenid, questId, limitType, maxLimit, cb)
    if not MySQL then if cb then cb(true, 0, maxLimit) end; return end
    local periodStart = os.date('%Y-%m-%d')
    if limitType == 'weekly' then
        -- 计算本周一日期
        local today = os.date('*t')
        local weekday = today.wday == 1 and 7 or today.wday - 1 -- Mon=1 .. Sun=7
        periodStart = os.date('%Y-%m-%d', os.time() - (weekday - 1) * 86400)
    end

    MySQL.Async.fetchScalar(
        'SELECT count FROM quest_daily_limits WHERE citizenid = ? AND quest_id = ? AND limit_type = ? AND period_start = ?',
        { citizenid, questId, limitType, periodStart },
        function(currentCount)
            local count = currentCount or 0
            if cb then cb(count < (maxLimit or 999), count, maxLimit) end
        end
    )
end

--- 更新每日/每周任务完成计数
---@param citizenid string
---@param questId string
---@param limitType string 'daily' | 'weekly' | 'lifetime'
function QuestDB.UpdateDailyLimit(citizenid, questId, limitType)
    if not MySQL then return end
    local periodStart = os.date('%Y-%m-%d')
    if limitType == 'weekly' then
        local today = os.date('*t')
        local weekday = today.wday == 1 and 7 or today.wday - 1
        periodStart = os.date('%Y-%m-%d', os.time() - (weekday - 1) * 86400)
    end

    MySQL.Async.execute(
        'INSERT INTO quest_daily_limits (citizenid, quest_id, limit_type, period_start, count) VALUES (?, ?, ?, ?, 1) ON DUPLICATE KEY UPDATE count = count + 1',
        { citizenid, questId, limitType, periodStart }
    )
end

print('[quest-db] ✅ 任务数据库操作层已加载 (v0.7.0)')
print('[quest-db]   新增: daily/weekly 次数限制 + 每日上限检查')