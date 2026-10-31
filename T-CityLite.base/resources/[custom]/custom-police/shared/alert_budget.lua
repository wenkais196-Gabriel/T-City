-- shared/alert_budget.lua — 警情通知的预算层（P2-2）。
--
-- 问题：建单后 `notifyOnDutyIncident` 对每个在勤警员逐条发通知。
-- 连续几个事件（连锁劫案、NPC callout 刷屏）会把手机通知栏和屏幕提示糊满，
-- 真正重要那一条反而被冲走。
--
-- 规则（与蓝图 §P2 一致）：
--   * 同 `code` 90 秒内只发第一条，之后合并成「（×N）」的更新：
--     第 2 条发一次、第 5 条发一次、此后每 10 条发一次，中间静默；
--   * 非紧急（priority ≥ 2）每人 5 秒最多 3 条，超出直接丢；
--   * 紧急（priority ≤ 1）穿透上面的频率上限（但仍按 code 合并）。
--
-- **限流本身不在这里实现**：冷却与窗口都走 `core-framework` 的 RateLimit
-- （RATE-01：安全原语只允许一份实现）。本文件只做"该发哪一条、标题带不带 ×N"。

PoliceAlertBudget = PoliceAlertBudget or {}

local MERGE_WINDOW_MS = 90 * 1000
local BURST_WINDOW_MS = 5 * 1000
local BURST_MAX = 3
local MERGE_ANNOUNCE = { [2] = true, [5] = true }

-- 合并计数：key:code -> 当前合并窗口内的条数（纯业务状态，不是限流器）
local counters = {}

-- 限流原语在 core-framework 里是**那个资源的全局**，跨资源拿不到 `_G.RateLimit`：
-- 生产必须走 export，golden 里才直接 dofile owner（于是 `_G.RateLimit` 存在）。
-- 2026-10-31 真机就是栽在这里：只认 `_G.RateLimit`，于是取到 nil、每条都 'sent'，
-- 合并窗口形同不存在（golden 却全绿，因为测试环境里全局确实有）。
local function cooldown(key, ms, now)
    local owner = _G.RateLimit
    if owner and owner.Cooldown then return owner.Cooldown(key, ms, now) end
    local ok, result = pcall(function()
        return exports['core-framework']:RateLimitCooldown(key, ms, now)
    end)
    if ok and result ~= nil then return result end
    return true
end

local function window(key, limit, ms, now)
    local owner = _G.RateLimit
    if owner and owner.Window then return owner.Window(key, limit, ms, now) end
    local ok, result = pcall(function()
        return exports['core-framework']:RateLimitWindow(key, limit, ms, now)
    end)
    if ok and result ~= nil then return result end
    return true
end

--- 清空状态（测试与资源重启时用）。
function PoliceAlertBudget.Reset()
    counters = {}
    local owner = _G.RateLimit
    if owner and owner.Reset then
        owner.Reset('alert:')
    else
        pcall(function() exports['core-framework']:RateLimitReset('alert:') end)
    end
end

--- 决定这一条通知该怎么办。
--- @param key string  接收人（citizenid）
--- @param code string 警情代号（10-31 / 911 / 10-90 …）
--- @param priority number 1 = 最紧急
--- @param now number  毫秒时间戳
--- @return string action  'sent' | 'merged' | 'suppressed' | 'throttled'
--- @return number count   该 code 在当前合并窗口内的累计条数
function PoliceAlertBudget.Decide(key, code, priority, now)
    key = tostring(key or '')
    code = tostring(code or '911')
    priority = tonumber(priority) or 2
    now = tonumber(now) or 0

    local slot = key .. ':' .. code

    -- 同 code 的合并窗口：冷却期内 = 还在同一批里（同一张单或同一次事件连发）。
    local fresh = cooldown('alert:merge:' .. slot, MERGE_WINDOW_MS, now)

    if not fresh then
        counters[slot] = (counters[slot] or 1) + 1
        local count = counters[slot]
        if MERGE_ANNOUNCE[count] or (count > 5 and count % 10 == 0) then
            return 'merged', count
        end
        return 'suppressed', count
    end

    counters[slot] = 1

    -- 紧急警情穿透频率上限
    if priority <= 1 then
        return 'sent', 1
    end

    if not window('alert:burst:' .. key, BURST_MAX, BURST_WINDOW_MS, now) then
        return 'throttled', 1
    end

    return 'sent', 1
end

--- 给标题加合并计数。
function PoliceAlertBudget.Decorate(title, count)
    if not count or count <= 1 then return title end
    return ('%s（×%d）'):format(tostring(title), count)
end

PoliceAlertBudget.MERGE_WINDOW_MS = MERGE_WINDOW_MS
PoliceAlertBudget.BURST_WINDOW_MS = BURST_WINDOW_MS
PoliceAlertBudget.BURST_MAX = BURST_MAX
