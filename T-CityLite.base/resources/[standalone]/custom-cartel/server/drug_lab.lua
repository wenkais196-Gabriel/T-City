-- drug_lab.lua — 毒品生产配方引擎
--
-- 核心机制:
--   1. 原料校验: 检查玩家背包是否有足够原料
--   2. 安全校验: SecurityService 清洗 + 等级检查 + 冷却检查
--   3. 加工计时: 客户端进度条/小游戏
--   4. 概率失败: 失败消耗原料无产出，成功消耗原料产出成品
--   5. 产出处理: 成品进入玩家背包或组织仓库
--   6. 审计日志: 大额生产记录
--
-- 事件流:
--   Client → cartel:server:startProduction → 校验 → 开始加工
--   Client → cartel:server:finishProduction → 确认完成 → 产出

local QBCore = exports['qb-core']:GetCoreObject()

-- Resolve bilingual { en, zh } labels — server defaults to English
local function L(val)
    if type(val) == 'table' then return val.en or val.zh or '???' end
    return val
end

-- ==============================================================
-- 事件: 开始生产
-- ==============================================================

RegisterNetEvent('cartel:server:startProduction', function(recipeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 系统开关
    if not Config.Cartel.Enabled then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_disabled'), 'error')
        return
    end

    -- 2. 成员校验
    local isMember, grade = CartelService.IsMember(src)
    if not isMember then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_not_member'), 'error')
        return
    end

    -- 3. 配方校验
    local recipe = Config.Cartel.Recipes[recipeId]
    if not recipe then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_unknown_recipe', tostring(recipeId)), 'error')
        return
    end

    -- 4. 等级校验
    if grade < recipe.requiredGrade then
        TriggerClientEvent('QBCore:Notify', src,
            ('Requires Cartel rank %d+ to produce %s'):format(recipe.requiredGrade, L(recipe.label)),
            'error')
        return
    end

    -- 5. 冷却校验
    local canProduce, remaining = CartelService.CheckProductionCooldown(Player.PlayerData.citizenid)
    if not canProduce then
        TriggerClientEvent('QBCore:Notify', src,
            ('Cooldown: %d seconds remaining'):format(remaining), 'error')
        return
    end

    -- 6. 原料校验 (检查是否拥有足够原料)
    for _, input in ipairs(recipe.inputs) do
        local hasItem = QBCore.Functions.HasItem(src, input.name, input.count)
        if not hasItem then
            TriggerClientEvent('QBCore:Notify', src,
                ('Missing ingredients: need %d x %s'):format(input.count, L(input.label)),
                'error')
            return
        end
    end

    -- 7. 安全清洗 (通过 SecurityService)
    if Bus and Bus.SecurityService then
        local ok, cleanedItem, cleanedCount, err = Bus.SecurityService.ValidateItemEvent(
            src, recipe.output.name, recipe.output.count
        )
        if not ok then
            TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_security_fail', err or 'unknown'), 'error')
            return
        end
    end

    -- 8. 设置冷却
    CartelService.SetProductionCooldown(Player.PlayerData.citizenid)

    -- 9. 通知客户端开始加工 (返回配方信息)
    TriggerClientEvent('cartel:client:productionStarted', src, {
        recipeId = recipeId,
        label = recipe.label,
        duration = recipe.duration,
        minigame = recipe.minigame,
    })

    print(('[cartel-lab] 🔬 %s started production: %s (rank %d, %ds)')
        :format(GetPlayerName(src), L(recipe.label), grade, recipe.duration))
end)

-- ==============================================================
-- 事件: 完成生产 (客户端加工结束后回调)
-- ==============================================================

RegisterNetEvent('cartel:server:finishProduction', function(recipeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local recipe = Config.Cartel.Recipes[recipeId]
    if not recipe then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_recipe_error'), 'error')
        return
    end

    -- 再次校验成员身份
    local isMember, _ = CartelService.IsMember(src)
    if not isMember then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_identity_fail'), 'error')
        return
    end

    -- 再次校验原料 (防止中间被转移)
    for _, input in ipairs(recipe.inputs) do
        local hasItem = QBCore.Functions.HasItem(src, input.name, input.count)
        if not hasItem then
            TriggerClientEvent('QBCore:Notify', src,
                ('Missing materials: need %d x %s (may have been moved)'):format(input.count, L(input.label)),
                'error')
            return
        end
    end

    -- ==============================================================
    -- 判定成功/失败
    -- ==============================================================
    local roll = math.random()
    local isSuccess = roll > recipe.failRate

    -- 消费原料 (无论成败都消耗)
    for _, input in ipairs(recipe.inputs) do
        exports['qb-inventory']:RemoveItem(src, input.name, input.count, nil, 'CartelLab:' .. recipeId)
    end

    if not isSuccess then
        -- 失败: 原料已消耗，无产出
        TriggerClientEvent('QBCore:Notify', src,
            ('Production failed! %s was damaged, ingredients consumed'):format(L(recipe.label)), 'error')

        -- 审计日志
        if exports['custom-logs'] then
            exports['custom-logs']:LogGeneric('Cartel Production Failed',
                ('**%s** (%s) | Recipe: %s | Fail Rate: %d%%'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid,
                    L(recipe.label), math.floor(recipe.failRate * 100)
                ), 16744576)
        end
        return
    end

    -- ==============================================================
    -- 成功: 给予产出物
    -- ==============================================================

    -- 尝试存入组织仓库 (优先)
    local storedInOrg = false
    if Bus and Bus.StorageService then
        local canAccess, _ = Bus.StorageService.CanAccess(src, 'cartel')
        if canAccess then
            local addOk = Bus.StorageService.AddItem('cartel',
                recipe.output.name, recipe.output.count, nil, nil)
            if addOk then
                storedInOrg = true
            end
        end
    end

    -- fallback: 存入玩家背包
    if not storedInOrg then
        exports['qb-inventory']:AddItem(src, recipe.output.name, recipe.output.count, nil, nil, 'CartelLab')
    end

    -- 通知
    TriggerClientEvent('QBCore:Notify', src,
        ('✅ Produced %d x %s%s'):format(
            recipe.output.count, L(recipe.output.label),
            storedInOrg and ' (stored in org vault)' or ''
        ), 'success')

    -- 审计日志
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('Cartel Production Success',
            ('**%s** (%s) | Recipe: %s | Output: %d x %s | Dest: %s'):format(
                GetPlayerName(src), Player.PlayerData.citizenid,
                L(recipe.label), recipe.output.count, L(recipe.output.label),
                storedInOrg and 'Org Vault' or 'Personal Inventory'
            ), 65280)
    end

    -- ==============================================================
    -- Raid 检测 (概率触发警察突袭)
    -- ==============================================================
    local shouldRaid, policeCount = CartelService.CheckRaidConditions()
    if shouldRaid then
        -- 通知所有在线警察
        local alertText = ('🚨 Intel: Drug production detected at Cartel farm! Online police: %d'):format(policeCount)
        TriggerClientEvent('police:client:cartelRaidAlert', -1, {
            coords = Config.Cartel.LabLocation.coords,
            message = alertText,
        })

        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('Cartel Raid触发',
                ('**Producer**: %s (%s) | **Online Police**: %d'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid, policeCount
                ))
        end
    end

    -- 🌐 Atmosphere: danger scene on cartel production (raid risk)
    if shouldRaid and Bus and Bus.SafeCall then Bus.SafeCall('atmosphere', 'PlayScene', src, 'danger') end

    print(('[cartel-lab] ✅ %s produced %d x %s (raid risk: %s)')
        :format(GetPlayerName(src), recipe.output.count, L(recipe.output.label),
            shouldRaid and '⚠️ TRIGGERED' or 'Safe'))
end)

-- ==============================================================
-- 回调: 获取配方列表 (供客户端 UI)
-- ==============================================================

QBCore.Functions.CreateCallback('cartel:server:getRecipes', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({}); return end

    local _, grade = CartelService.IsMember(source)
    if not grade then cb({}); return end

    local available = {}
    for recipeId, recipe in pairs(Config.Cartel.Recipes) do
        if grade >= recipe.requiredGrade then
            local canProduce, _ = CartelService.CheckProductionCooldown(Player.PlayerData.citizenid)
            table.insert(available, {
                id = recipeId,
                label = recipe.label,
                description = recipe.description,
                inputs = recipe.inputs,
                output = recipe.output,
                duration = recipe.duration,
                failRate = recipe.failRate,
                requiredGrade = recipe.requiredGrade,
                canProduce = canProduce,
            })
        end
    end

    cb(available)
end)

print('[cartel-lab] 🔬 Drug production recipe engine loaded')
print(('[cartel-lab]   Recipes: %d | Events: startProduction / finishProduction'):format(
    (function() local c = 0; for _ in pairs(Config.Cartel.Recipes) do c = c + 1 end; return c end)()
))
