-- main.lua — custom-mining 矿业系统服务端
--
-- 职责:
--   1. 处理矿石采集请求 (校验工具/位置/冷却)
--   2. 产出随机矿石
--   3. 自动存入组织仓库 (miner 150格)
--   4. 注册 Bus.MiningService

local QBCore = exports['qb-core']:GetCoreObject()
MiningService = {}

-- 采集冷却: citizenid → last_mine_time
local cooldowns = {}

-- ==============================================================
-- 采集事件
-- ==============================================================

RegisterNetEvent('mining:server:mineOre', function(siteId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 职业校验 (必须是 miner)
    local job = Player.PlayerData.job
    if not job or job.name ~= 'miner' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'mining_staff_only'), 'error')
        return
    end

    -- 2. 系统开关
    if not Config.Mining.Enabled then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'mining_disabled'), 'error')
        return
    end

    -- 3. 冷却校验
    local cid = Player.PlayerData.citizenid
    local now = os.time()
    local last = cooldowns[cid] or 0
    if now - last < Config.Mining.Security.cooldownSec then
        return -- 静默拒绝，防止UI抖动
    end
    cooldowns[cid] = now

    -- 4. 矿点校验
    local site = nil
    for _, s in ipairs(Config.Mining.Sites) do
        if s.id == siteId then site = s; break end
    end
    if not site then return end

    -- 5. 工具检测 (客户端带了什么矿镐)
    local toolName = 'pickaxe'
    if QBCore.Functions.HasItem(src, 'pickaxe_legendary', 1) then
        toolName = 'pickaxe_legendary'
    elseif QBCore.Functions.HasItem(src, 'pickaxe_pro', 1) then
        toolName = 'pickaxe_pro'
    elseif not QBCore.Functions.HasItem(src, 'pickaxe', 1) then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'mining_need_pickaxe'), 'error')
        return
    end

    local tool = Config.Mining.Tools[toolName]

    -- 6. 加权随机选矿 (按 weight 权重)
    local grade = job.grade and job.grade.level or 0
    local eligibleOres = {}
    local totalWeight = 0
    for _, ore in ipairs(site.ores) do
        if grade >= ore.minGrade then
            eligibleOres[#eligibleOres + 1] = ore
            totalWeight = totalWeight + ore.weight
        end
    end
    if #eligibleOres == 0 then return end

    local roll = math.random() * totalWeight
    local cumulative = 0
    local selectedOre = eligibleOres[1]
    for _, ore in ipairs(eligibleOres) do
        cumulative = cumulative + ore.weight
        if roll <= cumulative then selectedOre = ore; break end
    end

    -- 7. 计算产出 (可能双倍)
    local yield = 1
    if math.random() < tool.yieldBonus then
        yield = 2
    end

    -- 8. 安全清洗
    if Bus and Bus.SecurityService then
        local ok, _, cleanedCount = Bus.SecurityService.ValidateItemEvent(src, selectedOre.name, yield)
        if ok then yield = cleanedCount end
    end

    -- 9. 尝试存入组织仓库 (优先)
    local storedInOrg = false
    if Bus and Bus.StorageService then
        local canAccess = Bus.StorageService.CanAccess(src, 'mining_co')
        if canAccess then
            local addOk = Bus.StorageService.AddItem('mining_co', selectedOre.name, yield, nil, nil)
            if addOk then storedInOrg = true end
        end
    end

    -- fallback: 玩家背包
    if not storedInOrg then
        exports['qb-inventory']:AddItem(src, selectedOre.name, yield, nil, nil, 'Mining')
    end

    -- 10. 通知客户端结果
    TriggerClientEvent('mining:client:oreMined', src, {
        oreName = selectedOre.name,
        oreLabel = selectedOre.label,
        yield = yield,
        storedInOrg = storedInOrg,
        isDouble = yield > 1,
    })
end)

-- ==============================================================
-- 回调: 获取矿点列表
-- ==============================================================
QBCore.Functions.CreateCallback('mining:server:getSites', function(source, cb)
    local sites = {}
    for _, s in ipairs(Config.Mining.Sites) do
        table.insert(sites, {
            id = s.id,
            label = s.label,
            coords = s.coords,
            radius = s.radius,
        })
    end
    cb(sites)
end)

-- ==============================================================
-- 公共 API
-- ==============================================================
function MiningService.GetSites() return Config.Mining.Sites end
function MiningService.GetSmeltRecipes() return Config.Mining.SmeltRecipes end
function MiningService.GetToolStats(toolName) return Config.Mining.Tools[toolName] end

-- ==============================================================
-- 注册到 Bus
-- ==============================================================
if Bus and Bus.RegisterService then
    Bus.RegisterService('mining', {
        GetSites = MiningService.GetSites,
        GetSmeltRecipes = MiningService.GetSmeltRecipes,
        GetToolStats = MiningService.GetToolStats,
    })
end

-- ==============================================================
-- 命令
-- ==============================================================
QBCore.Commands.Add('mine', '查看矿点列表', {}, false, function(source)
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 200, 50 },
        args = { '⛏️ 矿点列表', '' }
    })
    for _, s in ipairs(Config.Mining.Sites) do
        TriggerClientEvent('chat:addMessage', source, {
            color = { 200, 200, 200 },
            args = { '  ', ('%s — 坐标: %.0f, %.0f'):format(s.label, s.coords.x, s.coords.y) }
        })
    end
end, 'user')

print('[custom-mining] ⛏️  矿业服务已注册到 Bus')
