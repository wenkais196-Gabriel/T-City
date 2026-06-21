-- client/main.lua — Cartel 客户端交互
--
-- 职责:
--   1. 生成农场 NPC ped
--   2. qb-target 交互 (供应商/分销商/任务发布人)
--   3. 实验室加工台 UI (qb-menu + progressbar)
--   4. 进度条/小游戏回调

local QBCore = exports['qb-core']:GetCoreObject()
local spawnedNPCs = {}
local isInLab = false

-- Bilingual label resolver — returns the right language for { en, zh } tables
local function L(val)
    if type(val) == 'table' then
        local lang = 'en'
        if _L then lang = _L('_lang') end
        return val[lang] or val.en or '???'
    end
    return val
end

-- ==============================================================
-- NPC Ped 生成
-- ==============================================================

CreateThread(function()
    -- 等待玩家登录
    while not LocalPlayer.state.isLoggedIn do Wait(1000) end

    -- 请求 NPC 数据
    QBCore.Functions.TriggerCallback('cartel:server:getNPCs', function(npcs)
        for _, npcCfg in ipairs(npcs) do
            spawnNPC(npcCfg)
        end
        -- cartel NPC spawn print removed
    end)
end)

function spawnNPC(npcCfg)
    local hash = GetHashKey(npcCfg.model)
    RequestModel(hash)
    local timeout = 0
    while not HasModelLoaded(hash) do
        Wait(10)
        timeout = timeout + 1
        if timeout > 300 then
            print('[cartel] ❌ NPC模型加载失败: ' .. npcCfg.model)
            return
        end
    end

    local ped = CreatePed(0, hash, npcCfg.coords.x, npcCfg.coords.y, npcCfg.coords.z - 1.0,
        npcCfg.coords.w, false, true)
    if DoesEntityExist(ped) then
        FreezeEntityPosition(ped, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)

        -- 设置 scenario (动画)
        if npcCfg.scenario then
            TaskStartScenarioInPlace(ped, npcCfg.scenario, 0, true)
        end

        spawnedNPCs[npcCfg.id] = { ped = ped, config = npcCfg }

        -- qb-target 交互
        setupNPCTarget(ped, npcCfg)
    end
end

-- ==============================================================
-- qb-target 交互设置
-- ==============================================================

function setupNPCTarget(ped, npcCfg)
    local options = {}

    if npcCfg.role == 'supplier' then
        -- 化学供应商
        options = {
            {
                type = 'client',
                event = 'cartel:client:openSupplierMenu',
                icon = 'fas fa-flask',
                label = 'Buy Chemical Materials',
                npcId = npcCfg.id,
                items = npcCfg.items,
            },
        }
    elseif npcCfg.role == 'dealer' then
        -- 毒品分销商
        options = {
            {
                type = 'client',
                event = 'cartel:client:openDealerMenu',
                icon = 'fas fa-money-bill-wave',
                label = 'Sell Drugs',
                npcId = npcCfg.id,
                buyPrices = npcCfg.buyPrices,
            },
        }
    elseif npcCfg.role == 'quest_giver' then
        -- 任务发布人
        options = {
            {
                type = 'client',
                event = 'cartel:client:openQuestMenu',
                icon = 'fas fa-scroll',
                label = 'Cartel Missions',
                npcId = npcCfg.id,
            },
        }
    end

    if #options > 0 then
        exports['qb-target']:AddTargetEntity(ped, {
            options = options,
            distance = 2.5,
        })
    end
end

-- ==============================================================
-- 供应商购买菜单
-- ==============================================================

RegisterNetEvent('cartel:client:openSupplierMenu', function(data)
    local npcId = data.npcId
    local items = data.items

    local menuItems = {}
    for _, item in ipairs(items) do
        table.insert(menuItems, {
            header = ('%s — $%d/pc (Stock: %d)'):format(L(item.label) or item.name, item.price, item.stock),
            txt = ('Buy %s'):format(L(item.label) or item.name),
            params = {
                event = 'cartel:client:buyItem',
                args = {
                    npcId = npcId,
                    itemName = item.name,
                    itemLabel = item.label or item.name,
                    price = item.price,
                }
            }
        })
    end

    if #menuItems == 0 then
        QBCore.Functions.Notify(_L('cartel_supplier_empty'), 'error')
        return
    end

    table.insert(menuItems, {
        header = 'Close',
        params = { event = 'qb-menu:closeMenu' }
    })

    exports['qb-menu']:openMenu(menuItems)
end)

RegisterNetEvent('cartel:client:buyItem', function(data)
    local dialog = exports['qb-input']:ShowInput({
        header = ('Buy %s ($%d/pc)'):format(data.itemLabel, data.price),
        submitText = 'Confirm Purchase',
        inputs = {
            {
                type = 'number',
                isRequired = true,
                name = 'quantity',
                text = 'Quantity',
                default = '1',
            }
        }
    })

    if dialog and dialog.quantity then
        local qty = tonumber(dialog.quantity)
        if qty and qty > 0 then
            TriggerServerEvent('cartel:server:buyFromSupplier', data.npcId, data.itemName, qty)
        end
    end
end)

-- ==============================================================
-- 分销商出售菜单
-- ==============================================================

RegisterNetEvent('cartel:client:openDealerMenu', function(data)
    local npcId = data.npcId
    local buyPrices = data.buyPrices

    local menuItems = {}
    for itemName, price in pairs(buyPrices) do
        table.insert(menuItems, {
            header = ('%s — $%d/pc'):format(itemName, price),
            txt = ('Sell %s'):format(itemName),
            params = {
                event = 'cartel:client:sellItem',
                args = {
                    npcId = npcId,
                    itemName = itemName,
                    price = price,
                }
            }
        })
    end

    table.insert(menuItems, {
        header = 'Close',
        params = { event = 'qb-menu:closeMenu' }
    })

    exports['qb-menu']:openMenu(menuItems)
end)

RegisterNetEvent('cartel:client:sellItem', function(data)
    local dialog = exports['qb-input']:ShowInput({
        header = ('Sell %s ($%d/pc)'):format(data.itemName, data.price),
        submitText = 'Confirm Sale',
        inputs = {
            {
                type = 'number',
                isRequired = true,
                name = 'quantity',
                text = 'Quantity',
                default = '1',
            }
        }
    })

    if dialog and dialog.quantity then
        local qty = tonumber(dialog.quantity)
        if qty and qty > 0 then
            TriggerServerEvent('cartel:server:sellToDealer', data.npcId, data.itemName, qty)
        end
    end
end)

-- ==============================================================
-- 任务发布人菜单
-- ==============================================================

RegisterNetEvent('cartel:client:openQuestMenu', function(data)
    QBCore.Functions.TriggerCallback('cartel:server:getAvailableQuests', function(quests)
        local menuItems = {}

        for _, quest in ipairs(quests) do
            table.insert(menuItems, {
                header = quest.label,
                txt = quest.description,
                params = {
                    event = 'quest:client:acceptQuest',
                    args = { questId = quest.id }
                }
            })
        end

        if #menuItems == 0 then
            QBCore.Functions.Notify(_L('cartel_no_quests'), 'primary')
            return
        end

        table.insert(menuItems, {
            header = 'Close',
            params = { event = 'qb-menu:closeMenu' }
        })

        exports['qb-menu']:openMenu(menuItems)
    end)
end)

-- ==============================================================
-- Laboratory Workbench
-- ==============================================================

RegisterNetEvent('cartel:client:openLab', function()
    -- 先检查距离
    local playerCoords = GetEntityCoords(PlayerPedId())
    local labCoords = Config.Cartel.LabLocation.coords
    local dist = #(playerCoords - labCoords)

    if dist > Config.Cartel.LabLocation.radius + 5.0 then
        QBCore.Functions.Notify(_L('cartel_too_far_lab'), 'error')
        return
    end

    QBCore.Functions.TriggerCallback('cartel:server:getRecipes', function(recipes)
        if #recipes == 0 then
            QBCore.Functions.Notify(_L('cartel_no_recipe'), 'error')
            return
        end

        local menuItems = {}
        for _, recipe in ipairs(recipes) do
            local cooldownText = recipe.canProduce and '✅ Available' or '⏳ Cooling Down'
            table.insert(menuItems, {
                header = ('%s [%s]'):format(L(recipe.label), cooldownText),
                txt = ('%s | %ds | Failure: %d%%'):format(
                    L(recipe.description), recipe.duration, math.floor(recipe.failRate * 100)),
                disabled = not recipe.canProduce,
                params = {
                    event = 'cartel:client:startProduction',
                    args = { recipeId = recipe.id, recipe = recipe }
                }
            })
        end

        table.insert(menuItems, {
            header = 'Close',
            params = { event = 'qb-menu:closeMenu' }
        })

        exports['qb-menu']:openMenu(menuItems)
    end)
end)

-- ==============================================================
-- Production Flow
-- ==============================================================

RegisterNetEvent('cartel:client:startProduction', function(data)
    -- 关闭菜单
    exports['qb-menu']:closeMenu()

    -- 通知服务端校验并开始
    TriggerServerEvent('cartel:server:startProduction', data.recipeId)
end)

-- 服务端确认后，开始客户端进度条
RegisterNetEvent('cartel:client:productionStarted', function(data)
    QBCore.Functions.Notify(_L('cartel_production_start', data.label), 'primary')

    -- 根据配方使用不同的交互方式
    if data.minigame == 'safecracker' then
        -- 使用 safecracker 小游戏
        local success = exports['safecracker']:StartSafeCracker()
        if success then
            TriggerServerEvent('cartel:server:finishProduction', data.recipeId)
        else
            QBCore.Functions.Notify(_L('cartel_production_fail'), 'error')
        end
    else
        -- 使用 progressbar
        QBCore.Functions.Progressbar('cartel_production', ('Producing: %s'):format(L(data.label)),
            data.duration * 1000, false, true, {
                disableMovement = true,
                disableCarMovement = true,
                disableMouse = false,
                disableCombat = true,
            }, {}, {}, {}, function()
                -- 完成 → 通知服务端
                TriggerServerEvent('cartel:server:finishProduction', data.recipeId)
            end, function()
                -- 取消 → 不通知服务端，原料不消耗
                QBCore.Functions.Notify(_L('cartel_production_cancel'), 'error')
            end)
    end
end)

-- ==============================================================
-- 警察 Raid 警报
-- ==============================================================

RegisterNetEvent('police:client:cartelRaidAlert', function(data)
    -- 只有警察收到此事件
    local Player = QBCore.Functions.GetPlayerData()
    if not Player or Player.job.name ~= 'police' then return end

    -- 地图标记
    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, 499)     -- 化学图标
    SetBlipColour(blip, 1)       -- 红色
    SetBlipScale(blip, 1.2)
    SetBlipFlashes(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(_L('cartel_blip'))
    EndTextCommandSetBlipName(blip)

    QBCore.Functions.Notify(data.message, 'error', 10000)

    -- 30秒后移除标记
    SetTimeout(30000, function()
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end)
end)

-- ==============================================================
-- 资源停止时清理
-- ==============================================================

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        for _, npcData in pairs(spawnedNPCs) do
            if DoesEntityExist(npcData.ped) then
                DeleteEntity(npcData.ped)
            end
        end
        spawnedNPCs = {}
    end
end)

-- cartel-client startup print removed (production mode)
