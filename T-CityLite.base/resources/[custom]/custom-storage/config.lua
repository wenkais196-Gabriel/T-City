-- config.lua — custom-storage 组织仓库配置 v2
--
-- 🏢 组织架构: 一个组织可包含多个职业，共享同一个仓库
--    - 合法组织按「总部/公司」划分 (如 LSPD 包含 police 等)
--    - 非法组织按帮派划分 (cartel/ballas/vagos)
--    - 无组织玩家使用「个人」仓库
--
-- 命令:
--   /jobstorage   → 显示 组织名+职业名+等级 → 打开组织仓库
--   /gangstorage  → 显示 组织名+帮派名+等级 → 打开帮派仓库
--   /orgstoragelist → 管理员查看全部组织配置

-- =============================================================
-- 🔒 局部变量存储，不依赖全局 Config
-- =============================================================

local Organizations = {

    -- ==========================================================
    -- 合法组织 (按总部/公司)
    -- ==========================================================

    lspd = {
        label = '洛圣都警察局 (LSPD)',
        type = 'job',
        jobs = { 'police' },
        storage = { maxSlots = 80, maxWeight = 500000 },
    },

    pillbox = {
        label = 'Pillbox Hill 医疗中心',
        type = 'job',
        jobs = { 'ambulance' },
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    cityhall = {
        label = '洛圣都市政厅',
        type = 'job',
        jobs = { 'mayor' },
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    courthouse = {
        label = '洛圣都法院',
        type = 'job',
        jobs = { 'judge' },
        storage = { maxSlots = 50, maxWeight = 200000 },
    },

    lawfirm = {
        label = '洛圣都律师事务所',
        type = 'job',
        jobs = { 'lawyer' },
        storage = { maxSlots = 50, maxWeight = 200000 },
    },

    mining_co = {
        label = '洛圣都矿业公司',
        type = 'job',
        jobs = { 'miner' },
        storage = { maxSlots = 150, maxWeight = 1000000 },
    },

    taxi_co = {
        label = '洛圣都出租车公司',
        type = 'job',
        jobs = { 'taxi' },
        storage = { maxSlots = 50, maxWeight = 200000 },
    },

    bus_co = {
        label = '洛圣都公交公司',
        type = 'job',
        jobs = { 'bus' },
        storage = { maxSlots = 50, maxWeight = 200000 },
    },

    trucking_co = {
        label = '洛圣都货运物流',
        type = 'job',
        jobs = { 'trucker' },
        storage = { maxSlots = 80, maxWeight = 500000 },
    },

    tow_co = {
        label = '洛圣都拖车服务',
        type = 'job',
        jobs = { 'tow' },
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    lscustoms = {
        label = 'LS Customs 改装连锁',
        type = 'job',
        jobs = { 'mechanic', 'mechanic2', 'mechanic3' },
        storage = { maxSlots = 80, maxWeight = 500000 },
    },

    beekers = {
        label = 'Beeker\'s Garage',
        type = 'job',
        jobs = { 'beeker' },
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    bennys = {
        label = 'Benny\'s Original Motor Works',
        type = 'job',
        jobs = { 'bennys' },
        storage = { maxSlots = 80, maxWeight = 500000 },
    },

    news_co = {
        label = '洛圣都新闻社',
        type = 'job',
        jobs = { 'reporter' },
        storage = { maxSlots = 50, maxWeight = 200000 },
    },

    garbage_co = {
        label = '洛圣都环卫局',
        type = 'job',
        jobs = { 'garbage' },
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    vineyard = {
        label = '洛圣都葡萄酒庄园',
        type = 'job',
        jobs = { 'vineyard' },
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    hotdog = {
        label = '热狗连锁摊贩',
        type = 'job',
        jobs = { 'hotdog' },
        storage = { maxSlots = 30, maxWeight = 100000 },
    },

    cardealer = {
        label = '洛圣都汽车经销商',
        type = 'job',
        jobs = { 'cardealer' },
        storage = { maxSlots = 80, maxWeight = 500000 },
    },

    realestate = {
        label = '洛圣都地产公司',
        type = 'job',
        jobs = { 'realestate' },
        storage = { maxSlots = 50, maxWeight = 200000 },
    },

    -- ==========================================================
    -- 非法组织 / 帮派
    -- ==========================================================
    cartel = {
        label = 'Cartel 集团',
        type = 'gang',
        gang = 'cartel',
        storage = { maxSlots = 80, maxWeight = 500000 },
    },

    ballas = {
        label = 'Ballas 帮派',
        type = 'gang',
        gang = 'ballas',
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    vagos = {
        label = 'Vagos 帮派',
        type = 'gang',
        gang = 'vagos',
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    lostmc = {
        label = 'The Lost MC 摩托帮',
        type = 'gang',
        gang = 'lostmc',
        storage = { maxSlots = 70, maxWeight = 400000 },
    },

    families = {
        label = 'Families 帮派',
        type = 'gang',
        gang = 'families',
        storage = { maxSlots = 60, maxWeight = 300000 },
    },

    triads = {
        label = '三合会',
        type = 'gang',
        gang = 'triads',
        storage = { maxSlots = 70, maxWeight = 400000 },
    },
}

-- =============================================================
-- 🔑 核心 API
-- =============================================================

--- 根据 job 名查找所属组织
---@param jobName string
---@return string|nil orgId, table|nil orgConfig
function FindOrgByJob(jobName)
    for orgId, org in pairs(Organizations) do
        if org.type == 'job' then
            for _, j in ipairs(org.jobs) do
                if j == jobName then return orgId, org end
            end
        end
    end
    return nil, nil
end

--- 根据 gang 名查找所属组织
---@param gangName string
---@return string|nil orgId, table|nil orgConfig
function FindOrgByGang(gangName)
    for orgId, org in pairs(Organizations) do
        if org.type == 'gang' and org.gang == gangName then
            return orgId, org
        end
    end
    return nil, nil
end

--- 获取组织配置
function GetOrgConfig(orgId)
    return Organizations[orgId]
end

--- 获取所有组织列表
function GetAllOrgs()
    local list = {}
    for orgId, org in pairs(Organizations) do
        table.insert(list, {
            id = orgId,
            label = org.label,
            type = org.type,
            jobs = org.jobs,
            gang = org.gang,
            maxSlots = org.storage.maxSlots,
            maxWeight = org.storage.maxWeight,
        })
    end
    table.sort(list, function(a, b)
        if a.type == b.type then return a.label < b.label end
        return a.type < b.type
    end)
    return list
end

--- 查找玩家所属组织
---@param job table player's job data
---@param gang table player's gang data
---@return string orgId, table orgConfig, string displayType
function FindPlayerOrg(job, gang)
    -- 1. 帮派优先 (非法组织)
    if gang and gang.name and gang.name ~= 'none' then
        local orgId, org = FindOrgByGang(gang.name)
        if orgId then return orgId, org, 'gang' end
    end

    -- 2. 职业组织
    if job and job.name and job.name ~= 'unemployed' then
        local orgId, org = FindOrgByJob(job.name)
        if orgId then return orgId, org, 'job' end
    end

    -- 3. 无组织归属
    return nil, nil, 'none'
end

-- 暴露到全局
_G.Organizations = Organizations

local jobOrgCount = 0; local gangOrgCount = 0
for _, org in pairs(Organizations) do
    if org.type == 'job' then jobOrgCount = jobOrgCount + 1
    elseif org.type == 'gang' then gangOrgCount = gangOrgCount + 1 end
end
-- storage-config startup print removed (production mode)
