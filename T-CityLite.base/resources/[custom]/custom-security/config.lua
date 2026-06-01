QBConfig = QBConfig or {}
QBConfig.Custom = QBConfig.Custom or {}

local function GetIntConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return math.floor(tonumber(val) or default) end
    return default
end

local function GetFloatConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return tonumber(val) or default end
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

-- 安全防刷配置
QBConfig.Custom.Security = {
    RateLimitMs = GetIntConvar('security_rate_limit_ms', 1000),             -- 敏感行为防刷冷却时长 (ms)
    MaxAddMoneyLimit = GetFloatConvar('security_max_add_money_limit', 50000.0), -- 单次资金变动上限
    MaxAddItemLimit = GetIntConvar('security_max_add_item_limit', 20),      -- 单次同类物品赋予上限
    MaxInteractionDistance = GetFloatConvar('security_max_interaction_distance', 10.0), -- 最大防瞬移交易距离
    CheckVehicleSpawn = GetBoolConvar('security_check_vehicle_spawn', true), -- 是否启用刷车服务端严格审查
    CheckWeaponGive = GetBoolConvar('security_check_weapon_give', true)     -- 是否审计指令武器获取
}
