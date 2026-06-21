-- config.lua — custom-quest 全局配置
--
-- 所有 Convar 定义 + 默认值 + 服务端/客户端共享常量

Config = Config or {}
Config.Quest = {}

-- ==============================================================
-- 系统开关
-- ==============================================================

-- 任务系统总开关
Config.Quest.Enabled = GetConvar('quest_enable', 'true') == 'true'

-- 每玩家同时最多接取的任务数
Config.Quest.MaxActiveQuests = tonumber(GetConvar('quest_max_active', '3')) or 3

-- 任务接取冷却（秒）
Config.Quest.AcceptCooldown = tonumber(GetConvar('quest_accept_cooldown', '5')) or 5

-- ==============================================================
-- 安全配置
-- ==============================================================

Config.Quest.Security = {
    -- Nonce Token 有效期（秒）
    NonceExpiry = tonumber(GetConvar('quest_nonce_expiry', '30')) or 30,

    -- Rate Limit: 同一操作最小间隔（毫秒）
    RateLimitMs = tonumber(GetConvar('quest_rate_limit_ms', '1000')) or 1000,

    -- 距离校验最大容差（米）
    MaxReachDistance = tonumber(GetConvar('quest_max_reach_distance', '25')) or 25,

    -- 启用 Nonce Token 校验
    EnforceNonce = GetConvar('quest_enforce_nonce', 'true') == 'true',

    -- 启用顺序强制
    EnforceStepOrder = GetConvar('quest_enforce_step_order', 'true') == 'true',

    -- v0.7.0 新增: 速度异常检测（防止瞬移作弊）
    EnableSpeedCheck = GetConvar('quest_speed_check', 'true') == 'true',

    -- 最大允许移动速度 (m/s)，超过即判定为瞬移
    MaxSpeedMps = tonumber(GetConvar('quest_max_speed_mps', '200')) or 200,

    -- v0.7.0 新增: 全局令牌桶熔断（全服共享）
    EnableGlobalRateLimit = GetConvar('quest_global_rate_limit', 'true') == 'true',

    -- 每秒允许的全局操作令牌数
    GlobalTokensPerSecond = tonumber(GetConvar('quest_global_tokens_per_sec', '50')) or 50,

    -- v0.7.0 新增: script_trigger 步骤的 Export 白名单
    -- 格式: "resource:exportName" → true
    AllowedScriptExports = {
        ['custom-mining:MineOre'] = true,
        ['custom-heist:CheckVaultDoor'] = true,
        ['custom-garage:SpawnMissionVehicle'] = true,
        ['custom-crime:LaunderMoney'] = true,
    },

    -- v0.7.0 新增: 最大步骤尝试次数（防止暴力枚举）
    MaxStepAttempts = tonumber(GetConvar('quest_max_step_attempts', '10')) or 10,
}

-- ==============================================================
-- 奖励配置
-- ==============================================================

Config.Quest.Rewards = {
    -- 是否经统一经济出口
    UseAddScaledMoney = GetConvar('quest_use_scaled_money', 'true') == 'true',

    -- 默认货币类型
    DefaultAccountType = GetConvar('quest_default_account', 'bank') or 'bank',
}

-- ==============================================================
-- 缓存配置
-- ==============================================================

Config.Quest.Cache = {
    -- 活跃任务缓存 TTL（秒）— v0.8b: 60s→1800s (30min)
    -- 运输任务单趟 5-10 分钟，60s 过期会导致缓存清空→步骤验证失败
    ActiveQuestTTL = tonumber(GetConvar('quest_cache_ttl_active', '1800')) or 1800,

    -- 冷却缓存 TTL（秒）
    CooldownTTL = tonumber(GetConvar('quest_cache_ttl_cooldown', '300')) or 300,
}

-- ==============================================================
-- 步骤类型枚举（服务端/客户端共享）
-- ==============================================================

Config.Quest.StepTypes = {
    REACH          = 'reach',           -- 到达指定位置
    COLLECT        = 'collect',         -- 收集物品
    SCRIPT_TRIGGER = 'script_trigger',  -- 调用外部脚本 export
    CUSTOM_EVENT   = 'custom_event',    -- 监听外部脚本事件
    VALIDATOR      = 'validator',       -- 自定义校验器（服务端权威校验）
    INTERACT       = 'interact',        -- 与物体/NPC交互（进度条+动画）
    DELIVER        = 'deliver',         -- 运送物资/车辆到指定地点
    GOTO           = 'goto',            -- 前往坐标（与reach等价）
    COMBAT         = 'combat',          -- 消灭指定NPC
    WAIT           = 'wait',            -- 在区域内生存/等待
    PLACEMENT      = 'placement',       -- v0.10: 实体放置回收（自动脱钩+验证+延迟回收）
    DECISION       = 'decision',        -- v0.7 story-engine: 剧情决策点（弹出NUI选择）
    REWARD         = 'reward',          -- 奖励步骤（自动完成）
}

-- ==============================================================
-- v0.11: Checkpoint 配置 (Native GTA Checkpoint 指引 + 自动验证)
-- ==============================================================

Config.Quest.Checkpoint = {
    -- 是否启用 native checkpoint (false → fallback 到 PolyZone)
    Enabled = GetConvar('quest_checkpoint_enabled', 'true') == 'true',

    -- 距离轮询间隔 (ms) — 飞行任务建议 150-200，地面 300
    PollIntervalMs = tonumber(GetConvar('quest_checkpoint_poll_ms', '200')) or 200,

    -- 垂直容差 (m) — 飞机穿过 ring checkpoint 时允许的高度偏差
    -- ring 类型: 默认 ±50m (飞行中高度难以精确控制)
    -- cylinder 类型: 默认 ±10m (地面区域)
    HeightTolerance = {
        ring     = tonumber(GetConvar('quest_cp_ht_ring', '50')) or 50,
        cylinder = tonumber(GetConvar('quest_cp_ht_cylinder', '10')) or 10,
        arrow    = tonumber(GetConvar('quest_cp_ht_arrow', '5')) or 5,
    },

    -- 默认检测半径 (m) — 按 checkpoint 类型
    DefaultRadius = {
        ring     = 30.0,   -- 环形航路点: 30m 检测半径
        cylinder = 15.0,   -- 地面目的地: 15m
        arrow    = 10.0,   -- 交互点: 10m
    },

    -- 步骤类型 → 默认 checkpoint 类型映射
    -- 未在此映射中的步骤类型不创建 checkpoint
    DefaultTypeMap = {
        reach     = 'ring',
        ['goto']  = 'ring',    -- goto 是 Lua 5.4 关键字，必须 ['goto']
        validator = 'cylinder',
        interact  = 'arrow',
        deliver   = 'cylinder',
    },

    -- 默认颜色 (RGB)
    DefaultColor = { 0, 255, 0 },     -- 绿色

    -- 颜色含义:
    --   绿 (0,255,0)     → 当前目标
    --   蓝 (0,180,255)   → 下一步预告
    --   灰 (128,128,128) → 已完成
    --   红 (255,60,60)   → 计时倒计时
}

-- ==============================================================
-- 任务状态枚举
-- ==============================================================

Config.Quest.Status = {
    NOT_STARTED   = 'not_started',
    IN_PROGRESS   = 'in_progress',
    COMPLETED     = 'completed',
    FAILED        = 'failed',
    ABANDONED     = 'abandoned',
}

-- ==============================================================
-- 事件名常量
-- ==============================================================

Config.Quest.Events = {
    -- 服务端 → 客户端
    QUEST_ACCEPTED       = 'quest:client:accepted',
    QUEST_PROGRESS       = 'quest:client:progress',
    QUEST_STEP_ADVANCED  = 'quest:client:stepAdvanced',
    QUEST_COMPLETED      = 'quest:client:completed',
    QUEST_FAILED         = 'quest:client:failed',
    QUEST_ABANDONED      = 'quest:client:abandoned',
    QUEST_STATE_RESTORE  = 'quest:client:restoreState',     -- v0.7.0: 重连恢复

    -- 客户端 → 服务端
    QUEST_ACCEPT         = 'quest:server:accept',
    QUEST_ABANDON        = 'quest:server:abandon',
    QUEST_REACH          = 'quest:server:reach',
    QUEST_COLLECT        = 'quest:server:collect',          -- v0.7.0: 收集物品
    QUEST_REQUEST_STATE  = 'quest:server:requestState',     -- v0.7.0: 请求状态恢复
    QUEST_REQUEST_NONCE  = 'quest:server:requestNonce',     -- v0.7.0: 请求 Nonce Token
}

-- quest-config startup print removed (production mode)