-- config/vehicles.lua — 6类载具多模态配置 (v2.0)
--
-- 数据驱动: 新增载具/调整面板只需修改此文件
-- 每个 class 定义: 模板名, 轮询间隔, 功能开关, 特有字段

DashboardConfig = DashboardConfig or {}

-- ==============================================================
-- GTA V 车辆 Class 常量 (参考)
-- ==============================================================
-- 0:Compacts  1:Sedans  2:SUVs  3:Coupes  4:Muscle  5:SportsClassics
-- 6:Sports  7:Super  8:Motorcycles  9:OffRoad  10:Industrial
-- 11:Utility  12:Vans  13:Cycles  14:Boats  15:Helicopters
-- 16:Planes  17:Service  18:Emergency  19:Military  20:Commercial
-- 21:Trains  22:OpenWheels

-- ==============================================================
-- 6 大模板映射: VehicleClass → Template + Category
-- ==============================================================

DashboardConfig.TemplateMap = {
    -- 🏎️ 跑车/赛车/摩托 → Sports 模板
    ['sports'] = {
        classes = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 22 },
        pollIntervalMs = 150,  -- 高频 (RPM/档位需要)
    },
    -- 🚛 商用/重卡/工业 → Commercial 模板
    ['commercial'] = {
        classes = { 10, 12, 17, 19, 20 },
        pollIntervalMs = 250,
    },
    -- 🚔 公共服务 (警/救护/消防) → Emergency 模板
    ['emergency'] = {
        classes = { 18 },
        pollIntervalMs = 200,
    },
    -- ✈️ 固定翼飞机 → Plane 模板
    ['plane'] = {
        classes = { 16 },
        pollIntervalMs = 150,  -- 高频 (高度/空速)
    },
    -- 🚁 直升机 → Helicopter 模板
    ['helicopter'] = {
        classes = { 15 },
        pollIntervalMs = 150,
    },
    -- 🚤 船只/游艇 → Boat 模板
    ['boat'] = {
        classes = { 14 },
        pollIntervalMs = 300,
    },
}

-- ==============================================================
-- 功能特征矩阵 (Feature Flags per Template)
-- ==============================================================

DashboardConfig.FeatureFlags = {
    -- 🏎️ 跑车/赛车/摩托
    sports = {
        -- 诊断页
        diag_rpm            = true,   -- RPM转速表
        diag_rpm_redline    = 0.85,   -- 红线区阈值 (RPM ratio)
        diag_gear           = true,   -- 当前档位
        diag_speed_mph      = true,   -- 时速 (mph)
        diag_speed_kmh      = true,   -- 时速 (km/h)
        diag_fuel           = true,   -- 燃油
        diag_engine_health  = true,
        diag_body_health    = true,
        diag_oil_life       = true,
        diag_coolant        = true,
        diag_battery        = true,
        diag_trans_temp     = true,
        diag_turbo          = true,   -- 涡轮增压
        -- 控制页
        ctrl_engine         = true,
        ctrl_lock           = true,
        ctrl_windows        = true,
        ctrl_hood           = true,
        ctrl_trunk          = true,
        ctrl_doors          = true,
        ctrl_hazard         = true,
        ctrl_alarm          = true,
        -- 特有控制
        ctrl_launch_control = true,   -- 弹射起步
        ctrl_spoiler        = true,   -- 尾翼升降
        ctrl_neon           = true,   -- 霓虹灯
        ctrl_tcs            = true,   -- 牵引力控制
        -- 驾驶模式
        drive_comfort       = true,
        drive_sport         = true,
        drive_eco           = true,
        drive_cruise        = true,
    },
    -- 🚛 商用/重卡/工业
    commercial = {
        diag_speed_mph      = true,
        diag_speed_kmh      = true,
        diag_rpm            = true,
        diag_fuel           = true,
        diag_engine_health  = true,
        diag_body_health    = true,
        diag_oil_life       = true,
        diag_coolant        = true,
        diag_battery        = true,
        diag_trailer        = true,   -- 挂车状态
        diag_air_brake      = true,   -- 气刹压力
        diag_gross_weight   = true,   -- 总重估算
        ctrl_engine         = true,
        ctrl_lock           = true,
        ctrl_windows        = true,
        ctrl_cargo_door     = true,   -- 货舱门
        ctrl_trailer_lock   = true,   -- 挂车锁
        ctrl_axle_lock      = true,   -- 多轴转向锁
        ctrl_hazard         = true,
        ctrl_alarm          = true,
        drive_comfort       = true,
        drive_freight       = true,   -- 货运模式
        drive_eco           = true,
        drive_cruise        = true,
    },
    -- 🚔 公共服务 (警/救护/消防)
    emergency = {
        diag_speed_mph      = true,
        diag_speed_kmh      = true,
        diag_rpm            = true,
        diag_fuel           = true,
        diag_engine_health  = true,
        diag_body_health    = true,
        diag_siren          = true,   -- 警笛状态
        diag_lightbar       = true,   -- 警灯状态
        ctrl_engine         = true,
        ctrl_lock           = true,
        ctrl_windows        = true,
        ctrl_hazard         = true,
        ctrl_siren          = true,   -- 警笛控制
        ctrl_megaphone      = true,   -- PA喊话
        ctrl_radar          = true,   -- 测速雷达
        ctrl_wanted_db      = true,   -- 通缉数据库
        ctrl_spotlight      = true,   -- 探照灯
        ctrl_water_cannon   = true,   -- 水炮(消防)
        ctrl_rear_door      = true,   -- 后门(救护)
        ctrl_dashcam        = true,   -- 行车记录仪
        -- 🚔 v2.1 警车新增功能
        ctrl_anpr           = true,   -- ANPR 车牌自动识别
        ctrl_tracker        = true,   -- GPS 追踪器
        ctrl_camera         = true,   -- CCTV 监控摄像头
        ctrl_flagplate      = true,   -- 车牌标记/查询
        ctrl_impound        = true,   -- 扣押附近车辆
        ctrl_speed_radar    = true,   -- 测速雷达枪
        drive_comfort       = true,
        drive_sport         = true,
        drive_cruise        = true,
    },
    -- ✈️ 固定翼飞机
    plane = {
        diag_altitude       = true,   -- 绝对高度
        diag_ground_alt     = true,   -- 雷达高度
        diag_airspeed       = true,   -- 空速
        diag_ground_speed   = true,   -- 地速
        diag_vsi            = true,   -- 垂直速率
        diag_heading        = true,   -- 航向
        diag_engine_health  = true,
        diag_fuel           = true,
        ctrl_engine         = true,
        ctrl_landing_gear   = true,   -- 起落架
        ctrl_flaps          = true,   -- 襟翼
        ctrl_flares         = true,   -- 热诱弹
        ctrl_autopilot      = true,   -- 自动驾驶
        ctrl_transponder    = true,   -- 应答机
        ctrl_lights         = true,
    },
    -- 🚁 直升机
    helicopter = {
        diag_altitude       = true,
        diag_ground_alt     = true,   -- 雷达高度计
        diag_airspeed       = true,
        diag_heading        = true,
        diag_yaw            = true,   -- 偏航
        diag_engine_health  = true,
        diag_fuel           = true,
        diag_wind           = true,   -- 风偏模拟
        ctrl_engine         = true,
        ctrl_hoist          = true,   -- 绞盘/吊钩
        ctrl_rappel         = true,   -- 索降
        ctrl_spotlight      = true,   -- 探照灯
        ctrl_night_vision   = true,   -- 夜视/热成像
        ctrl_flares         = true,
        ctrl_lights         = true,
    },
    -- 🚤 船只/游艇
    boat = {
        diag_speed_knots    = true,   -- 节
        diag_depth          = true,   -- 水深
        diag_heading        = true,   -- 罗盘航向
        diag_engine_health  = true,
        diag_fuel           = true,
        diag_draft          = true,   -- 吃水深度
        ctrl_engine         = true,
        ctrl_anchor         = true,   -- 抛锚/收锚
        ctrl_bilge_pump     = true,   -- 舱底排水
        ctrl_trim           = true,   -- 双引擎配平
        ctrl_lights         = true,
        ctrl_sonar          = true,   -- 声呐
    },
}

-- ==============================================================
-- 泛用功能 (所有模板共享)
-- ==============================================================

DashboardConfig.GlobalFeatures = {
    -- 全部模板都有的基础诊断
    base_diag = { 'diag_speed_mph', 'diag_fuel', 'diag_engine_health', 'diag_body_health' },
    -- 全部模板都有的基础控制
    base_ctrl = { 'ctrl_engine', 'ctrl_lock', 'ctrl_windows', 'ctrl_hazard' },
    -- 夜间模式
    night_mode = true,
    -- 驾驶模式 (由具体模板决定哪些可用)
    base_drive = { 'drive_cruise' },
}

-- ==============================================================
-- NUI 配置
-- ==============================================================

DashboardConfig.NUI = {
    -- 毛玻璃模糊度
    blurAmount = 24,
    -- 面板尺寸
    width = 440,
    height = 600,
    -- 位置 (right/top 百分比)
    positionRight = 20,  -- px from right edge
    positionTop = 50,    -- % from top
    -- 过渡动画时长
    transitionMs = 250,
}

-- ==============================================================
-- 性能配置
-- ==============================================================

DashboardConfig.Performance = {
    -- 默认轮询间隔 (ms) — 由各模板覆盖
    defaultPollInterval = 200,
    -- 操作冷却 (ms)
    actionCooldownMs = 1000,
    -- 最大轮询失败次数 (超过后降低频率)
    maxPollErrors = 5,
}

-- ==============================================================
-- 安全配置
-- ==============================================================

DashboardConfig.Security = {
    -- 驾驶席校验 (所有人)
    requireDriverSeat = true,
    -- 最大交互距离 (米)
    maxInteractionDistance = 5.0,
    -- Rate Limit (ms)
    rateLimitMs = 1000,
    -- 需要职业鉴权的操作
    jobRestricted = {
        siren        = { 'police', 'ambulance', 'fire' },
        megaphone    = { 'police', 'ambulance', 'fire' },
        radar        = { 'police' },
        wanted_db    = { 'police' },
        water_cannon = { 'fire' },
        dashcam      = { 'police' },
        -- v2.1 警车新增功能鉴权
        anpr         = { 'police' },
        tracker      = { 'police' },
        camera       = { 'police' },
        flagplate    = { 'police' },
        impound      = { 'police' },
        speed_radar  = { 'police' },
    },
}

-- ==============================================================
-- v2.1 警用监控摄像头配置 (镜像 qb-policejob)
-- ==============================================================

DashboardConfig.SecurityCameras = {
    cameras = {
        [1]  = { label = 'Pacific Bank CAM#1', canRotate = false },
        [2]  = { label = 'Pacific Bank CAM#2', canRotate = false },
        [3]  = { label = 'Pacific Bank CAM#3', canRotate = false },
        [4]  = { label = 'Limited Ltd Grove St. CAM#1', canRotate = false },
        [5]  = { label = "Rob's Liqour Prosperity St. CAM#1", canRotate = false },
        [6]  = { label = "Rob's Liqour San Andreas Ave. CAM#1", canRotate = false },
        [7]  = { label = 'Limited Ltd Ginger St. CAM#1', canRotate = false },
        [8]  = { label = '24/7 Supermarkt Innocence Blvd. CAM#1', canRotate = false },
        [9]  = { label = "Rob's Liqour El Rancho Blvd. CAM#1", canRotate = false },
        [10] = { label = 'Limited Ltd West Mirror Drive CAM#1', canRotate = false },
        [11] = { label = '24/7 Supermarkt Clinton Ave CAM#1', canRotate = false },
        [12] = { label = 'Limited Ltd Banham Canyon Dr CAM#1', canRotate = false },
        [13] = { label = "Rob's Liqour Great Ocean Hwy CAM#1", canRotate = false },
        [14] = { label = '24/7 Supermarkt Ineseno Road CAM#1', canRotate = false },
        [15] = { label = '24/7 Supermarkt Barbareno Rd. CAM#1', canRotate = false },
        [16] = { label = '24/7 Supermarkt Route 68 CAM#1', canRotate = false },
        [17] = { label = "Rob's Liqour Route 68 CAM#1", canRotate = false },
        [18] = { label = '24/7 Supermarkt Senora Fwy CAM#1', canRotate = false },
        [19] = { label = '24/7 Supermarkt Alhambra Dr. CAM#1', canRotate = false },
        [20] = { label = '24/7 Supermarkt Senora Fwy CAM#2', canRotate = false },
        [21] = { label = 'Fleeca Bank Hawick Ave CAM#1', canRotate = false },
        [22] = { label = 'Fleeca Bank Legion Square CAM#1', canRotate = false },
        [23] = { label = 'Fleeca Bank Hawick Ave CAM#2', canRotate = false },
        [24] = { label = 'Fleeca Bank Del Perro Blvd CAM#1', canRotate = false },
        [25] = { label = 'Fleeca Bank Great Ocean Hwy CAM#1', canRotate = false },
        [26] = { label = 'Paleto Bank CAM#1', canRotate = false },
        [27] = { label = 'Del Vecchio Liquor Paleto Bay', canRotate = false },
        [28] = { label = "Don's Country Store Paleto Bay CAM#1", canRotate = false },
        [29] = { label = "Don's Country Store Paleto Bay CAM#2", canRotate = false },
        [30] = { label = "Don's Country Store Paleto Bay CAM#3", canRotate = false },
        [31] = { label = 'Vangelico Jewelery CAM#1', canRotate = true },
        [32] = { label = 'Vangelico Jewelery CAM#2', canRotate = true },
        [33] = { label = 'Vangelico Jewelery CAM#3', canRotate = true },
        [34] = { label = 'Vangelico Jewelery CAM#4', canRotate = true },
    },
}

-- ==============================================================
-- 工具函数
-- ==============================================================

--- 根据 vehicleClass 返回模板名
function DashboardConfig.GetTemplate(class)
    for name, cfg in pairs(DashboardConfig.TemplateMap) do
        for _, c in ipairs(cfg.classes) do
            if c == class then return name, cfg.pollIntervalMs end
        end
    end
    return 'sports', 200  -- 默认回退到 sports 模板
end

--- 检查某模板是否启用某功能
function DashboardConfig.HasFeature(template, feature)
    local flags = DashboardConfig.FeatureFlags[template]
    if not flags then return false end
    return flags[feature] == true
end

--- 获取模板的轮询数据字段列表
function DashboardConfig.GetPollFields(template)
    local flags = DashboardConfig.FeatureFlags[template]
    if not flags then return {} end
    local fields = {}
    for k, v in pairs(flags) do
        if v == true and (k:find('^diag_') or k:find('^ctrl_')) then
            fields[#fields + 1] = k
        end
    end
    return fields
end

print('[tcity-dashboard] ⚙️ 载具配置已加载 — 6类模板就绪')
