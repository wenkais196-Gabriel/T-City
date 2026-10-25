-- server/core/rate_limit.lua — generic per-key token bucket.
--
-- No QBCore dependency: the caller supplies the key (custom-phone uses
-- `app:<citizenid>:<query|action>`) and the bucket is pure Lua state. The
-- defaults are 30 tokens/minute with a burst of 10, overridable by the
-- `phone_app_rate_per_minute` / `phone_app_rate_burst` convars or by
-- `Config.AppRateLimitPerMinute` / `Config.AppRateLimitBurst` when present.

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

--- Monotonic-ish seconds. GetGameTimer is millisecond wall time under FiveM;
--- os.clock keeps the module usable in the offline Lua test harness.
---@return number
local function nowSeconds()
    local timer = rawget(_G, 'GetGameTimer')
    if type(timer) == 'function' then return timer() / 1000.0 end
    return os.clock()
end

local buckets = {}
local lastSweep = nowSeconds()
local SWEEP_INTERVAL = 60 -- seconds between stale-bucket sweeps
local BUCKET_IDLE = 300  -- drop a bucket after 5 minutes of inactivity

---@param nowTs number
local function sweep(nowTs)
    if nowTs - lastSweep < SWEEP_INTERVAL then return end
    for key, bucket in pairs(buckets) do
        if nowTs - bucket.last > BUCKET_IDLE then buckets[key] = nil end
    end
    lastSweep = nowTs
end

--- Consume one token. `rate` is tokens per minute; defaults come from the
--- module settings above. Returns false when the bucket is empty so the caller
--- can answer `rate_limited` instead of doing the work.
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

    local nowTs = nowSeconds()
    sweep(nowTs)

    local bucket = buckets[key]
    if not bucket then
        bucket = { tokens = burst, last = nowTs }
        buckets[key] = bucket
    else
        local elapsed = nowTs - bucket.last
        if elapsed > 0 then
            bucket.tokens = math.min(burst, bucket.tokens + elapsed * (rate / 60))
            bucket.last = nowTs
        end
        if bucket.tokens > burst then bucket.tokens = burst end
    end

    if bucket.tokens < 1 then return false end
    bucket.tokens = bucket.tokens - 1
    return true
end
