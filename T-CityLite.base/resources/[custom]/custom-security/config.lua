QBConfig = QBConfig or {}
QBConfig.Custom = QBConfig.Custom or {}

-- 统一走 core-framework 的公共实现（原先这里有一份相同的解析）：
-- 用函数包一层，导出在调用时解析；资源启动顺序由 fxmanifest 的 dependencies 保证。
local GetIntConvar = function(...) return exports['core-framework']:ConvarInt(...) end

-- 统一走 core-framework 的公共实现（原先这里有一份相同的解析）：
-- 用函数包一层，导出在调用时解析；资源启动顺序由 fxmanifest 的 dependencies 保证。
local GetFloatConvar = function(...) return exports['core-framework']:ConvarFloat(...) end

-- 统一走 core-framework 的公共实现（原先这里有一份相同的解析）：
-- 用函数包一层，导出在调用时解析；资源启动顺序由 fxmanifest 的 dependencies 保证。
local GetBoolConvar = function(...) return exports['core-framework']:ConvarBool(...) end

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
