-- server/story_db.lua — player_choices 表异步 CRUD
--
-- 使用 oxmysql 异步接口，遵循四大铁律：
--   - 所有 DB 操作走异步回调
--   - 写入走 DirtyFlush 缓冲管道（生产阶段接入）

StoryDB = StoryDB or {}

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 写入
-- ==============================================================

--- 记录玩家抉择（异步）
---@param citizenid string
---@param decisionId string
---@param chosenOption string
---@param arcId string
---@param chapter number
function StoryDB.RecordChoice(citizenid, decisionId, chosenOption, arcId, chapter)
    local query = [[
        INSERT INTO player_choices (citizenid, decision_id, chosen_option, arc_id, chapter)
        VALUES (?, ?, ?, ?, ?)
    ]]
    local params = { citizenid, decisionId, chosenOption, arcId, chapter or 1 }

    exports.oxmysql:execute(query, params, function(affectedRows)
        if StoryConfig.Debug then
            print(('[story-db] 📝 Choice recorded: %s → %s = %s (rows=%d)'):format(
                citizenid, decisionId, chosenOption, affectedRows or 0))
        end
    end)
end

-- ==============================================================
-- 查询
-- ==============================================================

--- 获取玩家在某条剧情线上的所有选择
---@param citizenid string
---@param arcId string|nil
---@param cb function 回调: table[] (含 decision_id, chosen_option, chapter)
function StoryDB.GetPlayerChoices(citizenid, arcId, cb)
    local query, params
    if arcId then
        query = [[SELECT decision_id, chosen_option, chapter, chosen_at
                  FROM player_choices WHERE citizenid = ? AND arc_id = ? ORDER BY chapter ASC, chosen_at ASC]]
        params = { citizenid, arcId }
    else
        query = [[SELECT decision_id, chosen_option, arc_id, chapter, chosen_at
                  FROM player_choices WHERE citizenid = ? ORDER BY chosen_at ASC]]
        params = { citizenid }
    end

    exports.oxmysql:fetch(query, params, function(result)
        cb(result or {})
    end)
end

--- 获取玩家在指定章节的决策
---@param citizenid string
---@param arcId string
---@param chapter number
---@param cb function
function StoryDB.GetChapterChoices(citizenid, arcId, chapter, cb)
    local query = [[SELECT decision_id, chosen_option
                    FROM player_choices
                    WHERE citizenid = ? AND arc_id = ? AND chapter = ?]]
    exports.oxmysql:fetch(query, { citizenid, arcId, chapter }, function(result)
        cb(result or {})
    end)
end

--- 检查玩家是否已经做过某个决策
---@param citizenid string
---@param decisionId string
---@param cb function 回调: boolean
function StoryDB.HasMadeChoice(citizenid, decisionId, cb)
    local query = [[SELECT COUNT(*) AS cnt FROM player_choices
                    WHERE citizenid = ? AND decision_id = ?]]
    exports.oxmysql:fetch(query, { citizenid, decisionId }, function(result)
        local count = result and result[1] and result[1].cnt or 0
        cb(count > 0)
    end)
end

-- ==============================================================
-- v0.7 一次性门控: 剧情线完成追踪
-- ==============================================================

-- 内存缓存: citizenid → { arc_id → true }
StoryDB._arcCompletions = {}

--- 标记剧情线已完成（内存 + DB 异步写入）
---@param citizenid string
---@param arcId string
function StoryDB.MarkArcCompleted(citizenid, arcId)
    StoryDB._arcCompletions[citizenid] = StoryDB._arcCompletions[citizenid] or {}
    StoryDB._arcCompletions[citizenid][arcId] = true

    exports.oxmysql:execute(
        [[INSERT IGNORE INTO story_completions (citizenid, arc_id) VALUES (?, ?)]],
        { citizenid, arcId },
        function(rows)
            if StoryConfig.Debug then
                print(('[story-db] 🏁 Arc completed: %s → %s (rows=%d)'):format(
                    citizenid, arcId, rows or 0))
            end
        end
    )
end

--- 同步检查剧情线是否已完成（内存缓存，O(1)）
---@param citizenid string
---@param arcId string
---@return boolean
function StoryDB.IsArcCompletedSync(citizenid, arcId)
    local arcs = StoryDB._arcCompletions[citizenid]
    return arcs and arcs[arcId] == true or false
end

--- 从 DB 加载玩家的所有已完成剧情线（登录时调用）
---@param citizenid string
function StoryDB.LoadArcCompletions(citizenid)
    exports.oxmysql:fetch(
        [[SELECT arc_id FROM story_completions WHERE citizenid = ?]],
        { citizenid },
        function(result)
            StoryDB._arcCompletions[citizenid] = {}
            if result then
                for _, row in ipairs(result) do
                    StoryDB._arcCompletions[citizenid][row.arc_id] = true
                end
            end
            if StoryConfig.Debug then
                local count = result and #result or 0
                print(('[story-db] 📥 Loaded %d arc completions for %s'):format(count, citizenid))
            end
        end
    )
end

print('[story-db] ✅ player_choices CRUD + arc completion tracking 已就绪')
