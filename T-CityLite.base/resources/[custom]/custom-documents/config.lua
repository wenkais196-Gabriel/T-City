-- ============================================================
-- Document Registry — 统一文档注册表
-- 新增文档类型只需在此表加一行，无需改动任何核心逻辑
-- ============================================================

Config = Config or {}

-- 3D 文字出示配置
Config.PresentDuration = 8000        -- 头顶显示时长 (ms)
Config.NotifyNearbyRadius = 3.5      -- 附近提示半径 (GTA 单位)
Config.NotifyNearbyEnabled = true    -- 是否通知附近玩家

-- 警察/法官查验权限配置
Config.PoliceJobs = {                -- 允许查验的职业
    ['police'] = 0,                  -- 最低警衔 (0 = 所有警察)
    ['judge'] = 0,                   -- 🔧 自愈: 法官也需查验证照
}
Config.PoliceVerifyDistance = 3.5    -- 查验距离

-- ============================================================
-- 文档注册表
-- key:     物品名 (对应 items.lua 中 name)
-- label:   文档标签
-- icon:    目标菜单图标 (FontAwesome 5)
-- fields:  要展示的物品 info 字段列表 (空表 = 仅展示 serail)
-- ============================================================

Config.Documents = {
    id_card = {
        label = 'ID Card',
        icon = 'fas fa-id-card',
        fields = { 'citizenid', 'firstname', 'lastname', 'birthdate', 'gender', 'nationality' },
        presentText = '{firstname} {lastname} 出示了 ID 卡',   -- 附近提示模板 {field}
    },
    driver_license = {
        label = 'Drivers License',
        icon = 'fas fa-car',
        fields = { 'type', 'firstname', 'lastname', 'birthdate' },
        presentText = '{firstname} {lastname} 出示了驾照',
    },
    pilot_license = {
        label = 'Pilot License',
        icon = 'fas fa-helicopter',
        fields = { 'type', 'firstname', 'lastname' },
        presentText = '{firstname} {lastname} 出示了飞行执照',
    },
    boat_license = {
        label = 'Boat License',
        icon = 'fas fa-ship',
        fields = { 'type', 'firstname', 'lastname' },
        presentText = '{firstname} {lastname} 出示了船舶执照',
    },
    heavy_license = {
        label = 'Heavy Vehicle License',
        icon = 'fas fa-truck',
        fields = { 'type', 'firstname', 'lastname' },
        presentText = '{firstname} {lastname} 出示了重型载具执照',
    },
    weaponlicense = {
        label = 'Weapon License',
        icon = 'fas fa-gun',
        fields = {},
        presentText = '{firstname} {lastname} 出示了武器执照',
    },
    lawyerpass = {
        label = 'Lawyer Pass',
        icon = 'fas fa-scale-balanced',
        fields = { 'firstname', 'lastname' },
        presentText = '{firstname} {lastname} 出示了律师证',
    },
    -- 未来扩展示例:
    -- business_license = {
    --     label = 'Business License',
    --     icon = 'fas fa-store',
    --     fields = { 'businessName', 'type' },
    --     presentText = '{firstname} {lastname} 出示了营业执照',
    -- },
}

-- ============================================================
-- 查验结果格式化 — 用于警察查验时的证照状态展示
-- cert_status: 'unclaimed' | 'held' | 'suspended' | 'revoked'
-- ============================================================

Config.CertStatusLabels = {
    unclaimed = '未申领',
    held = '✅ 持有',
    suspended = '⏸ 暂停',
    revoked = '❌ 吊销',
}

Config.CertLabelMap = {
    driver = '驾照',
    weapon = '武器证',
    pilot = '飞行执照',
    boat = '船舶执照',
    heavy = '重型载具执照',
    business = '营业执照',
}
