-- client/main.lua — 矿业系统客户端
--
-- 职责:
--   1. 矿点 qb-target 交互
--   2. progressbar 采集动画
--   3. 冶炼厂 qb-target + qb-menu
--   4. 通知反馈

local QBCore = exports['qb-core']:GetCoreObject()

--- C-7：倒地/死亡判定。四键都查：服务端写 isdead/inlaststand，客户端写 isDead/inLaststand。
--- 注意：**必须**声明在第一个使用点（采矿循环 `:101`）之前 —— 上一版把它放在 215 行，
--- 真机直接 SCRIPT ERROR：attempt to call a nil value (global 'IsDowned')。
local function IsDowned()
    local st = LocalPlayer.state
    return st.isDead == true or st.inLaststand == true
        or st.isdead == true or st.inlaststand == true
end

--- 采矿反馈（C-5）：统一走 custom-notify 的**客户端本地出口**。
--- 原来这里直接 exports:Push —— 那是服务端接口，客户端根本没有，pcall 一包就静默丢了。
local function feedback(text, kind)
    local pushKind = (kind == 'error') and 'error' or 'feed'
    pcall(function() exports['custom-notify']:PushLocal(pushKind, text) end)
end


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

        -- C-4：采矿点交互改成 [E] 提示，见文件末尾的 InteractionLoop
    end

    -- 冶炼厂 Blip + Target
    local smelter = Config.Mining.SmelterLocation
    if smelter.blip then
        local blip = AddBlipForCoord(smelter.coords.x, smelter.coords.y, smelter.coords.z)
        SetBlipSprite(blip, smelter.blip.sprite)
        SetBlipColour(blip, smelter.blip.color)
        SetBlipScale(blip, smelter.blip.scale)
        -- 2026-11-12 PO：冶炼厂已找到，blip 回滚成近距离可见（原来为排查改成全图可见）
        SetBlipAsShortRange(blip, true)
        SetBlipCategory(blip, 135)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(_L('blip_smelter'))
        EndTextCommandSetBlipName(blip)
    end

    -- C-4：冶炼炉交互改成 [E] 提示（见 InteractionLoop）

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
        feedback('你离矿点太远了', 'error')
        return
    end

    -- 开始循环采集 (每次 progressbar 完成触发一次服务端采集)
    feedback(('开始采矿: %s'):format(site.label), 'primary')

    CreateThread(function()
        local mining = true
        while mining do
            if IsDowned() then
                feedback('你倒下了，采矿中断', 'error')
                mining = false
                break
            end

            local dist = #(GetEntityCoords(PlayerPedId()) - site.coords)
            if dist > site.radius then
                feedback('你离开了矿点区域', 'error')
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
                feedback('采矿已停止', 'primary')
                break
            end

            Wait(500)
        end
    end)
end)

-- 采集结果通知
RegisterNetEvent('mining:client:oreMined', function(data)
    if data.isDouble then
        feedback(
            ('🎉 双倍收获！获得 %d x %s%s'):format(data.yield, data.oreLabel,
                data.storedInOrg and ' → 组织仓库' or ''),
            'success')
    else
        feedback(
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
        feedback('你离冶炼厂太远了', 'error')
        return
    end

    QBCore.Functions.TriggerCallback('mining:server:getSmeltRecipes', function(recipes)
        if #recipes == 0 then
            feedback('没有可用的冶炼配方', 'error')
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
            feedback('冶炼已取消', 'error')
        end)
end)

-- mining-client startup print removed (production mode)

-- ==============================================================
-- C-4：统一 [E] 交互（采矿点 / 冶炼炉）
-- 原来两处都是 qb-target 的圆形区域 —— 一个位置只有一个动作，却要长按 ALT。
-- 现在按距离显示 custom-prompt，按 E 直接触发原来的事件（不改业务逻辑）。
-- ==============================================================
CreateThread(function()
    -- N-6：只 Hide 自己 Show 过的提示。原来 else 分支每轮（800ms）无条件 Hide()，
    -- 会把商店/警察/医护正在显示的提示一起打掉 —— 真机表现就是"[E] 打开商店"每约 0.8 秒闪一下。
    -- 其余资源（qb-shops / qb-storerobbery / qb-ambulancejob / qb-management）都是这个写法。
    local promptShown = false
    local promptLabel = nil
    while true do
        local sleep = 800
        local pos = GetEntityCoords(PlayerPedId())
        local action, label, payload = nil, nil, nil

        for _, site in ipairs(Config.Mining.Sites) do
            if #(pos - site.coords) <= (site.radius or 5.0) then
                action, label, payload = 'mining:client:startMining', ('在 %s 采矿'):format(site.label), { siteId = site.id }
                sleep = 200
                break
            end
        end

        if not action then
            local smelter = Config.Mining.SmelterLocation
            if #(pos - smelter.coords) <= (smelter.radius or 3.0) then
                action, label, payload = 'mining:client:openSmelter', '冶炼矿石', nil
                sleep = 200
            end
        end

        if IsDowned() then action = nil end -- C-7：倒地时不给任何交互提示

        if action then
            sleep = 0 -- N-8：范围内每帧采样 E（松开只在 1 帧为真，轮询会丢按键）
            if label ~= promptLabel then
                exports['custom-prompt']:Show({ key = 'E', label = label })
                promptLabel = label
                promptShown = true
            end
            if IsControlJustReleased(0, 38) then
                exports['custom-prompt']:Hide()
                promptShown = false
                promptLabel = nil
                if payload then
                    TriggerEvent(action, payload)
                else
                    TriggerEvent(action)
                end
                sleep = 800
            end
        elseif promptShown then
            exports['custom-prompt']:Hide()
            promptShown = false
            promptLabel = nil
        end

        Wait(sleep)
    end
end)
