-- server/core/rate_limit.lua — 手机端的限流门面（实现在 core-framework）
--
-- 历史：这里曾经是一份独立的令牌桶（94 行）。它的语义与 `core-framework/server/rate_limit.lua`
-- 的 `RateLimit.TokenBucket` 完全一致（tokens per minute + burst，按毫秒回填），
-- 两处各写一份意味着两个边界行为——而限流的 off-by-one 就是"多放过一次"。
--
-- 现在这里只保留**手机自己的东西**：默认速率/突发的来源（convar 与 Config），以及对外的
-- `PhoneRateLimit.Allow(key, rate, burst)` 门面。手机里 4 个调用点与 `core/diag.lua`
-- 都依赖这个名字，所以 API 不变，换掉的是实现。
--
-- 为什么失败时拒绝（fail-closed）而不是放行：这是安全控制。如果 core-framework 不在
-- （依赖缺失、加载失败），放行等于把所有频控一次性关掉且没有任何信号；
-- 拒绝会让手机功能报 `rate_limited`，故障可见、可修。前提是 custom-phone 声明了
-- `dependencies { 'core-framework' }`，正常运行时这个分支不该走到。

PhoneRateLimit = {}

local DEFAULTS = { rate = 30, burst = 10 }

---@param configKey string
---@param convarName string
---@param default number
---@return number
local function setting(configKey, convarName, default)
    local getConvar = rawget(_G, 'GetConvar')
    if type(getConvar) == 'function' then
        local value = tonumber(getConvar(convarName))
        if value and value > 0 then return value end
    end
    local config = rawget(_G, 'Config')
    if type(config) == 'table' then
        local value = tonumber(config[configKey])
        if value and value > 0 then return value end
    end
    return default
end

PhoneRateLimit.DefaultRate = setting(
    'AppRateLimitPerMinute', 'phone_app_rate_per_minute', DEFAULTS.rate)
PhoneRateLimit.DefaultBurst = setting(
    'AppRateLimitBurst', 'phone_app_rate_burst', DEFAULTS.burst)

local warned = false

--- Consume one token. `rate` is tokens per minute.
---@param key string
---@param rate number|nil
---@param burst number|nil
---@return boolean allowed
function PhoneRateLimit.Allow(key, rate, burst)
    if type(key) ~= 'string' or key == '' then return false end

    rate = tonumber(rate) or PhoneRateLimit.DefaultRate
    burst = math.floor(tonumber(burst) or PhoneRateLimit.DefaultBurst)
    if rate <= 0 or burst <= 0 then
        rate, burst = DEFAULTS.rate, DEFAULTS.burst
    end

    local exporter = rawget(_G, 'exports')
    if type(exporter) ~= 'table' then
        if not warned then
            warned = true
            print('[custom-phone] ❌ exports 不可用，限流无法委派到 core-framework（按拒绝处理）')
        end
        return false
    end

    return exporter['core-framework']:RateLimitTokenBucket(key, rate, burst) == true
end
