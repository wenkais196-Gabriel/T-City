-- config.lua — custom-vehicles 全局配置
--
-- 所有 Convar 定义 + 默认值 + 服务端/客户端共享常量
-- 运行时可动态调整，无需重启

Config = Config or {}
Config.Vehicles = {}

-- ==============================================================
-- 系统开关
-- ==============================================================

-- 总开关
Config.Vehicles.Enabled = GetConvar('vehicles_enable', 'true') == 'true'

-- 兼容桥开关（启用旧版 qb-vehiclekeys exports 桥接）
Config.Vehicles.CompatEnabled = GetConvar('vehicles_compat_enable', 'true') == 'true'

-- ==============================================================
-- 安全配置
-- ==============================================================

Config.Vehicles.Security = {
    -- 热线发动 / 撬锁最大物理距离（米）
    MaxInteractionDistance = tonumber(GetConvar('vehicles_max_interaction_dist', '5.0')) or 5.0,

    -- 热线发动耗时（毫秒）
    HotwireDuration = tonumber(GetConvar('vehicles_hotwire_duration', '15000')) or 15000,

    -- 撬锁耗时（毫秒）
    LockpickDuration = tonumber(GetConvar('vehicles_lockpick_duration', '10000')) or 10000,

    -- 热线发动成功概率（0-100） — 硬核模式
    HotwireSuccessChance = tonumber(GetConvar('vehicles_hotwire_chance', '30')) or 30,

    -- 撬锁成功概率（0-100） — 硬核模式
    LockpickSuccessChance = tonumber(GetConvar('vehicles_lockpick_chance', '40')) or 40,

    -- 防盗警报触发概率（0-100） — 硬核模式
    AlarmChance = tonumber(GetConvar('vehicles_alarm_chance', '50')) or 50,

    -- Rate Limit 间隔（毫秒）
    RateLimitMs = tonumber(GetConvar('vehicles_rate_limit_ms', '3000')) or 3000,

    -- NPC / 街头车辆默认上锁（true = 无钥匙无法开门上车）
    LockNPCVehicles = GetConvar('vehicles_lock_npc', 'true') == 'true',

    -- 自行车(13)不锁，其余 NPC/街头载具全锁
    NoLockVehicleClasses = { 13 },

    -- 上车拦截轮询间隔（毫秒），值越大 CPU 开销越低但拦截响应越慢
    EntryCheckIntervalMs = tonumber(GetConvar('vehicles_entry_check_ms', '250')) or 250,
}

-- ==============================================================
-- 性能配置
-- ==============================================================

Config.Vehicles.Performance = {
    -- 客户端钥匙缓存 TTL（秒）。0 = 无限，仅靠服务端推送事件刷新。
    -- 设为 0 避免锁车后可解锁/不可解锁的状态不一致（temp 钥匙生命周期 = 本次登录）。
    ClientCacheTTL = tonumber(GetConvar('vehicles_client_cache_ttl', '0')) or 0,
}

-- ==============================================================
-- 钥匙类型
-- ==============================================================

Config.Vehicles.KeyTypes = {
    OWNER    = 'owner',     -- 车主钥匙（永久，绑定 citizenid）
    SHARED   = 'shared',    -- 共享钥匙（临时，可撤销）
    TEMP     = 'temp',      -- 临时钥匙（任务/租车，下线释放）
    HOTWIRED = 'hotwired',  -- 热线发动（单次，15秒有效）
}

-- ==============================================================
-- 事件名常量（服务端/客户端共享）
-- ==============================================================

Config.Vehicles.Events = {
    -- 服务端 ↔ 客户端
    KEYS_UPDATED     = 'custom-vehicles:client:keysUpdated',
    ENGINE_TOGGLE    = 'custom-vehicles:client:engineToggle',
    LOCK_TOGGLE      = 'custom-vehicles:client:lockToggle',

    -- 客户端 → 服务端
    REQUEST_KEYS     = 'custom-vehicles:server:requestKeys',
    HOTWIRE_ATTEMPT  = 'custom-vehicles:server:hotwireAttempt',
    LOCKPICK_ATTEMPT = 'custom-vehicles:server:lockpickAttempt',
    GIVE_KEYS        = 'custom-vehicles:server:giveKeys',
    REMOVE_KEYS      = 'custom-vehicles:server:removeKeys',
    CHECK_KEYS       = 'custom-vehicles:server:checkKeys',
}

-- ==============================================================
-- 职业共享钥匙（替代 qb-vehiclekeys 的 Config.SharedKeys）
-- ==============================================================

Config.Vehicles.SharedKeys = {
    ['police'] = {
        requireOnduty = false,
        vehicles = { 'police', 'police2' },
    },
    ['mechanic'] = {
        requireOnduty = false,
        vehicles = { 'towtruck' },
    },
}

-- ==============================================================
-- Carjack 抢夺车辆（替代 qb-vehiclekeys 的 Carjack 功能）
-- ==============================================================

Config.Vehicles.CarJackEnable = GetConvar('vehicles_carjack_enable', 'true') == 'true'
Config.Vehicles.CarjackingTime = tonumber(GetConvar('vehicles_carjack_time', '7500')) or 7500
Config.Vehicles.DelayBetweenCarjackings = tonumber(GetConvar('vehicles_carjack_cooldown', '10000')) or 10000
Config.Vehicles.CarjackChance = {
    ['2685387236'] = 0.0,  -- melee
    ['416676503']  = 0.5,  -- handguns
    ['-957766203'] = 0.75, -- SMG
    ['860033945']  = 0.90, -- shotgun
    ['970310034']  = 0.90, -- assault
    ['1159398588'] = 0.99, -- LMG
    ['3082541095'] = 0.99, -- sniper
    ['2725924767'] = 0.99, -- heavy
    ['1548507267'] = 0.0,  -- throwable
    ['4257178988'] = 0.0,  -- misc
}
Config.Vehicles.NoCarjackWeapons = {
    'WEAPON_UNARMED', 'WEAPON_Knife', 'WEAPON_Nightstick', 'WEAPON_HAMMER',
    'WEAPON_Bat', 'WEAPON_Crowbar', 'WEAPON_Golfclub', 'WEAPON_Bottle',
    'WEAPON_Dagger', 'WEAPON_Hatchet', 'WEAPON_KnuckleDuster', 'WEAPON_Machete',
    'WEAPON_Flashlight', 'WEAPON_SwitchBlade', 'WEAPON_Poolcue', 'WEAPON_Wrench',
    'WEAPON_Battleaxe', 'WEAPON_Grenade', 'WEAPON_StickyBomb', 'WEAPON_ProximityMine',
    'WEAPON_BZGas', 'WEAPON_Molotov', 'WEAPON_FireExtinguisher', 'WEAPON_PetrolCan',
    'WEAPON_Flare', 'WEAPON_Ball', 'WEAPON_Snowball', 'WEAPON_SmokeGrenade',
}
Config.Vehicles.ImmuneVehicles = { 'stockade' }
Config.Vehicles.PoliceAlertChance = 0.75
Config.Vehicles.PoliceNightAlertChance = 0.50
Config.Vehicles.AlertCooldown = 10000

-- ==============================================================
-- v0.9: 车辆状态管理 (里程/引擎损耗/磨损部件/氮气/Tuner)
-- ==============================================================

Config.Vehicles.State = {
    -- 总开关: 是否启用里程追踪
    UseDistance = GetConvar('vehicles_state_distance', 'true') == 'true',

    -- 是否根据里程扣引擎健康度
    UseDistanceDamage = GetConvar('vehicles_state_distance_damage', 'true') == 'true',

    -- 是否启用磨损部件 (散热器/车轴/刹车/离合器/油箱)
    UseWearableParts = GetConvar('vehicles_state_wearable', 'true') == 'true',

    -- 磨损触发概率 (每 Tick 千分比, 1 = 0.1%)
    WearablePartsChance = tonumber(GetConvar('vehicles_state_wearable_chance', '1')) or 1,

    -- 磨损部件效果触发阈值 (≤25 触发故障效果)
    DamageThreshold = tonumber(GetConvar('vehicles_state_damage_threshold', '25')) or 25,

    -- 警告阈值 (≤50 工具箱中显示黄色)
    WarningThreshold = tonumber(GetConvar('vehicles_state_warning_threshold', '50')) or 50,

    -- 里程→引擎损耗映射 (同一档位只扣一次，不会帧级重复)
    MinimalMetersForDamage = {
        { min = 5000,  max = 10000, damage = 10 },
        { min = 15000, max = 20000, damage = 20 },
        { min = 25000, max = 30000, damage = 30 },
    },

    -- 磨损部件定义 (maxValue + 修理材料)
    WearableParts = {
        radiator = { label = '散热器',  maxValue = 100 },
        axle     = { label = '车轴',    maxValue = 100 },
        brakes   = { label = '刹车',    maxValue = 100 },
        clutch   = { label = '离合器',  maxValue = 100 },
        fuel     = { label = '燃油管',  maxValue = 100 },
    },

    -- 氮气强化倍率
    NitrousBoost = tonumber(GetConvar('vehicles_state_nitrous_boost', '1.8')) or 1.8,

    -- 氮气每帧消耗
    NitrousUsage = tonumber(GetConvar('vehicles_state_nitrous_usage', '0.1')) or 0.1,

    -- 不追踪的载具类型 (13=自行车 14=船 15=直升机 16=飞机 21=火车)
    IgnoreClasses = {
        [13] = true, [14] = true, [15] = true, [16] = true, [21] = true,
    },

    -- 燃油资源名 (ex. 'LegacyFuel', 'cdn-fuel', 'ps-fuel')
    FuelResource = GetConvar('vehicles_state_fuel_resource', 'LegacyFuel') or 'LegacyFuel',
}

print('[custom-vehicles] ⚙️ 配置已加载')
