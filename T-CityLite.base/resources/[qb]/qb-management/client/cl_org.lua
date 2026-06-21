-- ==============================================================
-- cl_org.lua — 统一 Boss 管理菜单 UI（职业 + 帮派）
--
-- 自动检测玩家当前组织类型（职业 / 帮派），渲染对应的 Boss 菜单。
-- 新增"退位交接"选项，允许 Boss 指定在线成员为新 Boss。
--
-- 统一五级组织模板：
--   0 = 实习  1 = 正式  2 = 小组长  3 = 副部长  4 = Boss
-- ==============================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- 动态检测：玩家当前是职业 Boss 还是帮派 Boss
local function GetActiveOrg()
    local pData = QBCore.Functions.GetPlayerData()
    if not pData then return nil, nil end

    if pData.job and pData.job.isboss then
        return 'job', pData.job
    elseif pData.gang and pData.gang.isboss then
        return 'gang', pData.gang
    end
    return nil, nil
end

-- 获取组织数据定义（shared Jobs/Gangs）
local function GetOrgDef(orgType, orgName)
    if orgType == 'job' then
        return QBCore.Shared.Jobs[orgName]
    elseif orgType == 'gang' then
        return QBCore.Shared.Gangs[orgName]
    end
    return nil
end

-- 获取对应坐标配置
local function GetMenuConfig(orgType, orgName)
    if orgType == 'job' then
        return Config.BossMenus and Config.BossMenus[orgName]
    elseif orgType == 'gang' then
        return Config.GangMenus and Config.GangMenus[orgName]
    end
    return nil
end

-- ==============================================================
-- 菜单状态
-- ==============================================================

local shownMenu = false
local DynamicMenuItems = {}

local function CloseMenuFull()
    exports['qb-menu']:closeMenu()
    exports['qb-core']:HideText()
    shownMenu = false
end

-- ==============================================================
-- 动态菜单项 API（兼容旧 exports）
-- ==============================================================

local function AddOrgMenuItem(data, id)
    local menuID = id or (#DynamicMenuItems + 1)
    DynamicMenuItems[menuID] = deepcopy(data)
    return menuID
end

local function RemoveOrgMenuItem(id)
    DynamicMenuItems[id] = nil
end

exports('AddBossMenuItem', AddOrgMenuItem)
exports('RemoveBossMenuItem', RemoveOrgMenuItem)
exports('AddGangMenuItem', AddOrgMenuItem)
exports('RemoveGangMenuItem', RemoveOrgMenuItem)
exports('AddOrgMenuItem', AddOrgMenuItem)
exports('RemoveOrgMenuItem', RemoveOrgMenuItem)

-- ==============================================================
-- 玩家数据事件
-- ==============================================================

local currentOrg = nil

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    currentOrg = QBCore.Functions.GetPlayerData()
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(jobInfo)
    if currentOrg then currentOrg.job = jobInfo end
end)

RegisterNetEvent('QBCore:Client:OnGangUpdate', function(gangInfo)
    if currentOrg then currentOrg.gang = gangInfo end
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    currentOrg = nil
end)

-- ==============================================================
-- 主 Boss 菜单
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:OpenMenu', function()
    local orgType, org = GetActiveOrg()
    if not orgType or not org then
        -- 尝试回退：可能是通过旧事件触发的
        local pData = QBCore.Functions.GetPlayerData()
        if pData then
            if pData.job and pData.job.isboss then
                orgType, org = 'job', pData.job
            elseif pData.gang and pData.gang.isboss then
                orgType, org = 'gang', pData.gang
            end
        end
        if not orgType then return end
    end

    local orgLabel = org.label or 'Organization'
    local orgName = org.name
    local headerLabel = orgType == 'job' and 'Boss Menu - ' or 'Gang Management - '

    shownMenu = true

    local menu = {
        {
            header = headerLabel .. string.upper(orgLabel),
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
        {
            header = 'Manage Members',
            txt = 'View and manage your team',
            icon = 'fa-solid fa-list',
            params = {
                event = 'qb-orgmenu:client:ManageMembers',
            }
        },
        {
            header = 'Hire Members',
            txt = 'Recruit nearby civilians',
            icon = 'fa-solid fa-hand-holding',
            params = {
                event = 'qb-orgmenu:client:HireMembers',
            }
        },
        {
            header = 'Storage Access',
            txt = 'Open organization stash',
            icon = 'fa-solid fa-box-open',
            params = {
                isServer = true,
                event = 'qb-orgmenu:server:stash',
            }
        },
        {
            header = 'Outfits',
            txt = 'Change clothes',
            icon = 'fa-solid fa-shirt',
            params = {
                event = 'qb-bossmenu:client:Wardrobe',   -- 复用旧更衣室事件
            }
        },
        -- 🔑 退位交接（仅 Boss 可见）
        {
            header = '🔑 Transfer Ownership',
            txt = 'Step down and appoint a new Boss',
            icon = 'fa-solid fa-crown',
            params = {
                event = 'qb-orgmenu:client:TransferOwnership',
            }
        },
    }

    -- 注入第三方动态菜单项
    for _, v in pairs(DynamicMenuItems) do
        menu[#menu + 1] = v
    end

    menu[#menu + 1] = {
        header = 'Exit',
        icon = 'fa-solid fa-angle-left',
        params = {
            event = 'qb-menu:closeMenu',
        }
    }

    exports['qb-menu']:openMenu(menu)
end)

-- ==============================================================
-- 关闭菜单（供服务器调用）
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:CloseMenu', function()
    CloseMenuFull()
end)

-- ==============================================================
-- 成员管理列表
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:ManageMembers', function()
    local orgType, org = GetActiveOrg()
    if not orgType then return end

    local orgName = org.name
    local orgLabel = org.label
    local headerLabel = 'Manage Members - '

    local menu = {
        {
            header = headerLabel .. string.upper(orgLabel),
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
    }

    QBCore.Functions.TriggerCallback('qb-orgmenu:server:GetEmployees', function(employees)
        for _, v in pairs(employees) do
            menu[#menu + 1] = {
                header = v.name,
                txt = v.grade.name .. ' (Level ' .. v.grade.level .. ')',
                icon = 'fa-solid fa-circle-user',
                params = {
                    event = 'qb-orgmenu:client:ManageMember',
                    args = {
                        player = v,
                        orgName = orgName,
                        orgType = orgType,
                    }
                }
            }
        end
        menu[#menu + 1] = {
            header = 'Return',
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-orgmenu:client:OpenMenu',
            }
        }
        exports['qb-menu']:openMenu(menu)
    end, orgName)
end)

-- ==============================================================
-- 单个成员操作：晋升/降级/开除
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:ManageMember', function(data)
    local orgType, org = GetActiveOrg()
    if not orgType then return end

    local orgDef = GetOrgDef(orgType, data.orgName)
    if not orgDef then return end

    local menu = {
        {
            header = 'Manage ' .. data.player.name .. ' - ' .. string.upper(org.label),
            isMenuHeader = true,
            icon = 'fa-solid fa-circle-info',
        },
    }

    -- 列出该组织的所有等级，供 Boss 选择
    for k, v in pairs(orgDef.grades) do
        menu[#menu + 1] = {
            header = v.name,
            txt = 'Grade: ' .. k,
            params = {
                isServer = true,
                event = 'qb-orgmenu:server:GradeUpdate',
                icon = 'fa-solid fa-file-pen',
                args = {
                    cid = data.player.empSource,
                    orgName = data.orgName,
                    grade = tonumber(k),
                    gradename = v.name
                }
            }
        }
    end

    menu[#menu + 1] = {
        header = 'Fire Member',
        icon = 'fa-solid fa-user-large-slash',
        params = {
            isServer = true,
            event = 'qb-orgmenu:server:FireMember',
            args = {
                cid = data.player.empSource,
                orgName = data.orgName,
            }
        }
    }

    menu[#menu + 1] = {
        header = 'Return',
        icon = 'fa-solid fa-angle-left',
        params = {
            event = 'qb-orgmenu:client:ManageMembers',
        }
    }

    exports['qb-menu']:openMenu(menu)
end)

-- ==============================================================
-- 招募新成员
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:HireMembers', function()
    local orgType, org = GetActiveOrg()
    if not orgType then return end

    local orgName = org.name
    local orgLabel = org.label

    local menu = {
        {
            header = 'Hire Members - ' .. string.upper(orgLabel),
            isMenuHeader = true,
            icon = 'fa-solid fa-circle-info',
        },
    }

    QBCore.Functions.TriggerCallback('qb-orgmenu:getplayers', function(players)
        for _, v in pairs(players) do
            if v and v ~= PlayerId() then
                menu[#menu + 1] = {
                    header = v.name,
                    txt = 'Citizen ID: ' .. v.citizenid .. ' - ID: ' .. v.sourceplayer,
                    icon = 'fa-solid fa-user-check',
                    params = {
                        isServer = true,
                        event = 'qb-orgmenu:server:HireMember',
                        args = {
                            recruitSource = v.sourceplayer,
                            orgName = orgName,
                        }
                    }
                }
            end
        end
        menu[#menu + 1] = {
            header = 'Return',
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-orgmenu:client:OpenMenu',
            }
        }
        exports['qb-menu']:openMenu(menu)
    end)
end)

-- ==============================================================
-- 🔑 退位交接 — 选择接班人
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:TransferOwnership', function()
    local orgType, org = GetActiveOrg()
    if not orgType then return end

    local orgName = org.name
    local orgLabel = org.label

    local menu = {
        {
            header = '🔑 Transfer Ownership - ' .. string.upper(orgLabel),
            txt = 'Choose a successor to become the new Boss',
            isMenuHeader = true,
            icon = 'fa-solid fa-crown',
        },
    }

    -- 只显示同组织的在线成员
    QBCore.Functions.TriggerCallback('qb-orgmenu:server:GetEmployees', function(employees)
        local hasOnlineMembers = false
        for _, v in pairs(employees) do
            -- 只显示在线、非 Boss 的成员
            if v.isOnline and not v.isboss then
                hasOnlineMembers = true
                menu[#menu + 1] = {
                    header = v.name,
                    txt = v.grade.name .. ' (Level ' .. v.grade.level .. ')',
                    icon = 'fa-solid fa-user-plus',
                    params = {
                        event = 'qb-orgmenu:client:ConfirmTransfer',
                        args = {
                            successorCid = v.empSource,
                            successorName = v.name:gsub('🟢 ', ''),
                            orgName = orgName,
                            orgType = orgType,
                            orgLabel = orgLabel,
                        }
                    }
                }
            end
        end

        if not hasOnlineMembers then
            menu[#menu + 1] = {
                header = 'No eligible members online',
                txt = 'At least one other member must be online to transfer ownership',
                icon = 'fa-solid fa-circle-exclamation',
                disabled = true,
            }
        end

        menu[#menu + 1] = {
            header = 'Cancel',
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-orgmenu:client:OpenMenu',
            }
        }
        exports['qb-menu']:openMenu(menu)
    end, orgName)
end)

-- ==============================================================
-- 🔑 退位交接 — 确认弹窗
-- ==============================================================

RegisterNetEvent('qb-orgmenu:client:ConfirmTransfer', function(data)
    local menu = {
        {
            header = '⚠️ Confirm Ownership Transfer',
            txt = 'This action is IRREVERSIBLE!',
            isMenuHeader = true,
            icon = 'fa-solid fa-triangle-exclamation',
        },
        {
            header = 'You are about to transfer:',
            txt = data.orgLabel .. ' → ' .. data.successorName,
            icon = 'fa-solid fa-info-circle',
            disabled = true,
        },
        {
            header = '✅ YES — Transfer Now',
            txt = 'I confirm. Pass ownership to ' .. data.successorName,
            icon = 'fa-solid fa-check',
            params = {
                isServer = true,
                event = 'qb-orgmenu:server:TransferOwnership',
                args = {
                    successorCid = data.successorCid,
                    orgName = data.orgName,
                }
            }
        },
        {
            header = '❌ Cancel',
            txt = 'Go back',
            icon = 'fa-solid fa-xmark',
            params = {
                event = 'qb-orgmenu:client:TransferOwnership',
            }
        },
    }

    exports['qb-menu']:openMenu(menu)
end)

-- ==============================================================
-- Target / DrawText 入口（根据组织类型自动切换）
-- ==============================================================

CreateThread(function()
    if Config.UseTarget then
        -- === Job Boss Zones ===
        if Config.BossMenus then
            for job, zones in pairs(Config.BossMenus) do
                for index, coords in ipairs(zones) do
                    local zoneName = job .. '_orgmenu_' .. index
                    exports['qb-target']:AddCircleZone(zoneName, coords, 0.5, {
                        name = zoneName,
                        debugPoly = false,
                        useZ = true
                    }, {
                        options = {
                            {
                                type = 'client',
                                event = 'qb-orgmenu:client:OpenMenu',
                                icon = 'fas fa-sign-in-alt',
                                label = 'Boss Menu',
                                canInteract = function()
                                    local pData = QBCore.Functions.GetPlayerData()
                                    return pData and pData.job
                                        and pData.job.name == job and pData.job.isboss
                                end,
                            },
                        },
                        distance = 2.5
                    })
                end
            end
        end

        -- === Gang Boss Zones ===
        if Config.GangMenus then
            for gang, zones in pairs(Config.GangMenus) do
                for index, coords in ipairs(zones) do
                    local zoneName = gang .. '_gangmenu_' .. index
                    exports['qb-target']:AddCircleZone(zoneName, coords, 1.2, {
                        name = zoneName,
                        debugPoly = false,
                        useZ = true
                    }, {
                        options = {
                            {
                                type = 'client',
                                event = 'qb-orgmenu:client:OpenMenu',
                                icon = 'fas fa-sign-in-alt',
                                label = 'Gang Menu',
                                canInteract = function()
                                    local pData = QBCore.Functions.GetPlayerData()
                                    return pData and pData.gang
                                        and pData.gang.name == gang and pData.gang.isboss
                                end,
                            },
                        },
                        distance = 2.5
                    })
                end
            end
        end
    else
        -- === DrawText 模式（非 Target）===
        while true do
            local wait = 2500
            local pos = GetEntityCoords(PlayerPedId())
            local inRange = false
            local nearMenu = false
            local orgType, org = GetActiveOrg()

            if orgType and org then
                wait = 0
                local menuConfig = GetMenuConfig(orgType, org.name)
                if menuConfig then
                    for _, coords in ipairs(menuConfig) do
                        if #(pos - coords) < 5.0 then
                            inRange = true
                            if #(pos - coords) <= 1.5 then
                                nearMenu = true
                                if not shownMenu then
                                    exports['qb-core']:DrawText('[E] Open ' .. (orgType == 'job' and 'Job' or 'Gang') .. ' Management', 'left')
                                    shownMenu = true
                                end
                                if IsControlJustReleased(0, 38) then
                                    exports['qb-core']:HideText()
                                    TriggerEvent('qb-orgmenu:client:OpenMenu')
                                end
                            end
                            if not nearMenu and shownMenu then
                                CloseMenuFull()
                            end
                        end
                    end
                end
                if not inRange then
                    Wait(1500)
                    if shownMenu then
                        CloseMenuFull()
                    end
                end
            end
            Wait(wait)
        end
    end
end)

-- cl_org startup print removed
