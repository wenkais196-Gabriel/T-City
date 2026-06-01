QBConfig = QBConfig or {}

QBConfig.Custom = QBConfig.Custom or {}

-- 实用工具函数：从系统 Convars 中读取配置，支持后备默认值
local function GetStrConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return val end
    return default
end

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
    EnableDebug = true,          -- 是否开启调试信息输出
    EnableCustomLogs = true      -- 是否启用本地审计与 Discord Webhook
}

-- 桥接适配器开关
QBConfig.Custom.Bridges = {
    ExampleBridgeEnabled = false
}

-- Webhook 连接池 (从 Convar 动态读取，不硬编码)
-- 实际 webhook URL 在 configs/modules/economy.cfg 和 security.cfg 中配置
QBConfig.Custom.Webhooks = {
    DefaultLog = '',
    JoinLeave  = GetStrConvar('economy_discord_webhook', ''),
    Money      = GetStrConvar('economy_discord_webhook', ''),
    Security   = GetStrConvar('security_discord_webhook', ''),
    Custom     = '',
}

-- 经济系统配置
QBConfig.Custom.Economy = {
    Enable = true,                                                 -- 始终开启经济体系集成
    RewardScale = GetFloatConvar('economy_reward_scale', 1.0),     -- 全局奖励结算倍率
    PriceScale = GetFloatConvar('economy_price_scale', 1.0),       -- 全局物价/购买开销倍率
    
    SampleWindowMinutes = GetIntConvar('economy_sample_window_minutes', 60), -- 自适应统计频率
    HighInflationNetPerHour = GetFloatConvar('economy_high_inflation_net_per_hour', 150000.0), -- 通胀阈值
    LowActivityNetPerHour = GetFloatConvar('economy_low_activity_net_per_hour', 30000.0),      -- 冷清阈值
    RewardScaleStep = GetFloatConvar('economy_scale_step', 0.05),  -- 自适应每次调整幅度
    MinRewardScale = GetFloatConvar('economy_min_reward_scale', 0.8), -- 倍率调整下限
    MaxRewardScale = GetFloatConvar('economy_max_reward_scale', 1.4)  -- 倍率调整上限
}

-- 安全防刷配置
QBConfig.Custom.Security = {
    RateLimitMs = GetIntConvar('security_rate_limit_ms', 1000),             -- 敏感行为防刷冷却时长 (ms)
    MaxAddMoneyLimit = GetFloatConvar('security_max_add_money_limit', 50000.0), -- 单次资金变动上限
    MaxAddItemLimit = GetIntConvar('security_max_add_item_limit', 20),      -- 单次同类物品赋予上限
    MaxInteractionDistance = GetFloatConvar('security_max_interaction_distance', 10.0), -- 最大防瞬移交易距离
    CheckVehicleSpawn = GetBoolConvar('security_check_vehicle_spawn', true), -- 是否启用刷车服务端严格审查
    CheckWeaponGive = GetBoolConvar('security_check_weapon_give', true)     -- 是否审计指令武器获取
}
