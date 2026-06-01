QBConfig = QBConfig or {}
QBConfig.Custom = QBConfig.Custom or {}

-- 实用工具函数：从系统 Convars 中读取配置，支持后备默认值
local function GetFloatConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return tonumber(val) or default end
    return default
end

local function GetIntConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return math.floor(tonumber(val) or default) end
    return default
end

local function GetBoolConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return val == "true" or val == "1" end
    return default
end

-- 通用常规配置
QBConfig.Custom.General = {
    EnableDebug = true
}

-- 经济系统配置
QBConfig.Custom.Economy = {
    Enable = true,                                                 -- 始终开启经济体系集成
    RewardScale = GetFloatConvar('economy_reward_scale', 1.0),     -- 全局奖励结算倍率
    PriceScale = GetFloatConvar('economy_price_scale', 1.0),       -- 全局物价/购买开销倍率
    
    SampleWindowMinutes = GetIntConvar('economy_sample_window_minutes', 60), -- 自适应统计频率
    HighInflationNetPerHour = GetFloatConvar('economy_high_inflation_net_per_hour', 150000.0), -- 通胀阈值
    LowActivityNetPerHour = GetFloatConvar('economy_low_activity_net_per_hour', 30000.0),      -- 核心冷清阈值
    RewardScaleStep = GetFloatConvar('economy_scale_step', 0.05),  -- 自适应每次调整幅度
    MinRewardScale = GetFloatConvar('economy_min_reward_scale', 0.8), -- 倍率调整下限
    MaxRewardScale = GetFloatConvar('economy_max_reward_scale', 1.4)  -- 倍率调整上限
}
