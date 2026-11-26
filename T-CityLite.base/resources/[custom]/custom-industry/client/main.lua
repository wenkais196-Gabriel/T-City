-- client/main.lua — S5 产业 Boss 菜单（qb-management 动态注入）。
--
-- 不新增 NUI：注入一个菜单项，点开后用 qb-menu 的二级列表展示服务端 Snapshot；
-- 所有数字与可卖上限都由服务端算好，本文件只做排版与把玩家动作转成 callback。
--
-- 授权不在这里：菜单项只由 uiState 回调确认「产业已开启」后注入；每个写操作
-- 仍然由服务端 IndustryUi.* 复验成员身份 + Boss（非 Boss 返回 not_boss）。

local QBCore
local function core()
    if QBCore then return QBCore end
    local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(value) == 'table' then QBCore = value return value end
    return nil
end

local MENU_ID = 'industry_panel'
local BLOCK_TEXT = {
    stock = '库存不足',
    org_cap = '本组织配额已用完',
    demand = '全服配额已用完',
    none = '当前不可卖出',
    cap = '工位已满',
    funds = '金库余额不足',
}

local lastSnapshot = nil
-- 只有 uiState 确认产业已开启后才允许注入；qb-management 后启动时也看这个标记，
-- 避免 industry_enable=false 时因为一次资源重启把菜单项塞回去。
local uiEnabled = false

-- 本地千分位格式化。别用 qb-core 的全局 `Money()` —— 它只在 import 过
-- @qb-core/shared/main.lua 的资源里存在，本资源 client 没 import，调用会直接
-- SCRIPT ERROR: attempt to call a nil value (global 'Money')，整个面板渲染中断。
-- 实现按「从右往左每 3 位插逗号」写：正则在左侧贪心匹配会在长数字上重复插入逗号
-- （"1234,567" → "1234,,567" → 死循环），别再用那种写法。
local function money(value)
    local n = math.floor(tonumber(value) or 0)
    local sign = n < 0 and '-' or ''
    local digits = tostring(math.abs(n))
    local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return sign .. grouped
end

local function notify(message, kind)
    local qb = core()
    local ok = qb and pcall(function() qb.Functions.Notify(message, kind) end)
    if not ok then
        print(('[custom-industry] %s'):format(tostring(message)))
    end
end

local function errorText(errorCode)
    return ('操作失败：%s'):format(tostring(errorCode or 'unknown'))
end

local function openMenu(items)
    local ok = pcall(function() exports['qb-menu']:openMenu(items) end)
    if not ok then notify('菜单不可用（qb-menu 未启动）', 'error') end
end

local function render(snapshot)
    lastSnapshot = snapshot

    local menu = {}
    if snapshot.facility then
        menu[#menu + 1] = {
            header = ('%s · L%d · %s'):format(
                snapshot.orgLabel, snapshot.facility.level, snapshot.gradeName),
            isMenuHeader = true,
            icon = 'fa-solid fa-industry',
        }
    else
        menu[#menu + 1] = {
            header = snapshot.orgLabel,
            isMenuHeader = true,
            icon = 'fa-solid fa-industry',
        }
    end

    if not snapshot.facility then
        -- 未建厂：只显示这一行，不给建造入口（/orgbuild 仍是控制台路径）。
        menu[#menu + 1] = {
            header = '尚未建设施',
            txt = '建造入口仍由 /orgbuild（控制台）负责',
            icon = 'fa-solid fa-hammer',
            disabled = true,
        }
    else
        local facility = snapshot.facility
        local demand = snapshot.demand
        local sellable = snapshot.sellable

        menu[#menu + 1] = {
            header = '金库余额',
            txt = ('$%s'):format(money(snapshot.balance)),
            icon = 'fa-solid fa-vault',
            disabled = true,
        }
        menu[#menu + 1] = {
            header = '设施',
            txt = ('%s L%d · 工位 %d/%d'):format(
                facility.label, facility.level, facility.workstations, facility.workstationCap),
            icon = 'fa-solid fa-building',
            disabled = true,
        }
        menu[#menu + 1] = {
            header = '库存',
            txt = ('%d / %d'):format(facility.stock, facility.stockCap),
            icon = 'fa-solid fa-boxes-stacked',
            disabled = true,
        }
        menu[#menu + 1] = {
            header = '配额',
            txt = ('全服剩 %d / %d · 本组织剩 %d / %d'):format(
                demand.globalRemaining, demand.globalTotal,
                demand.orgRemaining, demand.orgCap),
            icon = 'fa-solid fa-chart-pie',
            disabled = true,
        }
        menu[#menu + 1] = {
            header = '单位售价',
            txt = ('$%s'):format(money(demand.unitPrice)),
            icon = 'fa-solid fa-tag',
            disabled = true,
        }
        menu[#menu + 1] = {
            header = '累计产出',
            txt = tostring(snapshot.producedUnits),
            icon = 'fa-solid fa-gears',
            disabled = true,
        }

        -- 非 Boss 只看到数字：下面三个写操作入口一个都不出现。
        if snapshot.isBoss then
            if facility.hireBlocked then
                menu[#menu + 1] = {
                    header = ('雇工位（$%s）'):format(money(facility.nextWorkstationCost)),
                    txt = BLOCK_TEXT[facility.hireBlocked] or '当前不可雇佣',
                    icon = 'fa-solid fa-user-plus',
                    disabled = true, params = { event = 'industry:client:hire' },
                }
            else
                menu[#menu + 1] = {
                    header = ('雇工位（$%s）'):format(money(facility.nextWorkstationCost)),
                    txt = ('第 %d 个工位'):format(facility.workstations + 1),
                    icon = 'fa-solid fa-user-plus',
                    params = { event = 'industry:client:hire' },
                }
            end

            if sellable.maxQty > 0 then
                menu[#menu + 1] = {
                    header = ('卖出…（最多 %d 件）'):format(sellable.maxQty),
                    txt = ('单价 $%s'):format(money(demand.unitPrice)),
                    icon = 'fa-solid fa-hand-holding-dollar',
                    params = { event = 'industry:client:sell' },
                }
            else
                menu[#menu + 1] = {
                    header = '卖出…（最多 0 件）',
                    txt = BLOCK_TEXT[sellable.blocked] or '当前不可卖出',
                    icon = 'fa-solid fa-hand-holding-dollar',
                    disabled = true, params = { event = 'industry:client:sell' },
                }
            end
        end
    end

    menu[#menu + 1] = {
        header = '返回',
        icon = 'fa-solid fa-angle-left',
        params = { event = 'qb-orgmenu:client:OpenMenu' },
    }

    openMenu(menu)
end

local function refresh()
    local qb = core()
    if not qb then return end
    qb.Functions.TriggerCallback('industry:server:snapshot', function(response)
        if not response or response.ok ~= true then
            notify(errorText(response and response.error or 'snapshot_failed'), 'error')
            return
        end
        render(response.data)
    end)
end

--- 清掉上一次运行留下的菜单项（例如同一个客户端里 industry_enable 被改回 false）。
local function removeMenu()
    pcall(function() exports['qb-management']:RemoveBossMenuItem(MENU_ID) end)
    pcall(function() exports['qb-management']:RemoveGangMenuItem(MENU_ID) end)
end

--- 注入 / 重注入两个 Boss 菜单（职业菜单与帮派菜单各自一份动态表）。
local function injectMenu()
    if not uiEnabled then return end
    local item = {
        header = '产业',
        txt = '查看与经营产业',
        icon = 'fa-solid fa-industry',
        params = { event = 'industry:client:open' },
    }
    local bossOk = pcall(function()
        exports['qb-management']:AddBossMenuItem(item, MENU_ID)
    end)
    local gangOk = pcall(function()
        exports['qb-management']:AddGangMenuItem(item, MENU_ID)
    end)
    if not bossOk and not gangOk then
        print('[custom-industry] boss menu injection skipped: qb-management unavailable')
    end
end

-- 产业面板直开入口：/industry。
-- 为什么不走 /orgmenu：qb-management 的提示循环里有一条
-- 「shownMenu 为真但玩家不在 1.5m 内 → CloseMenuFull()」，它会把任何用 qb-menu
-- 打开的界面一起关掉（我们撤掉临时坐标点后就恒不在范围内，菜单开几秒自己关）。
-- 直接渲染产业面板不会置 shownMenu，那个循环就不会来收；组织菜单里的「产业」项仍然保留。
RegisterCommand('industry', function()
    -- 关闸时不打服务端：uiState 回答 enabled=false 之后 uiEnabled 一直是 false，
    -- 再调 snapshot 会撞 qb-core 的「回调不存在」错误。
    if not uiEnabled then notify('产业功能未开启', 'error') return end
    refresh()
end, false)

-- 组织菜单入口：/orgmenu。
-- 为什么需要它：qb-management 里 qb-bossmenu（cl_boss.lua）与 qb-orgmenu（cl_org.lua）
-- 都会遍历 Config.BossMenus 在**同一坐标**注册交互，玩家按 E 会随机进其中一个；
-- 而「产业」项只能注入组织菜单（qb-menu 那套）。给组织菜单一个确定入口，避免和二选一赌博。
-- 授权仍在服务端：不在组织里就没有 org，直接拒绝。
RegisterCommand('orgmenu', function()
    if not uiEnabled then notify('产业功能未开启', 'error') return end
    local qb = core()
    if not qb then return end
    local ok = pcall(function()
        qb.Functions.TriggerCallback('industry:server:canOpenOrgMenu', function(state)
            if state and state.ok == true then
                TriggerEvent('qb-orgmenu:client:OpenMenu')
            else
                notify('你不在任何组织里，无法打开组织菜单', 'error')
            end
        end)
    end)
    if not ok then notify('组织菜单不可用（qb-management 未启动）', 'error') end
end, false)

RegisterNetEvent('industry:client:open', function()
    refresh()
end)

RegisterNetEvent('industry:client:hire', function()
    local qb = core()
    if not qb then return end
    qb.Functions.TriggerCallback('industry:server:hire', function(response)
        if response and response.ok == true then
            local data = response.data or {}
            notify(('已雇佣工位（$%s），当前 %d 个'):format(
                money(data.cost or 0), tonumber(data.workstations) or 0), 'success')
            refresh()
        else
            notify(errorText(response and response.error), 'error')
        end
    end)
end)

--- 卖出分两步：先 EstimateSale（只读报价/截断原因），确认后才发 Action。
RegisterNetEvent('industry:client:sell', function()
    local qb = core()
    if not qb then return end

    local snapshot = lastSnapshot
    if not snapshot or not snapshot.facility or not snapshot.sellable then
        notify('请先打开产业面板', 'error')
        return
    end

    local maxQty = tonumber(snapshot.sellable.maxQty) or 0
    if maxQty <= 0 then
        notify(BLOCK_TEXT[snapshot.sellable.blocked] or '当前不可卖出', 'error')
        return
    end

    local dialog
    local ok = pcall(function()
        dialog = exports['qb-input']:ShowInput({
            header = ('卖出 %s'):format(snapshot.demand.item),
            submitText = '报价',
            inputs = {
                {
                    type = 'number',
                    isRequired = true,
                    name = 'qty',
                    text = ('数量（1–%d）'):format(maxQty),
                    default = '1',
                },
            },
        })
    end)
    if not ok or not dialog or not dialog.qty then return end

    local qty = tonumber(dialog.qty)
    if not qty then return end

    qb.Functions.TriggerCallback('industry:server:estimate', function(response)
        if not response or response.ok ~= true then
            notify(errorText(response and response.error or 'estimate_failed'), 'error')
            return
        end

        local estimate = response.data or {}
        if estimate.ok ~= true then
            notify(BLOCK_TEXT[estimate.blocked] or '当前不可卖出', 'error')
            return
        end

        local detail = ('%d 件 × $%s = $%s'):format(
            estimate.qty, money(estimate.unitPrice), money(estimate.revenue))
        if estimate.blocked then
            detail = detail .. ('（受%s限制）'):format(BLOCK_TEXT[estimate.blocked] or '上限')
        end

        openMenu({
            {
                header = '确认卖出',
                txt = detail,
                isMenuHeader = true,
                icon = 'fa-solid fa-circle-check',
            },
            {
                header = ('确认卖出 %d 件'):format(estimate.qty),
                txt = ('预计入账 $%s'):format(money(estimate.revenue)),
                icon = 'fa-solid fa-check',
                params = {
                    event = 'industry:client:confirmSell',
                    args = { qty = estimate.qty },
                },
            },
            {
                header = '取消',
                icon = 'fa-solid fa-xmark',
                params = { event = 'industry:client:open' },
            },
        })
    end, qty)
end)

RegisterNetEvent('industry:client:confirmSell', function(data)
    local qb = core()
    if not qb then return end
    local qty = tonumber(type(data) == 'table' and data.qty or data)
    if not qty then return end

    qb.Functions.TriggerCallback('industry:server:sell', function(response)
        if response and response.ok == true then
            local result = response.data or {}
            notify(('已卖出 %d 件，入账 $%s'):format(
                tonumber(result.qty) or qty, money(result.revenue or 0)), 'success')
            refresh()
        else
            notify(errorText(response and response.error), 'error')
        end
    end, qty)
end)

-- qb-management 后启动 / 重启时补注入；重复调用按 MENU_ID 覆盖，不会出现两个「产业」。
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'qb-management' then injectMenu() end
end)

-- industry_enable=false 时服务端不注册 uiState，回调不会回来，也就不注入菜单。
removeMenu()
local qb = core()
-- 同上：TriggerCallback 也是可调用表，`type(...) == 'function'` 恒假 ——
-- 这条曾经让 uiEnabled 永远 false，注入被自己挡掉（真机：菜单里看不到「产业」）。
if qb then
    local ok = pcall(function() qb.Functions.TriggerCallback('industry:server:uiState', function(state)
        if state and state.ok == true and state.enabled == true then
            uiEnabled = true
            injectMenu()
        end
    end) end)
    if not ok then print('[custom-industry] uiState bootstrap failed') end
end
