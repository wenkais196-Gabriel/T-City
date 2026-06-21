-- config.lua — custom-justice 司法系统配置

Config = Config or {}
Config.Justice = {}

-- =============================================================
-- 罪名与刑期配置
-- =============================================================
Config.Justice.Crimes = {
    -- 暴力犯罪
    murder =      { label = '谋杀',       baseMinutes = 120, maxMinutes = 480, fine = 50000, category = 'violent' },
    assault =     { label = '故意伤害',   baseMinutes = 30,  maxMinutes = 120, fine = 15000, category = 'violent' },
    kidnapping =  { label = '绑架',       baseMinutes = 60,  maxMinutes = 240, fine = 30000, category = 'violent' },

    -- 毒品犯罪
    drug_traffic = { label = '毒品贩运',  baseMinutes = 90,  maxMinutes = 360, fine = 80000, category = 'drug' },
    drug_possess = { label = '持有毒品',  baseMinutes = 15,  maxMinutes = 60,  fine = 10000, category = 'drug' },
    drug_produce = { label = '制造毒品',  baseMinutes = 60,  maxMinutes = 240, fine = 50000, category = 'drug' },

    -- 财产犯罪
    robbery =     { label = '抢劫',       baseMinutes = 45,  maxMinutes = 180, fine = 25000, category = 'property' },
    burglary =    { label = '入室盗窃',   baseMinutes = 30,  maxMinutes = 120, fine = 20000, category = 'property' },
    theft =       { label = '盗窃',       baseMinutes = 15,  maxMinutes = 60,  fine = 10000, category = 'property' },
    fraud =       { label = '诈骗',       baseMinutes = 30,  maxMinutes = 180, fine = 40000, category = 'property' },

    -- 公共秩序
    evasion =     { label = '拒捕/逃逸',  baseMinutes = 20,  maxMinutes = 90,  fine = 15000, category = 'public' },
    trespass =    { label = '非法入侵',   baseMinutes = 10,  maxMinutes = 30,  fine = 5000,  category = 'public' },
    weapon_poss = { label = '非法持枪',   baseMinutes = 30,  maxMinutes = 120, fine = 20000, category = 'public' },
}

-- =============================================================
-- 减刑机制
-- =============================================================
Config.Justice.Reductions = {
    lawyer_defense  = { rate = 0.30, label = '律师辩护',   desc = '律师出庭辩护，最高减刑30%' },
    community_service = { rate = 0.25, label = '社区服务', desc = '完成社区服务任务，减刑25%' },
    snitch          = { rate = 0.40, label = '举报立功',   desc = '举报其他犯罪分子，减刑40%' },
    good_behavior   = { rate = 0.15, label = '良好表现',   desc = '狱中表现良好自动减刑15%' },
    first_offense   = { rate = 0.20, label = '初犯减免',   desc = '首次犯罪减刑20%' },
}

-- =============================================================
-- 律师配置
-- =============================================================
Config.Justice.Lawyer = {
    minOnlineForAssignment = 1,     -- 至少需要1名律师在线才能安排辩护
    feeBase = 5000,                 -- 基础律师费
    feePerMinute = 500,             -- 每分钟庭审附加费
    cooldownMinutes = 30,           -- 律师接案冷却
}

-- =============================================================
-- 法院位置
-- =============================================================
Config.Justice.Courthouse = {
    coords = vector3(243.0, -1093.0, 29.3),
    radius = 5.0,
    label = { zh = '洛圣都法院', en = 'Los Santos Courthouse' },
    blip = { sprite = 419, color = 38, scale = 1.0, label = { zh = '法院', en = 'Courthouse' } },
}

-- =============================================================
-- 监狱参数
-- =============================================================
Config.Justice.Prison = {
    coords = vector3(1680.0, 2510.0, 45.0),   -- Bolingbroke 监狱
    releaseCoords = vector3(1840.0, 2585.0, 46.0),  -- 出狱点
    interior = vector3(1685.0, 2500.0, 45.0),
    blip = { sprite = 188, color = 1, scale = 1.0, label = { zh = '州立监狱', en = 'State Prison' } },

    -- 探视
    visitDuration = 10,            -- 探视时长(分钟)
    visitCooldown = 60,            -- 探视冷却(分钟)
    maxVisitors = 2,               -- 每次最多探视人数

    -- 社区服务
    communityServiceMinutes = 30,  -- 社区服务折算比率: 30分钟服务 = 抵扣60分钟刑期
    communityServiceRatio = 2.0,   -- 1分钟服务 = X分钟刑期抵扣
}

-- justice-config startup print removed
