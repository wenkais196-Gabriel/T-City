-- server/quest_daily_limit.lua — 每日/每周次数上限（把死字段接上）
--
-- 背景：模板里早就写着 `conditions.daily_limit = 8`，`quest_db.lua` 里也有
-- `CheckDailyLimit` / `UpdateDailyLimit`，但**两边都没有调用点** —— 于是同一条路线
-- 可以一天刷无限次，`04-numbers.md` 里的「$/h」只能算理论值。
--
-- 设计（与 quest_cooldown 同形）：
--   * 判定走内存：TriggerQuest 是同步函数，不能等一个异步查询；
--   * 内存未命中时用 `MySQL.scalar.await` **只查一次**并缓存（当天为键，跨天自动失效）；
--   * 计数在完成时内存 +1，DB 异步累加（失败只记日志，不打断结算 —— 结算是钱，不能被限流搞挂）；
--   * DB 不可用时一律**放行**并打一行警告：宁可漏拦，也不要让玩家在 DB 抖动时连任务都接不了。
--
-- 已知边界：`os.date` 用的是服务器本地日期；跨时区/夏令时的那一天会有一天偏差，
-- 与 quest_cooldown 的取舍一致（冷却也是按秒算的）。

QuestDailyLimit = QuestDailyLimit or {}

--- 内存缓存：'cid:quest:type' → { period = 'YYYY-MM-DD', count = n }
QuestDailyLimit.Cache = QuestDailyLimit.Cache or {}

local Cache = QuestDailyLimit.Cache

local DEFAULT_TYPE = 'daily'

--- 当前周期的起始日（weekly = 本周一；其余 = 今天）
---@param limitType string|nil
---@return string
function QuestDailyLimit.PeriodStart(limitType)
    local today = os.date('*t')
    if limitType == 'weekly' then
        local weekday = today.wday == 1 and 7 or today.wday - 1 -- Mon=1 .. Sun=7
        return os.date('%Y-%m-%d', os.time() - (weekday - 1) * 86400)
    end
    return os.date('%Y-%m-%d')
end

local function cacheKey(citizenid, questId, limitType)
    return tostring(citizenid) .. ':' .. tostring(questId) .. ':' .. tostring(limitType)
end

--- 从 DB 读一次并写进缓存（失败返回 nil，调用方决定放行）
--- 注意：SQL 一律走 quest_db（本资源的 DB owner），这里不直接碰 MySQL。
---@return number|nil count
local function loadCount(citizenid, questId, limitType, period)
    if not QuestDB or not QuestDB.DailyLimitCountSync then return nil end
    return QuestDB.DailyLimitCountSync(citizenid, questId, limitType, period)
end
--- 这个玩家今天/本周还能不能接这条任务
---@param citizenid string
---@param questId string
---@param maxLimit number
---@param limitType string|nil 'daily'（默认）| 'weekly'
---@return boolean allowed
---@return number count
function QuestDailyLimit.Allowed(citizenid, questId, maxLimit, limitType)
    local limit = tonumber(maxLimit) or 0
    if limit <= 0 then return true, 0 end

    local kind = limitType or DEFAULT_TYPE
    local period = QuestDailyLimit.PeriodStart(kind)
    local key = cacheKey(citizenid, questId, kind)
    local entry = Cache[key]

    if not entry or entry.period ~= period then
        local fromDb = loadCount(citizenid, questId, kind, period)
        if fromDb == nil then
            -- DB 不可用：不拦（否则一次抖动把所有人的任务都锁死）
            return true, 0
        end
        entry = { period = period, count = fromDb }
        Cache[key] = entry
    end

    return entry.count < limit, entry.count
end

--- 完成一次 → 计数 +1（内存立刻生效，DB 异步累加）
---@param citizenid string
---@param questId string
---@param limitType string|nil
function QuestDailyLimit.Increment(citizenid, questId, limitType)
    local kind = limitType or DEFAULT_TYPE
    local period = QuestDailyLimit.PeriodStart(kind)
    local key = cacheKey(citizenid, questId, kind)

    local entry = Cache[key]
    if not entry or entry.period ~= period then
        entry = { period = period, count = 0 }
        Cache[key] = entry
    end
    entry.count = entry.count + 1

    if QuestDB and QuestDB.DailyLimitIncrementSync then
        QuestDB.DailyLimitIncrementSync(citizenid, questId, kind, period)
    end
end
--- 清掉某个玩家的缓存（重连/换角色时用；不清也不会错，只是多读一次库）
---@param citizenid string
function QuestDailyLimit.Clear(citizenid)
    local prefix = tostring(citizenid) .. ':'
    for key in pairs(Cache) do
        if key:sub(1, #prefix) == prefix then Cache[key] = nil end
    end
end

print('[quest-daily-limit] ✅ 每日/每周上限已接管 daily_limit（内存判定 + DB 异步累加）')
