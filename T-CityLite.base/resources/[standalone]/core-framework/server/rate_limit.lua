-- rate_limit.lua — 限流原语（唯一实现）
--
-- 为什么要有这个文件：仓库里曾有 7 份各自实现的限流，语义分成三类——
--   1. 每键冷却（`now - last < ms`）：dashboard、custom-vehicles
--   2. 固定窗口计数：notify_service、atmosphere
--   3. 令牌桶 + 突发：custom-phone 自己的 core/rate_limit.lua
-- 安全原语各写一份 = 7 种边界行为，其中任何一份的 off-by-one 都是可利用的。
--
-- 这里提供全部三类。唯一的例外是 custom-phone 自己那份令牌桶：它带 diag 钩子与独立单测，
-- 合并会改变已测试的语义，因此登记为例外而不是硬并。
--
-- 用法：
--   RateLimit.Cooldown(('%s:%s'):format(src, 'cash'), 1000)            -- 冷却
--   RateLimit.Window(('%s:%s'):format(src, 'notify'), 20, 60000)       -- 窗口计数
--   exports['core-framework']:RateLimitCooldown(key, ms)               -- 跨资源
--   exports['core-framework']:RateLimitWindow(key, limit, windowMs)

RateLimit = {}

local cooldowns = {}   -- key -> 上次通过的时间戳(ms)
local windows = {}     -- key -> { count = n, start = ts }

local function nowMs()
    if GetGameTimer then return GetGameTimer() end
    return os.time() * 1000
end

--- 每键冷却：距离上次放行不足 cooldownMs 就拒绝。
---@param key string 建议 `('<src>:<action>'):format(...)`
---@param cooldownMs number
---@param now number|nil 便于测试注入
---@return boolean allowed
function RateLimit.Cooldown(key, cooldownMs, now)
    if type(key) ~= 'string' or key == '' then return true end
    cooldownMs = tonumber(cooldownMs) or 0
    now = now or nowMs()

    local last = cooldowns[key]
    if last and (now - last) < cooldownMs then
        return false
    end
    cooldowns[key] = now
    return true
end

--- 固定窗口计数：窗口内超过 limit 次就拒绝；窗口过期自动重置。
---@param key string
---@param limit number 窗口内允许的次数
---@param windowMs number
---@param now number|nil
---@return boolean allowed
---@return number count 本窗口内已用次数（便于诊断）
function RateLimit.Window(key, limit, windowMs, now)
    if type(key) ~= 'string' or key == '' then return true, 0 end
    limit = tonumber(limit) or 0
    windowMs = tonumber(windowMs) or 0
    now = now or nowMs()

    local entry = windows[key]
    if not entry or (now - entry.start) > windowMs then
        windows[key] = { count = 1, start = now }
        return true, 1
    end

    entry.count = entry.count + 1
    return entry.count <= limit, entry.count
end

--- 清掉某个键或某个前缀下的所有键——玩家下线时调用，避免表无限增长。
---@param prefix string 例如 `('sec:%s:'):format(src)`
function RateLimit.Reset(prefix)
    if type(prefix) ~= 'string' or prefix == '' then return end
    for k in pairs(cooldowns) do
        if k == prefix or k:sub(1, #prefix) == prefix then cooldowns[k] = nil end
    end
    for k in pairs(windows) do
        if k == prefix or k:sub(1, #prefix) == prefix then windows[k] = nil end
    end
end

--- 令牌桶：`ratePerMinute` 的补充速率 + `burst` 突发上限。
--- 这是第三种语义（前两种是冷却与固定窗口）；手机那边的令牌桶带 diag 钩子与独立单测，
--- 保持独立，其余新增的桶都该用这里。
---@param key string
---@param ratePerMinute number
---@param burst number
---@param now number|nil
---@return boolean allowed
---@return number retryAfterMs 被拒时建议的重试间隔
function RateLimit.TokenBucket(key, ratePerMinute, burst, now)
    if type(key) ~= 'string' or key == '' then return true, 0 end
    ratePerMinute = math.max(tonumber(ratePerMinute) or 0, 1)
    burst = math.max(tonumber(burst) or 1, 1)
    now = now or nowMs()

    local refillPerMs = ratePerMinute / 60000
    local bucket = windows[key]                      -- 与窗口计数共用一张表，键空间已带前缀
    if not bucket or bucket.tokens == nil then
        -- 首次请求也要消耗一个令牌：曾经这里给满 tokens 却不扣，导致 burst=2 能连续放过 3 次
        -- （真实调用探针抓到的 off-by-one —— 静态闸门永远看不见这种错）。
        windows[key] = { tokens = burst - 1, updatedAt = now }
        return true, 0
    end

    local elapsed = math.max(0, now - (bucket.updatedAt or now))
    if elapsed > 0 then
        bucket.tokens = math.min(burst, bucket.tokens + elapsed * refillPerMs)
        bucket.updatedAt = now
    end

    if bucket.tokens < 1 then
        return false, math.ceil((1 - bucket.tokens) / refillPerMs)
    end
    bucket.tokens = bucket.tokens - 1
    return true, 0
end

--- 清理超过 maxAgeMs 未更新的记录（给"每分钟清一次"的调用方用）。
---@param maxAgeMs number
function RateLimit.Sweep(maxAgeMs)
    maxAgeMs = tonumber(maxAgeMs) or 60000
    local now = nowMs()
    for k, at in pairs(cooldowns) do
        if now - at > maxAgeMs then cooldowns[k] = nil end
    end
    for k, entry in pairs(windows) do
        local stamp = entry.updatedAt or entry.start or 0
        if now - stamp > maxAgeMs then windows[k] = nil end
    end
end

--- 仅用于测试/诊断：总条目数
---@return number
function RateLimit.Size()
    local n = 0
    for _ in pairs(cooldowns) do n = n + 1 end
    for _ in pairs(windows) do n = n + 1 end
    return n
end

--- 仅用于测试/诊断：当前表大小
function RateLimit.Stats()
    local c, w = 0, 0
    for _ in pairs(cooldowns) do c = c + 1 end
    for _ in pairs(windows) do w = w + 1 end
    return { cooldowns = c, windows = w }
end

exports('RateLimitCooldown', RateLimit.Cooldown)
exports('RateLimitWindow', RateLimit.Window)
exports('RateLimitReset', RateLimit.Reset)
exports('RateLimitTokenBucket', RateLimit.TokenBucket)

if Bus and Bus.RegisterService then
    Bus.RegisterService('rateLimit', {
        Cooldown = RateLimit.Cooldown,
        Window   = RateLimit.Window,
        Reset    = RateLimit.Reset,
        TokenBucket = RateLimit.TokenBucket,
    })
end

print('[core-framework] rate limit ready (exports: RateLimitCooldown, RateLimitWindow, RateLimitReset, RateLimitTokenBucket)')
