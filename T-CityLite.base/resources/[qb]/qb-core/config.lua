QBConfig = {}

QBConfig.MaxPlayers = GetConvarInt('sv_maxclients', 48) -- Gets max players from config file, default 48
QBConfig.DefaultSpawn = vector4(-1035.71, -2731.87, 12.86, 0.0)
QBConfig.UpdateInterval = 5                             -- how often to update player data in minutes
QBConfig.StatusInterval = 5000                          -- how often to check hunger/thirst status in milliseconds

QBConfig.Money = {}
QBConfig.Money.MoneyTypes = { cash = 500, bank = 5000, crypto = 0 } -- type = startamount - Add or remove money types for your server (for ex. blackmoney = 0), remember once added it will not be removed from the database!
QBConfig.Money.DontAllowMinus = { 'cash', 'crypto' }                -- Money that is not allowed going in minus
QBConfig.Money.MinusLimit = -5000                                    -- The maximum amount you can be negative 
QBConfig.Money.PayCheckTimeOut = 10                                 -- The time in minutes that it will give the paycheck
QBConfig.Money.PayCheckSociety = false                              -- If true paycheck will come from the society account that the player is employed at, requires qb-management

QBConfig.Player = {}
QBConfig.Player.HungerRate = 4.2 -- Rate at which hunger goes down.
QBConfig.Player.ThirstRate = 3.8 -- Rate at which thirst goes down.
QBConfig.Player.Bloodtypes = {
    'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-',
}

QBConfig.Player.PlayerDefaults = {
    citizenid = function() return QBCore.Player.CreateCitizenId() end,
    cid = 1,
    money = function()
        local moneyDefaults = {}
        for moneytype, startamount in pairs(QBConfig.Money.MoneyTypes) do
            moneyDefaults[moneytype] = startamount
        end
        return moneyDefaults
    end,
    optin = true,
    charinfo = {
        firstname = 'Firstname',
        lastname = 'Lastname',
        birthdate = '00-00-0000',
        gender = 0,
        nationality = 'USA',
        phone = function() return QBCore.Functions.CreatePhoneNumber() end,
        account = function() return QBCore.Functions.CreateAccountNumber() end
    },
    job = {
        name = 'unemployed',
        label = 'Civilian',
        payment = 10,
        type = 'none',
        onduty = false,
        isboss = false,
        grade = {
            name = 'Freelancer',
            level = 0
        }
    },
    gang = {
        name = 'none',
        label = 'No Gang Affiliation',
        isboss = false,
        grade = {
            name = 'none',
            level = 0
        }
    },
    metadata = {
        hunger = 100,
        thirst = 100,
        stress = 0,
        isdead = false,
        inlaststand = false,
        armor = 0,
        health = 200,
        ishandcuffed = false,
        tracker = false,
        injail = 0,
        jailitems = {},
        status = {},
        phone = {},
        rep = {},
        currentapartment = nil,
        callsign = 'NO CALLSIGN',
        bloodtype = function() return QBConfig.Player.Bloodtypes[math.random(1, #QBConfig.Player.Bloodtypes)] end,
        fingerprint = function() return QBCore.Player.CreateFingerId() end,
        walletid = function() return QBCore.Player.CreateWalletId() end,
        criminalrecord = {
            hasRecord = false,
            date = nil
        },
        licences = {
            driver = true,
            business = false,
            weapon = false,
            pilot = false,
            boat = false,
            heavy = false
        },
        cert_status = {
            driver = 'held',
            business = 'unclaimed',
            weapon = 'unclaimed',
            pilot = 'unclaimed',
            boat = 'unclaimed',
            heavy = 'unclaimed'
        },
        -- 三位一体: 资质 (Qualifications) — 跨阵营专业技术通行证
        -- 资质只认标签，不看职业/等级
        -- 示例: police_heli_pilot, advanced_surgery, heavy_weapons, undercover
        qualifications = {},
        inside = {
            house = nil,
            apartment = {
                apartmentType = nil,
                apartmentId = nil,
            }
        },
        phonedata = {
            SerialNumber = function() return QBCore.Player.CreateSerialNumber() end,
            InstalledApps = {}
        }
    },
    position = QBConfig.DefaultSpawn,
    items = {},
}

QBConfig.Server = {}                                    -- General server config
QBConfig.Server.Closed = false                          -- Set server closed (no one can join except people with ace permission 'qbadmin.join')
QBConfig.Server.ClosedReason = 'Server Closed'          -- Reason message to display when people can't join the server
QBConfig.Server.Uptime = 0                              -- Time the server has been up.
QBConfig.Server.Whitelist = false                       -- Enable or disable whitelist on the server
QBConfig.Server.WhitelistPermission = 'admin'           -- Permission that's able to enter the server when the whitelist is on
QBConfig.Server.PVP = true                              -- Enable or disable pvp on the server (Ability to shoot other players)
QBConfig.Server.Discord = ''                            -- Discord invite link
QBConfig.Server.CheckDuplicateLicense = true            -- Check for duplicate rockstar license on join
QBConfig.Server.Permissions = { 'god', 'admin', 'mod' } -- Add as many groups as you want here after creating them in your server.cfg

QBConfig.Commands = {}                                  -- Command Configuration
QBConfig.Commands.OOCColor = { 255, 151, 133 }          -- RGB color code for the OOC command

QBConfig.Notify = {}

-- ═══════════════════════════════════════════════════════════
-- 轨 3: 原生 GTA The Feed 配置
-- ═══════════════════════════════════════════════════════════
QBConfig.Notify.Native = {
    enabled = true,          -- 默认通道是否启用原生 Feed
    defaultDuration = 5000,   -- 默认显示时长 (ms)
}

-- ═══════════════════════════════════════════════════════════
-- 轨 2: NUI 高级通知配置
-- ═══════════════════════════════════════════════════════════
QBConfig.Notify.NotificationStyling = {
    group = false,      -- Allow notifications to stack with a badge instead of repeating
    position = 'right', -- top-left | top-right | bottom-left | bottom-right | top | bottom | left | right | center
    progress = true     -- Display Progress Bar
}

-- ═══════════════════════════════════════════════════════════
-- 轨 1: 插件注册契约 — 第三方模组可在此声明自定义通知类型
--       格式: { type = 'mission_pass', icon = 'CHAR_LESTER', channel = 'native'|'nui' }
--       注册后 Notify(text, 'mission_pass') 自动路由到对应通道
-- ═══════════════════════════════════════════════════════════
QBConfig.Notify.PluginTypes = {
    -- 示例 (取消注释以启用):
    -- { type = 'mission_pass',  icon = 'CHAR_LESTER',  channel = 'native', label = '任务通过' },
    -- { type = 'mission_fail',  icon = 'CHAR_LESTER',  channel = 'native', label = '任务失败' },
    -- { type = 'bounty_alert',  icon = 'CHAR_BLOCK',   channel = 'nui',    label = '悬赏通知' },
    -- { type = 'org_broadcast', icon = 'CHAR_CREW',    channel = 'nui',    label = '组织广播' },
}

-- These are how you define different notification variants
-- The "color" key is background of the notification
-- The "icon" key is the css-icon code, this project uses `Material Icons` & `Font Awesome`
QBConfig.Notify.VariantDefinitions = {
    success = {
        classes = 'success',
        icon = 'check_circle'
    },
    primary = {
        classes = 'primary',
        icon = 'notifications'
    },
    warning = {
        classes = 'warning',
        icon = 'warning'
    },
    error = {
        classes = 'error',
        icon = 'error'
    },
    police = {
        classes = 'police',
        icon = 'local_police'
    },
    ambulance = {
        classes = 'ambulance',
        icon = 'fas fa-ambulance'
    }
}

-- ============================================================================
-- 三位一体: 资质系统配置 (Qualifications)
-- ============================================================================
-- 资质是跨阵营的专业技术通行证，独立于职业和组织等级
-- 判断逻辑: 职业(Job) AND 等级(Rank) AND 资质(Qualification)
-- 维基: docs/ORGANIZATION_GUIDE.md
-- ============================================================================

QBConfig.Qualifications = {
    -- ── 航空类 (Aviation) ──────────────────────────────────────────
    civilian_heli_pilot = {
        label = 'Civilian Helicopter Pilot',
        category = 'aviation',
        description = '民用直升机驾驶资质，可操作非武装民用直升机',
        compatibleJobs = { 'taxi', 'mechanic', 'reporter' },
    },
    police_heli_pilot = {
        label = 'Police Helicopter Pilot',
        category = 'aviation',
        description = '警用直升机驾驶资质，可操作警用直升机进行空中巡逻',
        compatibleJobs = { 'police' },
    },
    advanced_heli_pilot = {
        label = 'Advanced Helicopter Pilot',
        category = 'aviation',
        description = '高级直升机驾驶资质，可操作重型/特殊用途直升机',
        compatibleJobs = { 'police', 'ambulance' },
    },

    -- ── 医疗类 (Medical) ──────────────────────────────────────────
    emt_basic = {
        label = 'Basic EMT',
        category = 'medical',
        description = '基础急救资质，可执行 CPR 和基础止血',
        compatibleJobs = { 'ambulance', 'police' },
    },
    emt_field = {
        label = 'Field EMT',
        category = 'medical',
        description = '现场急救资质，可在移动载具上执行急救脚本',
        compatibleJobs = { 'ambulance' },
    },
    advanced_surgery = {
        label = 'Advanced Surgery',
        category = 'medical',
        description = '高级外科手术资质，可执行高阶手术脚本',
        compatibleJobs = { 'ambulance' },
    },

    -- ── 武器类 (Weapon) ───────────────────────────────────────────
    civilian_concealed_carry = {
        label = 'Civilian Concealed Carry',
        category = 'weapon',
        description = '民用隐蔽持枪证，可携带手枪类武器',
        compatibleJobs = {},
    },
    police_firearm = {
        label = 'Police Firearm Certification',
        category = 'weapon',
        description = '警用持枪资质，可携带警用制式武器',
        compatibleJobs = { 'police' },
    },
    heavy_weapons = {
        label = 'Heavy Weapons Certification',
        category = 'weapon',
        description = '重型武器资质，可操作霰弹枪/冲锋枪/步枪',
        compatibleJobs = { 'police' },
    },

    -- ── 车辆类 (Vehicle) ──────────────────────────────────────────
    heavy_truck = {
        label = 'Heavy Truck License',
        category = 'vehicle',
        description = '重型卡车驾驶证，可驾驶卡车/运输车',
        compatibleJobs = { 'trucker', 'mechanic' },
    },
    special_vehicle = {
        label = 'Special Vehicle License',
        category = 'vehicle',
        description = '特种车辆驾驶证，可驾驶装甲车/特殊用途车辆',
        compatibleJobs = { 'police' },
    },

    -- ── 特殊类 (Special) ──────────────────────────────────────────
    undercover = {
        label = 'Undercover Operations',
        category = 'special',
        description = '卧底行动资质，可执行便衣侦查/卧底任务',
        compatibleJobs = { 'police' },
    },
    diving = {
        label = 'Commercial Diving',
        category = 'special',
        description = '商业潜水资质，可执行水下作业/打捞任务',
        compatibleJobs = { 'police', 'mechanic' },
    },
}

-- ============================================================================
-- 动态经济系统配置 (Economy)
-- ============================================================================
-- 统一奖励公式: final = base × globalMultiplier × heatCoefficient × playerBonus
-- 全局乘数由 custom-economy 自适应调节 Loop 自动管理
-- 热度系数由 HeatService 自动追踪和衰减
-- ============================================================================

QBConfig.Economy = {}

-- ── 活动热度追踪 (HeatService) ──────────────────────────────────────
QBConfig.Economy.Heat = {
    sampleWindowMinutes = 30,       -- 采样窗口 (分钟)，每窗口执行一次衰减计算
    decayRate = 0.05,               -- 每次衰减步长
    minCoefficient = 0.5,           -- 热度系数地板 (再热门的活动至少拿 50% 基础收益)
    maxCoefficient = 1.5,           -- 热度系数天花板 (再冷门的活动最多拿 150%)
    defaultCoefficient = 1.0,       -- 新活动的初始系数
}

-- ── 资金碎纸机 (SinkService) ────────────────────────────────────────
QBConfig.Economy.Sinks = {
    -- 玩家间大额交易印花税
    transaction_tax = {
        enabled = true,
        rate = 0.05,                -- 5% 税率
        minAmount = 10000,          -- 低于此金额的交易免税
        description = 'Government Stamp Duty',
    },
    -- ATM 存取款手续费
    atm_fee = {
        enabled = true,
        rate = 0.02,                -- 2% 手续费
        description = 'ATM Service Fee',
    },
    -- 车辆定期维护费
    vehicle_maintenance = {
        enabled = true,
        baseFee = 500,              -- 基础维护费
        ratePerValue = 0.001,       -- 车辆价值 × 0.1% 附加
        intervalHours = 48,         -- 每 48 小时扣一次
        description = 'Vehicle Maintenance',
    },
    -- 房产物业税
    housing_tax = {
        enabled = true,
        rate = 0.005,               -- 房产价值 × 0.5%
        intervalHours = 72,         -- 每 72 小时扣一次
        description = 'Property Tax',
    },
    -- 保释金
    prison_bail = {
        enabled = true,
        baseMultiplier = 1.0,       -- 原保释金乘数
        description = 'Prison Bail',
    },
    -- 车辆扣押取回费
    impound_fee = {
        enabled = true,
        baseFee = 2500,
        description = 'Vehicle Impound Fee',
    },
    -- 武器维修费 (桥接现有系统)
    weapon_repair = {
        enabled = true,
        description = 'Weapon Repair Cost',
    },
    -- 车辆购置税
    vehicle_purchase_tax = {
        enabled = true,
        rate = 0.08,                -- 新车购置税 8%
        description = 'Vehicle Purchase Tax',
    },
    -- 车辆过户印花税
    vehicle_transfer_tax = {
        enabled = true,
        rate = 0.05,                -- 过户税 5% (买方卖方各担一半)
        description = 'Vehicle Transfer Stamp Duty',
    },
    -- 车辆定期保险
    vehicle_insurance = {
        enabled = true,
        baseFee = 500,              -- 基础保险费
        ratePerValue = 0.001,       -- 车辆价值 × 0.1%
        intervalHours = 48,         -- 每 48 小时
        description = 'Vehicle Insurance',
    },
    -- 引擎大修费
    vehicle_overhaul = {
        enabled = true,
        baseFee = 1500,             -- 基础大修费
        ratePerValue = 0.002,       -- 车辆价值 × 0.2%
        mileageThreshold = 1000,    -- 每 1000 公里触发一次 (km)
        description = 'Engine Overhaul',
    },
}

-- ── 房产税阶梯配置 ──────────────────────────────────────────────────
QBConfig.Taxes = {}
QBConfig.Taxes.PropertyTax = {
    -- 房产数量阶梯: 越多越贵 (几何上升)
    tiers = {
        { count = 1,  rate = 0.003 },   -- 第1套: 0.3%
        { count = 2,  rate = 0.005 },   -- 第2套: 0.5%
        { count = 3,  rate = 0.010 },   -- 第3套: 1.0%
        { count = 5,  rate = 0.020 },   -- 第5套: 2.0%
        { count = 99, rate = 0.050 },   -- 5+套:  5.0%
    },
    -- 地段系数 (基于 houselocations.tier)
    locationMultipliers = {
        [1] = 0.8,   -- 郊区/廉价区
        [2] = 1.0,   -- 普通市区
        [3] = 1.5,   -- 高级住宅区
        [4] = 2.0,   -- 豪宅/海滨
    },
    -- 充公阈值: 连续欠费次数
    foreclosureThreshold = 3,
    -- 扣费间隔 (小时)
    intervalHours = 72,
}

-- ── 全局经济参数 ────────────────────────────────────────────────────
QBConfig.Economy.Global = {
    -- 管理员手动覆盖乘数 (优先级高于自适应调节)
    -- nil = 跟随自适应调节; 设置数值后锁定该乘数
    manualMultiplierOverride = nil,

    -- 自适应调节阈值 (同时作为 custom-economy Convar 的默认值参考)
    highInflationNetPerHour = 150000,    -- 全服每小时净增超过此值 → 降低 RewardScale
    lowActivityNetPerHour = 30000,       -- 全服每小时净增低于此值 → 提升 RewardScale
    scaleStep = 0.05,                    -- 每次调节步长
    minRewardScale = 0.8,               -- RewardScale 地板
    maxRewardScale = 1.4,               -- RewardScale 天花板
}
