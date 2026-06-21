-- client/main.lua — 矿业系统客户端
--
-- 职责:
--   1. 矿点 qb-target 交互
--   2. progressbar 采集动画
--   3. 冶炼厂 qb-target + qb-menu
--   4. 通知反馈

local QBCore = exports['qb-core']:GetCoreObject()

-- _L i18n 安全兜底: 防止 production-freeze 加载时序问题导致 _L 为 nil
if _L == nil then
    _L = function(key, ...)
        if not key then return '' end
        if select('#', ...) > 0 then
            return ('[%s]'):format(tostring(key))
        end
        return '[' .. tostring(key) .. ']'
    end
end

-- ==============================================================
-- 矿点 Blip + Target 生成
-- ==============================================================
CreateThread(function()
    while not LocalPlayer.state.isLoggedIn do Wait(1000) end

    for _, site in ipairs(Config.Mining.Sites) do
        if site.blip then
            local blip = AddBlipForCoord(site.coords.x, site.coords.y, site.coords.z)
            SetBlipSprite(blip, site.blip.sprite)
            SetBlipColour(blip, site.blip.color)
            SetBlipScale(blip, site.blip.scale)
            SetBlipAsShortRange(blip, true)
            SetBlipCategory(blip, 135)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString(_L('blip_' .. site.id))
            EndTextCommandSetBlipName(blip)
        end

        -- qb-target 区域
        exports['qb-target']:AddCircleZone('mining_' .. site.id, site.coords, site.radius, {
            name = 'mining_' .. site.id,
            debugPoly = false,
        }, {
            options = {
                {
                    type = 'client',
                    event = 'mining:client:startMining',
                    icon = 'fas fa-gem',
                    label = ('在 %s 采矿'):format(site.label),
                    siteId = site.id,
                },
            },
            distance = site.radius,
        })
    end

    -- 冶炼厂 Blip + Target
    local smelter = Config.Mining.SmelterLocation
    if smelter.blip then
        local blip = AddBlipForCoord(smelter.coords.x, smelter.coords.y, smelter.coords.z)
        SetBlipSprite(blip, smelter.blip.sprite)
        SetBlipColour(blip, smelter.blip.color)
        SetBlipScale(blip, smelter.blip.scale)
        SetBlipAsShortRange(blip, true)
        SetBlipCategory(blip, 135)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(_L('blip_smelter'))
        EndTextCommandSetBlipName(blip)
    end

    exports['qb-target']:AddCircleZone('mining_smelter', smelter.coords, smelter.radius, {
        name = 'mining_smelter',
        debugPoly = false,
    }, {
        options = {
            {
                type = 'client',
                event = 'mining:client:openSmelter',
                icon = 'fas fa-fire',
                label = '冶炼矿石',
            },
        },
        distance = smelter.radius,
    })

    -- mining target zones ready
end)

-- ==============================================================
-- 采矿交互
-- ==============================================================
RegisterNetEvent('mining:client:startMining', function(data)
    local siteId = data.siteId
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)

    -- 找矿点
    local site = nil
    for _, s in ipairs(Config.Mining.Sites) do
        if s.id == siteId then site = s; break end
    end
    if not site then return end

    -- 距离校验
    if #(playerCoords - site.coords) > site.radius + 5 then
        QBCore.Functions.Notify('你离矿点太远了', 'error')
        return
    end

    -- 开始循环采集 (每次 progressbar 完成触发一次服务端采集)
    QBCore.Functions.Notify(('开始采矿: %s'):format(site.label), 'primary')

    CreateThread(function()
        local mining = true
        while mining do
            local dist = #(GetEntityCoords(PlayerPedId()) - site.coords)
            if dist > site.radius then
                QBCore.Functions.Notify('你离开了矿点区域', 'error')
                mining = false
                break
            end

            -- progressbar
            local cancelled = false
            QBCore.Functions.Progressbar('mining_action', '采矿中...', 5000, false, true, {
                disableMovement = true,
                disableCarMovement = true,
                disableMouse = false,
                disableCombat = true,
            }, {
                animDict = 'melee@hatchet@streamed_core',
                anim = 'plyr_rear_takedown_b',
                flags = 1,
            }, {}, {}, function()
                -- 完成 → 发送采集事件
                TriggerServerEvent('mining:server:mineOre', siteId)
            end, function()
                cancelled = true
            end)

            if cancelled then
                mining = false
                QBCore.Functions.Notify('采矿已停止', 'primary')
                break
            end

            Wait(500)
        end
    end)
end)

-- 采集结果通知
RegisterNetEvent('mining:client:oreMined', function(data)
    if data.isDouble then
        QBCore.Functions.Notify(
            ('🎉 双倍收获！获得 %d x %s%s'):format(data.yield, data.oreLabel,
                data.storedInOrg and ' → 组织仓库' or ''),
            'success')
    else
        QBCore.Functions.Notify(
            ('⛏️ 获得 %s%s'):format(data.oreLabel,
                data.storedInOrg and ' → 组织仓库' or ''),
            'primary')
    end
end)

-- ==============================================================
-- 冶炼交互
-- ==============================================================
RegisterNetEvent('mining:client:openSmelter', function()
    local smelter = Config.Mining.SmelterLocation
    local dist = #(GetEntityCoords(PlayerPedId()) - smelter.coords)
    if dist > smelter.radius + 3 then
        QBCore.Functions.Notify('你离冶炼厂太远了', 'error')
        return
    end

    QBCore.Functions.TriggerCallback('mining:server:getSmeltRecipes', function(recipes)
        if #recipes == 0 then
            QBCore.Functions.Notify('没有可用的冶炼配方', 'error')
            return
        end

        local menuItems = {}
        for _, r in ipairs(recipes) do
            local inputDesc = {}
            for _, inp in ipairs(r.inputs) do
                inputDesc[#inputDesc + 1] = ('%dx%s'):format(inp.count, inp.label)
            end
            table.insert(menuItems, {
                header = ('冶炼 %s'):format(r.label),
                txt = ('原料: %s | 耗时 %ds | 失败率 %d%%'):format(
                    table.concat(inputDesc, ' + '), r.duration,
                    math.floor(r.failRate * 100)),
                params = {
                    event = 'mining:client:doSmelt',
                    args = { recipeId = r.id, recipe = r }
                }
            })
        end
        table.insert(menuItems, { header = '关闭', params = { event = 'qb-menu:closeMenu' } })
        exports['qb-menu']:openMenu(menuItems)
    end)
end)

RegisterNetEvent('mining:client:doSmelt', function(data)
    exports['qb-menu']:closeMenu()

    QBCore.Functions.Progressbar('mining_smelt', ('冶炼中: %s'):format(data.recipe.label),
        data.recipe.duration * 1000, false, true, {
            disableMovement = true,
            disableCarMovement = true,
            disableMouse = false,
            disableCombat = true,
        }, {}, {}, {}, function()
            TriggerServerEvent('mining:server:smeltOre', data.recipeId)
        end, function()
            QBCore.Functions.Notify('冶炼已取消', 'error')
        end)
end)

-- mining-client startup print removed (production mode)
