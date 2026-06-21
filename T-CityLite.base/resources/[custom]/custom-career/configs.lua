-- configs.lua — custom-career 职业身份配置 v2
--
-- 🏢 组织架构: 组织 > 职业 > 个人等级
--   每个职业必须属于一个组织，组织是仓库/权限/身份的容器
--   默认: 无业者 → 组织 = "个人"

QBConfig = QBConfig or {}
QBConfig.Career = QBConfig.Career or {}

-- =============================================================
-- 🏢 组织定义 (与 custom-storage 配置保持同步)
-- =============================================================
-- 组织分为三类:
--   job  — 合法职业组织 (按总部/公司)
--   gang — 非法帮派组织
--   personal — 个人 (默认，不属于任何组织)

QBConfig.Career.Organizations = {
    -- === 合法组织 (按总部/公司) ===
    lspd = {
        label = '洛圣都警察局 (LSPD)',
        type = 'job',
        jobs = { 'police' },
    },
    pillbox = {
        label = 'Pillbox Hill 医疗中心',
        type = 'job',
        jobs = { 'ambulance' },
    },
    cityhall = {
        label = '洛圣都市政厅',
        type = 'job',
        jobs = { 'mayor' },
    },
    courthouse = {
        label = '洛圣都法院',
        type = 'job',
        jobs = { 'judge' },
    },
    lawfirm = {
        label = '洛圣都律师事务所',
        type = 'job',
        jobs = { 'lawyer' },
    },
    mining_co = {
        label = '洛圣都矿业公司',
        type = 'job',
        jobs = { 'miner' },
    },
    taxi_co = {
        label = '洛圣都出租车公司',
        type = 'job',
        jobs = { 'taxi' },
    },
    bus_co = {
        label = '洛圣都公交公司',
        type = 'job',
        jobs = { 'bus' },
    },
    trucking_co = {
        label = '洛圣都货运物流',
        type = 'job',
        jobs = { 'trucker' },
    },
    tow_co = {
        label = '洛圣都拖车服务',
        type = 'job',
        jobs = { 'tow' },
    },
    lscustoms = {
        label = 'LS Customs 改装连锁',
        type = 'job',
        jobs = { 'mechanic', 'mechanic2', 'mechanic3' },
    },
    beekers = {
        label = 'Beeker\'s Garage',
        type = 'job',
        jobs = { 'beeker' },
    },
    bennys = {
        label = 'Benny\'s Original Motor Works',
        type = 'job',
        jobs = { 'bennys' },
    },
    news_co = {
        label = '洛圣都新闻社',
        type = 'job',
        jobs = { 'reporter' },
    },
    garbage_co = {
        label = '洛圣都环卫局',
        type = 'job',
        jobs = { 'garbage' },
    },
    vineyard = {
        label = '洛圣都葡萄酒庄园',
        type = 'job',
        jobs = { 'vineyard' },
    },
    hotdog = {
        label = '热狗连锁摊贩',
        type = 'job',
        jobs = { 'hotdog' },
    },
    cardealer = {
        label = '洛圣都汽车经销商',
        type = 'job',
        jobs = { 'cardealer' },
    },
    realestate = {
        label = '洛圣都地产公司',
        type = 'job',
        jobs = { 'realestate' },
    },

    -- === 非法组织 / 帮派 ===
    cartel   = { label = 'Cartel 集团',         type = 'gang', gang = 'cartel' },
    ballas   = { label = 'Ballas 帮派',          type = 'gang', gang = 'ballas' },
    vagos    = { label = 'Vagos 帮派',           type = 'gang', gang = 'vagos' },
    lostmc   = { label = 'The Lost MC 摩托帮',   type = 'gang', gang = 'lostmc' },
    families = { label = 'Families 帮派',        type = 'gang', gang = 'families' },
    triads   = { label = '三合会',               type = 'gang', gang = 'triads' },

    -- === 个人 (默认) ===
    personal = {
        label = '个人',
        type = 'personal',
        jobs = {},
    },
}

-- =============================================================
-- 阶层定义
-- =============================================================
QBConfig.Career.Tiers = {
    boss   = { label = '教父',   permissions = { 'kpi_terminal', 'catalyst', 'godfather' } },
    leader = { label = '领袖',   permissions = { 'kpi_terminal', 'catalyst' } },
    mid    = { label = '中层',   permissions = { 'dept_manage' } },
    entry  = { label = '基层',   permissions = {} },
}

-- =============================================================
-- 🔑 组织查找 API
-- =============================================================

--- 根据 job 名查找所属组织
function QBConfig.Career.FindOrgByJob(jobName)
    for orgId, org in pairs(QBConfig.Career.Organizations) do
        if org.type == 'job' then
            for _, j in ipairs(org.jobs) do
                if j == jobName then return orgId, org end
            end
        end
    end
    return 'personal', QBConfig.Career.Organizations.personal
end

--- 根据 gang 名查找所属组织
function QBConfig.Career.FindOrgByGang(gangName)
    for orgId, org in pairs(QBConfig.Career.Organizations) do
        if org.type == 'gang' and org.gang == gangName then
            return orgId, org
        end
    end
    return 'personal', QBConfig.Career.Organizations.personal
end

--- 解析玩家当前组织 (帮派优先)
function QBConfig.Career.ResolvePlayerOrg(job, gang)
    if gang and gang.name and gang.name ~= 'none' then
        return QBConfig.Career.FindOrgByGang(gang.name)
    end
    if job and job.name and job.name ~= 'unemployed' then
        return QBConfig.Career.FindOrgByJob(job.name)
    end
    return 'personal', QBConfig.Career.Organizations.personal
end

local jobCount, gangCount = 0, 0
for _, o in pairs(QBConfig.Career.Organizations) do
    if o.type == 'job' then jobCount = jobCount + 1
    elseif o.type == 'gang' then gangCount = gangCount + 1 end
end
-- career-config startup print removed
