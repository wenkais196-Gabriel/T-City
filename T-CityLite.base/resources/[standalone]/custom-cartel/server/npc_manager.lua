-- npc_manager.lua — Cartel 农场 NPC 管理
--
-- 管理 Madrazo Ranch 内的 3 个 NPC:
--   1. 化学供应商 (s_m_m_chemsec_01) — 出售化学原料
--   2. 毒品分销商 (g_m_m_chicold_01) — 收购成品毒品
--   3. 任务发布人 (g_m_m_mexboss_01) — 发布 cartel 任务
--
-- 客户端负责 ped 生成 + qb-target 交互
-- 服务端负责交易逻辑 + 权限校验

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 回调: 获取 NPC 列表 (供客户端生成 ped)
-- ==============================================================

QBCore.Functions.CreateCallback('cartel:server:getNPCs', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({}); return end

    local isMember, _ = CartelService.IsMember(source)
    local npcs = {}

    for _, npcCfg in ipairs(Config.Cartel.NPCs) do
        table.insert(npcs, {
            id = npcCfg.id,
            model = npcCfg.model,
            coords = npcCfg.coords,
            label = npcCfg.label,
            role = npcCfg.role,
            scenario = npcCfg.scenario,
            accessible = isMember,  -- 非成员显示但不可交互
            items = npcCfg.items,   -- 供应商商品列表
            buyPrices = npcCfg.buyPrices,  -- 分销商收购价
        })
    end

    cb(npcs)
end)

-- ==============================================================
-- 供应商交易: 玩家向 NPC 购买原料
-- ==============================================================

RegisterNetEvent('cartel:server:buyFromSupplier', function(npcId, itemName, quantity)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 成员校验
    local isMember, _ = CartelService.IsMember(src)
    if not isMember then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_supplier_refuse'), 'error')
        return
    end

    -- 2. NPC 校验
    local npcCfg = nil
    for _, cfg in ipairs(Config.Cartel.NPCs) do
        if cfg.id == npcId then npcCfg = cfg; break end
    end
    if not npcCfg or npcCfg.role ~= 'supplier' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_invalid_supplier'), 'error')
        return
    end

    -- 3. 商品校验
    local itemCfg = nil
    for _, item in ipairs(npcCfg.items) do
        if item.name == itemName then itemCfg = item; break end
    end
    if not itemCfg then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_not_sell_item'), 'error')
        return
    end

    -- 4. 数量清洗
    quantity = tonumber(quantity) or 1
    if quantity < 1 then quantity = 1 end
    if quantity > 100 then quantity = 100 end

    -- 5. 库存检查
    if itemCfg.stock < quantity then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_supplier_no_stock'), 'error')
        return
    end

    -- 6. 计算价格 (走动态市场价或固定价)
    local unitPrice = itemCfg.price
    if Bus and Bus.MarketService then
        local marketPrice = Bus.MarketService.GetPrice(itemName)
        if marketPrice then
            -- 供应商价格 = 市场价 * 0.8 (8折进货)
            unitPrice = math.floor(marketPrice * 0.8 + 0.5)
        end
    end

    local totalCost = unitPrice * quantity

    -- 7. 扣款
    if Player.PlayerData.money.bank < totalCost and Player.PlayerData.money.cash < totalCost then
        TriggerClientEvent('QBCore:Notify', src,
            ('资金不足，需要 $%d (市场价 $%d/个)'):format(totalCost, unitPrice), 'error')
        return
    end

    -- 优先扣 bank
    if Player.PlayerData.money.bank >= totalCost then
        Player.Functions.RemoveMoney('bank', totalCost, 'CartelSupplier:' .. itemName)
    else
        Player.Functions.RemoveMoney('cash', totalCost, 'CartelSupplier:' .. itemName)
    end

    -- 8. 给予物品
    exports['qb-inventory']:AddItem(src, itemName, quantity, nil, nil, 'CartelSupplier')

    -- 9. 扣库存
    itemCfg.stock = itemCfg.stock - quantity

    -- 10. 通知
    TriggerClientEvent('QBCore:Notify', src,
        ('购买了 %d x %s @ $%d/个 (总计 $%d)'):format(quantity, itemCfg.label or itemName, unitPrice, totalCost),
        'success')

    -- 审计日志
    if totalCost > 10000 and exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('Cartel采购',
            ('**%s** | 购买 %d x %s | $%d'):format(GetPlayerName(src), quantity, itemName, totalCost), 65280)
    end
end)

-- ==============================================================
-- 分销商交易: 玩家向 NPC 出售成品毒品
-- ==============================================================

RegisterNetEvent('cartel:server:sellToDealer', function(npcId, itemName, quantity)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 成员校验
    local isMember, _ = CartelService.IsMember(src)
    if not isMember then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_distributor_refuse'), 'error')
        return
    end

    -- 2. NPC 校验
    local npcCfg = nil
    for _, cfg in ipairs(Config.Cartel.NPCs) do
        if cfg.id == npcId then npcCfg = cfg; break end
    end
    if not npcCfg or npcCfg.role ~= 'dealer' then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_invalid_distributor'), 'error')
        return
    end

    -- 3. 收购价校验
    local unitPrice = npcCfg.buyPrices[itemName]
    if not unitPrice then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_not_buy_item'), 'error')
        return
    end

    -- 4. 数量清洗
    quantity = tonumber(quantity) or 1
    if quantity < 1 then quantity = 1 end
    if quantity > 50 then quantity = 50 end

    -- 5. 物品校验
    local hasItem = QBCore.Functions.HasItem(src, itemName, quantity)
    if not hasItem then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'cartel_not_enough_item', itemName), 'error')
        return
    end

    -- 6. 使用动态市场价 (如果有)
    local finalPrice = unitPrice
    if Bus and Bus.MarketService then
        local marketPrice = Bus.MarketService.GetPrice(itemName)
        if marketPrice then
            -- 分销商收购价 = 市场价 * 0.85
            finalPrice = math.floor(marketPrice * 0.85 + 0.5)
        end
    end

    local totalRevenue = finalPrice * quantity

    -- 7. 移除物品
    exports['qb-inventory']:RemoveItem(src, itemName, quantity, nil, 'CartelDealer')

    -- 8. 付款 (走统一经济出口)
    if Bus and Bus.EconomyService then
        Bus.EconomyService.AddScaled(src, 'bank', totalRevenue, 'CartelDealer:' .. itemName)
    else
        Player.Functions.AddMoney('bank', totalRevenue, 'CartelDealer:' .. itemName)
    end

    -- 9. 更新市场供给 (如果 MarketService 可用)
    if Bus and Bus.MarketService then
        -- MarketService.Sell 会增加 supply，但我们直接卖给了 NPC
        -- 这里手动触发市场调整：分销商出货 → 市场供给增加
        -- 用 Sell 间接影响市场价格
        Bus.MarketService.Sell(src, itemName, math.floor(quantity * 0.5))
    end

    -- 10. 通知
    TriggerClientEvent('QBCore:Notify', src,
        ('出售了 %d x %s @ $%d/个 (总计 $%d)'):format(quantity, itemName, finalPrice, totalRevenue),
        'success')

    -- 审计日志
    if totalRevenue > 50000 and exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('Cartel分销',
            ('**%s** | 出售 %d x %s | $%d'):format(GetPlayerName(src), quantity, itemName, totalRevenue), 16744576)
    end
end)

-- ==============================================================
-- 任务发布人: 获取可用任务列表
-- ==============================================================

QBCore.Functions.CreateCallback('cartel:server:getAvailableQuests', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({}); return end

    local isMember, _ = CartelService.IsMember(source)
    if not isMember then cb({}); return end

    -- 查询 custom-quest 系统获取 cartel 类别任务
    -- 这里返回静态列表，实际任务由 custom-quest 管理
    local quests = {
        {
            id = 'cartel_initiation',
            label = 'Cartel 入会考验',
            description = '完成运输任务证明你的忠诚',
            category = 'cartel',
        },
        {
            id = 'cartel_drug_run',
            label = '毒品运输',
            description = '将货物安全送达目的地',
            category = 'cartel',
        },
    }

    cb(quests)
end)

-- ==============================================================
-- 距离校验回调 (供客户端 target 交互使用)
-- ==============================================================

QBCore.Functions.CreateCallback('cartel:server:validateNPCDistance', function(source, cb, npcId)
    -- 客户端已做了本地距离校验，服务端再双重验证
    -- 简化处理：只要成员身份合法即可
    local isMember, _ = CartelService.IsMember(source)
    cb(isMember)
end)

print('[cartel-npc] 👥 NPC 管理器已加载')
print(('[cartel-npc]   供应商: 化学品/原料 | 分销商: 收购毒品 | 任务发布人: cartel 任务'))
