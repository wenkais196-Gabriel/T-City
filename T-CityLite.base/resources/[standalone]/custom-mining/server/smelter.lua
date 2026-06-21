-- smelter.lua — 冶炼引擎
--
-- 矿石 → 金属锭，消耗煤炭作为燃料
-- 3 ore + 1~2 coal → 1 ingot

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 冶炼事件
-- ==============================================================
RegisterNetEvent('mining:server:smeltOre', function(recipeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 职业校验
    local job = Player.PlayerData.job
    if not job or job.name ~= 'miner' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'mining_smelter_staff_only'), 'error')
        return
    end

    -- 2. 配方校验
    local recipe = nil
    for _, r in ipairs(Config.Mining.SmeltRecipes) do
        if r.id == recipeId then recipe = r; break end
    end
    if not recipe then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'unknown_recipe'), 'error')
        return
    end

    -- 3. 原料校验
    for _, input in ipairs(recipe.inputs) do
        if not QBCore.Functions.HasItem(src, input.name, input.count) then
            TriggerClientEvent('QBCore:Notify', src,
                ('原料不足: 需要 %d x %s'):format(input.count, input.label), 'error')
            return
        end
    end

    -- 4. 消耗原料
    for _, input in ipairs(recipe.inputs) do
        exports['qb-inventory']:RemoveItem(src, input.name, input.count, nil, 'Smelter')
    end

    -- 5. 判定成功/失败
    if math.random() < recipe.failRate then
        TriggerClientEvent('QBCore:Notify', src, ('冶炼失败！%s已损坏'):format(recipe.label), 'error')
        return
    end

    -- 6. 产出 → 优先组织仓库
    local storedInOrg = false
    if Bus and Bus.StorageService then
        local canAccess = Bus.StorageService.CanAccess(src, 'mining_co')
        if canAccess then
            storedInOrg = Bus.StorageService.AddItem('mining_co', recipe.output.name, recipe.output.count, nil, nil)
        end
    end
    if not storedInOrg then
        exports['qb-inventory']:AddItem(src, recipe.output.name, recipe.output.count, nil, nil, 'Smelter')
    end

    TriggerClientEvent('QBCore:Notify', src,
        ('✅ 冶炼成功: %d x %s%s'):format(recipe.output.count, recipe.output.label,
            storedInOrg and ' (已存入组织仓库)' or ''), 'success')
end)

-- ==============================================================
-- 回调: 获取配方
-- ==============================================================
QBCore.Functions.CreateCallback('mining:server:getSmeltRecipes', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Player.PlayerData.job or Player.PlayerData.job.name ~= 'miner' then
        cb({}); return
    end
    cb(Config.Mining.SmeltRecipes)
end)

print('[mining-smelter] 🔥 冶炼引擎已加载')
