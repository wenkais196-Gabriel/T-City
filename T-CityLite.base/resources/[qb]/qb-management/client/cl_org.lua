-- ==============================================================
-- cl_org.lua — 统一 Boss / 组织 / 帮派管理菜单 UI（#385）
--
-- 收敛原 cl_boss.lua + cl_gang.lua + cl_org.lua 为单入口控制器：
--   1. 单一交互注册：同一坐标只在 [E] 提示或 qb-target 中注册一次；
--   2. 单一菜单面板：Boss 视图（成员/招聘/仓库/更衣室）与组织视图（退位交接 + 动态注入项）分区展示；
--   3. 严格归因关闭：CloseMenuFull 仅关闭本资源持有的 qb-menu 会话与 custom-prompt，
--      不越界关闭其它资源菜单，/orgmenu 远程打开也不会被距离循环误关；
--   4. 焦点栈协同：复用 custom-ui IsTaken()/Top() 防叠开，零 SetNuiFocus 调用。
-- ==============================================================

local QBCore = exports['qb-core']:GetCoreObject()

local RESOURCE_OWNER = (GetCurrentResourceName and GetCurrentResourceName()) or 'qb-management'
local CUSTOM_UI = 'custom-ui'
local CUSTOM_PROMPT = 'custom-prompt'
local QB_MENU = 'qb-menu'
local QB_TARGET = 'qb-target'

local function copyData(value, seen)
    if type(deepcopy) == 'function' then
        return deepcopy(value, seen)
    end
    if type(value) ~= 'table' then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
        out[copyData(k, seen)] = copyData(v, seen)
    end
    return out
end

local function getPlayerData()
    if QBCore and QBCore.Functions and QBCore.Functions.GetPlayerData then
        return QBCore.Functions.GetPlayerData()
    end
    return nil
end

local function GetActiveOrg(preferredType, pData)
    pData = pData or getPlayerData()
    if type(pData) ~= 'table' then return nil, nil end

    if preferredType == 'gang' then
        if type(pData.gang) == 'table' and pData.gang.isboss then
            return 'gang', pData.gang
        end
        if type(pData.job) == 'table' and pData.job.isboss then
            return 'job', pData.job
        end
    else
        if type(pData.job) == 'table' and pData.job.isboss then
            return 'job', pData.job
        end
        if type(pData.gang) == 'table' and pData.gang.isboss then
            return 'gang', pData.gang
        end
    end
    return nil, nil
end

local function GetOrgDef(orgType, orgName)
    if not QBCore or not QBCore.Shared then return nil end
    if orgType == 'job' then
        return QBCore.Shared.Jobs and QBCore.Shared.Jobs[orgName]
    elseif orgType == 'gang' then
        return QBCore.Shared.Gangs and QBCore.Shared.Gangs[orgName]
    end
    return nil
end

local function GetMenuConfig(orgType, orgName)
    if not Config then return nil end
    if orgType == 'job' then
        return Config.BossMenus and Config.BossMenus[orgName]
    elseif orgType == 'gang' then
        return Config.GangMenus and Config.GangMenus[orgName]
    end
    return nil
end

-- ==============================================================
-- 焦点栈与归因状态（提示条状态与菜单持有权彻底分离）
-- ==============================================================

local shownPrompt = false
local shownPromptLabel = nil
local activeMenuOwner = nil
local activeZoneCoords = nil
local pendingCallbackAt = nil
local nextDynamicId = 0

local DynamicMenuItems = {}
local DynamicMenuOrder = {}

local function uiStarted()
    return GetResourceState ~= nil and GetResourceState(CUSTOM_UI) == 'started'
end

local function uiIsTaken()
    if not uiStarted() then return false end
    local ok, taken = pcall(function()
        return exports[CUSTOM_UI]:IsTaken()
    end)
    return ok and taken == true
end

local function uiTopFrame()
    if not uiStarted() then return nil end
    local ok, top = pcall(function()
        return exports[CUSTOM_UI]:Top()
    end)
    if ok and type(top) == 'table' then
        return top
    end
    return nil
end

local function isAllowedActiveOwner(ownerName)
    return ownerName == 'custom-menu' or ownerName == QB_MENU or ownerName == RESOURCE_OWNER
end

local function canOpenMenu(fromPrompt)
    if not uiIsTaken() then
        return true
    end
    if fromPrompt then
        return false
    end
    local top = uiTopFrame()
    return top ~= nil and isAllowedActiveOwner(top.owner)
end

local function showPrompt(orgType)
    local label = '打开' .. (orgType == 'job' and '职业' or '帮派') .. '管理'
    if shownPrompt and shownPromptLabel == label then return end
    shownPrompt = true
    shownPromptLabel = label
    pcall(function()
        exports[CUSTOM_PROMPT]:Show({ key = 'E', label = label })
    end)
end

local function hidePrompt()
    if not shownPrompt then return end
    shownPrompt = false
    shownPromptLabel = nil
    pcall(function()
        exports[CUSTOM_PROMPT]:Hide()
    end)
end

local function clearOwnedMenuState()
    activeMenuOwner = nil
    activeZoneCoords = nil
    pendingCallbackAt = nil
end

local function beginAsyncMenuWait()
    pendingCallbackAt = (GetGameTimer ~= nil and GetGameTimer()) or 1
end

local function isAsyncMenuPending()
    if not pendingCallbackAt then return false end
    if GetGameTimer == nil then return true end
    if (GetGameTimer() - pendingCallbackAt) > 5000 then
        pendingCallbackAt = nil
        return false
    end
    return true
end

local function CloseMenuFull(owner)
    hidePrompt()
    if activeMenuOwner == nil or owner ~= RESOURCE_OWNER or activeMenuOwner ~= owner then
        return false
    end
    if uiStarted() then
        if not uiIsTaken() then
            clearOwnedMenuState()
            return false
        end
        local top = uiTopFrame()
        if top ~= nil and type(top.owner) == 'string' and top.owner ~= '' and not isAllowedActiveOwner(top.owner) then
            clearOwnedMenuState()
            return false
        end
    end
    clearOwnedMenuState()
    pcall(function()
        exports[QB_MENU]:closeMenu()
    end)
    return true
end

local function openManagedMenu(menu, opts)
    opts = type(opts) == 'table' and opts or {}
    if not canOpenMenu(opts.fromPrompt == true) then
        pendingCallbackAt = nil
        return false
    end
    pendingCallbackAt = nil
    activeMenuOwner = RESOURCE_OWNER
    if opts.zoneCoords ~= nil then
        activeZoneCoords = opts.zoneCoords
    elseif not opts.preserveZone then
        activeZoneCoords = nil
    end
    local okOpen, errOpen = pcall(function()
        exports[QB_MENU]:openMenu(menu)
    end)
    if not okOpen then
        clearOwnedMenuState()
        print(('[qb-management] open failed: %s'):format(tostring(errOpen)))
        return false
    end
    return true
end

-- ==============================================================
-- 动态菜单项 API（统一写入单一表，保留三个旧导出名兼容）
-- ==============================================================

local function removeOrderKey(id)
    for i = #DynamicMenuOrder, 1, -1 do
        if DynamicMenuOrder[i] == id then
            table.remove(DynamicMenuOrder, i)
        end
    end
end

local function AddOrgMenuItem(data, id)
    local menuID = id
    if menuID == nil then
        nextDynamicId = nextDynamicId + 1
        menuID = nextDynamicId
    end
    removeOrderKey(menuID)
    DynamicMenuOrder[#DynamicMenuOrder + 1] = menuID
    DynamicMenuItems[menuID] = copyData(data)
    return menuID
end

local function RemoveOrgMenuItem(id)
    DynamicMenuItems[id] = nil
    removeOrderKey(id)
end

exports('AddBossMenuItem', AddOrgMenuItem)
exports('RemoveBossMenuItem', RemoveOrgMenuItem)
exports('AddGangMenuItem', AddOrgMenuItem)
exports('RemoveGangMenuItem', RemoveOrgMenuItem)
exports('AddOrgMenuItem', AddOrgMenuItem)
exports('RemoveOrgMenuItem', RemoveOrgMenuItem)

-- ==============================================================
-- 帮派地图标记（原 cl_gang.lua 保留）
-- ==============================================================

local BLIP_FALLBACKS = {
    blip_cartel_hq = 'Cartel 总部',
    blip_cartel_garage = 'Cartel 车库',
    blip_cartel_boss = 'Cartel 首脑办公室',
    blip_ballas_hq = 'Ballas 据点',
    blip_families_hq = 'Families 据点',
    blip_lostmc_hq = 'Lost MC 会所',
    blip_vagos_hq = 'Vagos 据点',
}

local function blipLabel(key)
    if type(_L) == 'function' then
        local ok, label = pcall(_L, key)
        if ok and type(label) == 'string' and label ~= '' then
            return label
        end
    end
    return BLIP_FALLBACKS[key] or key
end

local gangBlips = {}

local function ClearGangBlips()
    for _, blip in ipairs(gangBlips) do
        if DoesBlipExist and DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    gangBlips = {}
end

local function createGangBlip(x, y, z, sprite, scale, colour, category, labelKey)
    if type(AddBlipForCoord) ~= 'function' then return end
    local blip = AddBlipForCoord(x, y, z)
    SetBlipSprite(blip, sprite)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, scale)
    SetBlipColour(blip, colour)
    SetBlipAsShortRange(blip, true)
    if category then
        SetBlipCategory(blip, category)
    end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(blipLabel(labelKey))
    EndTextCommandSetBlipName(blip)
    gangBlips[#gangBlips + 1] = blip
end

local function UpdateGangBlips(gangData)
    ClearGangBlips()

    if type(gangData) ~= 'table' then
        local pData = getPlayerData()
        gangData = pData and pData.gang
    end
    if type(gangData) ~= 'table' then return end

    if gangData.name == 'cartel' then
        createGangBlip(1395.80, 1141.74, 115.24, 84, 0.8, 1, 136, 'blip_cartel_hq')
        createGangBlip(1411.67, 1117.80, 114.84, 357, 0.7, 1, 136, 'blip_cartel_garage')
        if gangData.isboss then
            createGangBlip(1407.92, 1141.29, 113.84, 438, 0.8, 28, 136, 'blip_cartel_boss')
        end
    elseif gangData.name == 'ballas' then
        createGangBlip(98.15, -1929.74, 20.80, 84, 0.8, 30, nil, 'blip_ballas_hq')
    elseif gangData.name == 'families' then
        createGangBlip(-144.13, -1693.93, 29.29, 84, 0.8, 25, nil, 'blip_families_hq')
    elseif gangData.name == 'lostmc' then
        createGangBlip(982.26, -104.22, 74.85, 84, 0.8, 27, nil, 'blip_lostmc_hq')
    elseif gangData.name == 'vagos' then
        createGangBlip(336.57, -2012.39, 22.31, 84, 0.8, 49, nil, 'blip_vagos_hq')
    end
end

-- ==============================================================
-- 玩家数据与生命周期事件
-- ==============================================================

local currentOrg = nil

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= RESOURCE_OWNER then return end
    currentOrg = getPlayerData()
    UpdateGangBlips(currentOrg and currentOrg.gang)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RESOURCE_OWNER then return end
    ClearGangBlips()
    CloseMenuFull(RESOURCE_OWNER)
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    currentOrg = getPlayerData()
    UpdateGangBlips(currentOrg and currentOrg.gang)
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(jobInfo)
    if currentOrg then currentOrg.job = jobInfo end
end)

RegisterNetEvent('QBCore:Client:OnGangUpdate', function(gangInfo)
    if currentOrg then currentOrg.gang = gangInfo end
    UpdateGangBlips(gangInfo)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    currentOrg = nil
    ClearGangBlips()
    CloseMenuFull(RESOURCE_OWNER)
end)

RegisterNetEvent('qb-menu:client:menuClosed', function()
    if activeMenuOwner == RESOURCE_OWNER then
        clearOwnedMenuState()
    end
end)

-- ==============================================================
-- 主菜单：同一菜单内分「老板视图」与「组织视图」区块
-- ==============================================================

local function openOrgMenu(preferredType, opts)
    opts = type(opts) == 'table' and opts or {}
    local orgType, org = GetActiveOrg(preferredType)
    if not orgType or not org then return false end

    if not canOpenMenu(opts.fromPrompt == true) then
        return false
    end

    local orgLabel = org.label or org.name or 'Organization'
    local orgName = org.name
    local headerLabel = orgType == 'job' and 'Boss Menu - ' or 'Gang Management - '

    local menu = {
        {
            header = headerLabel .. string.upper(orgLabel),
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
        {
            header = '老板视图 · 人事与库存',
            txt = orgType == 'job' and '团队管理、招聘、组织仓库与更衣室' or '帮派成员、招新、帮派仓库与更衣室',
            icon = 'fa-solid fa-briefcase',
            isMenuHeader = true,
        },
        {
            header = 'Manage Members',
            txt = 'View and manage your team',
            icon = 'fa-solid fa-list',
            params = {
                event = 'qb-orgmenu:client:ManageMembers',
                args = { orgType = orgType, orgName = orgName },
            }
        },
        {
            header = 'Hire Members',
            txt = 'Recruit nearby civilians',
            icon = 'fa-solid fa-hand-holding',
            params = {
                event = 'qb-orgmenu:client:HireMembers',
                args = { orgType = orgType, orgName = orgName },
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
                event = 'qb-bossmenu:client:Wardrobe',
            }
        },
        {
            header = '组织视图 · 治理与扩展',
            txt = '所有权交接及第三方挂载入口',
            icon = 'fa-solid fa-sitemap',
            isMenuHeader = true,
        },
        {
            header = '🔑 Transfer Ownership',
            txt = 'Step down and appoint a new Boss',
            icon = 'fa-solid fa-crown',
            params = {
                event = 'qb-orgmenu:client:TransferOwnership',
                args = { orgType = orgType, orgName = orgName },
            }
        },
    }

    for _, key in ipairs(DynamicMenuOrder) do
        local item = DynamicMenuItems[key]
        if type(item) == 'table' then
            menu[#menu + 1] = copyData(item)
        end
    end

    menu[#menu + 1] = {
        header = 'Exit',
        icon = 'fa-solid fa-angle-left',
        params = {
            event = 'qb-orgmenu:client:CloseMenu',
        }
    }

    return openManagedMenu(menu, opts)
end

RegisterNetEvent('qb-orgmenu:client:OpenMenu', function(data)
    local opts = type(data) == 'table' and data or {}
    openOrgMenu(opts.orgType, opts)
end)

RegisterNetEvent('qb-bossmenu:client:OpenMenu', function(data)
    local opts = type(data) == 'table' and data or {}
    openOrgMenu('job', opts)
end)

RegisterNetEvent('qb-gangmenu:client:OpenMenu', function(data)
    local opts = type(data) == 'table' and data or {}
    openOrgMenu('gang', opts)
end)

-- Cartel 普通成员专属个人面板（原 cl_gang.lua 保留）
RegisterNetEvent('qb-gangmenu:client:OpenMemberMenu', function()
    local pData = getPlayerData()
    if type(pData) ~= 'table' or type(pData.gang) ~= 'table' or pData.gang.name ~= 'cartel' then
        return
    end
    if not canOpenMenu(false) then
        return
    end
    local memberMenu = {
        {
            header = '卡特尔个人面板',
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
        {
            header = '个人储物箱',
            txt = '打开您个人的专属独立保险箱',
            icon = 'fa-solid fa-box-open',
            params = {
                isServer = true,
                event = 'qb-gangmenu:server:personalStash',
            }
        },
        {
            header = '个人更衣室',
            txt = '更换您保存过的精美帮派服装',
            icon = 'fa-solid fa-shirt',
            params = {
                event = 'qb-gangmenu:client:Warbobe',
            }
        },
        {
            header = 'Exit',
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-orgmenu:client:CloseMenu',
            }
        }
    }
    openManagedMenu(memberMenu, { preserveZone = false })
end)

-- 更衣室事件兼容
local function openOutfitWardrobe()
    hidePrompt()
    clearOwnedMenuState()
    TriggerEvent('qb-clothing:client:openOutfitMenu')
end

RegisterNetEvent('qb-bossmenu:client:Wardrobe', openOutfitWardrobe)
RegisterNetEvent('qb-gangmenu:client:Warbobe', openOutfitWardrobe)

-- 关闭菜单（严格按 owner 归因，供服务端与 Exit 项调用）
RegisterNetEvent('qb-orgmenu:client:CloseMenu', function()
    CloseMenuFull(RESOURCE_OWNER)
end)

RegisterNetEvent('qb-bossmenu:client:CloseMenu', function()
    CloseMenuFull(RESOURCE_OWNER)
end)

RegisterNetEvent('qb-gangmenu:client:CloseMenu', function()
    CloseMenuFull(RESOURCE_OWNER)
end)

-- ==============================================================
-- 成员管理列表 / 升降级 / 开除 / 招募 / 退位交接
-- ==============================================================

local function openManageMembers(preferredType)
    local orgType, org = GetActiveOrg(preferredType)
    if not orgType or not org then return end
    if not canOpenMenu(false) then return end

    local orgName = org.name
    local orgLabel = org.label or orgName

    beginAsyncMenuWait()
    QBCore.Functions.TriggerCallback('qb-orgmenu:server:GetEmployees', function(employees)
        if not canOpenMenu(false) then
            pendingCallbackAt = nil
            return
        end
        local menu = {
            {
                header = 'Manage Members - ' .. string.upper(orgLabel),
                icon = 'fa-solid fa-circle-info',
                isMenuHeader = true,
            },
        }
        for _, v in pairs(employees or {}) do
            local gradeName = v.grade and v.grade.name or ''
            local gradeLevel = v.grade and v.grade.level or 0
            menu[#menu + 1] = {
                header = v.name,
                txt = gradeName .. ' (Level ' .. tostring(gradeLevel) .. ')',
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
                args = { orgType = orgType, preserveZone = true },
            }
        }
        openManagedMenu(menu, { preserveZone = true })
    end, orgName)
end

RegisterNetEvent('qb-orgmenu:client:ManageMembers', function(data)
    openManageMembers(type(data) == 'table' and data.orgType or nil)
end)

RegisterNetEvent('qb-bossmenu:client:employeelist', function()
    openManageMembers('job')
end)

RegisterNetEvent('qb-gangmenu:client:ManageGang', function()
    openManageMembers('gang')
end)

local function openManageMember(data, preferredType)
    if type(data) ~= 'table' or type(data.player) ~= 'table' then return end
    if not canOpenMenu(false) then return end

    local orgNameHint = data.orgName or (data.work and data.work.name)
    local inferredType = data.orgType or preferredType
    if not inferredType and orgNameHint and QBCore and QBCore.Shared then
        if QBCore.Shared.Gangs and QBCore.Shared.Gangs[orgNameHint] then
            inferredType = 'gang'
        elseif QBCore.Shared.Jobs and QBCore.Shared.Jobs[orgNameHint] then
            inferredType = 'job'
        end
    end

    local orgType, org = GetActiveOrg(inferredType)
    if not orgType or not org then return end

    local orgName = orgNameHint or org.name
    local orgDef = GetOrgDef(orgType, orgName)
    if not orgDef or type(orgDef.grades) ~= 'table' then return end

    local menu = {
        {
            header = 'Manage ' .. tostring(data.player.name) .. ' - ' .. string.upper(org.label or orgName),
            isMenuHeader = true,
            icon = 'fa-solid fa-circle-info',
        },
    }

    local gradeKeys = {}
    for k in pairs(orgDef.grades) do
        gradeKeys[#gradeKeys + 1] = k
    end
    table.sort(gradeKeys, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)

    for _, k in ipairs(gradeKeys) do
        local v = orgDef.grades[k]
        menu[#menu + 1] = {
            header = v.name,
            txt = 'Grade: ' .. tostring(k),
            icon = 'fa-solid fa-file-pen',
            params = {
                isServer = true,
                event = 'qb-orgmenu:server:GradeUpdate',
                icon = 'fa-solid fa-file-pen',
                args = {
                    cid = data.player.empSource,
                    orgName = orgName,
                    grade = tonumber(k),
                    gradename = v.name,
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
                orgName = orgName,
            }
        }
    }

    menu[#menu + 1] = {
        header = 'Return',
        icon = 'fa-solid fa-angle-left',
        params = {
            event = 'qb-orgmenu:client:ManageMembers',
            args = { orgType = orgType },
        }
    }

    openManagedMenu(menu, { preserveZone = true })
end

RegisterNetEvent('qb-orgmenu:client:ManageMember', function(data)
    openManageMember(data, nil)
end)

RegisterNetEvent('qb-bossmenu:client:ManageEmployee', function(data)
    openManageMember(data, 'job')
end)

-- 保留原 cl_gang.lua 的历史拼写事件名（qb-gangmenu:lient:ManageMember）兼容外部调用
RegisterNetEvent('qb-gangmenu:lient:ManageMember', function(data)
    openManageMember(data, 'gang')
end)

local function openHireMembers(preferredType)
    local orgType, org = GetActiveOrg(preferredType)
    if not orgType or not org then return end
    if not canOpenMenu(false) then return end

    local orgName = org.name
    local orgLabel = org.label or orgName

    beginAsyncMenuWait()
    QBCore.Functions.TriggerCallback('qb-orgmenu:getplayers', function(players)
        if not canOpenMenu(false) then
            pendingCallbackAt = nil
            return
        end
        local menu = {
            {
                header = 'Hire Members - ' .. string.upper(orgLabel),
                isMenuHeader = true,
                icon = 'fa-solid fa-circle-info',
            },
        }
        for _, v in pairs(players or {}) do
            if v and v ~= PlayerId() then
                menu[#menu + 1] = {
                    header = v.name,
                    txt = 'Citizen ID: ' .. tostring(v.citizenid) .. ' - ID: ' .. tostring(v.sourceplayer),
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
                args = { orgType = orgType, preserveZone = true },
            }
        }
        openManagedMenu(menu, { preserveZone = true })
    end)
end

RegisterNetEvent('qb-orgmenu:client:HireMembers', function(data)
    openHireMembers(type(data) == 'table' and data.orgType or nil)
end)

RegisterNetEvent('qb-bossmenu:client:HireMenu', function()
    openHireMembers('job')
end)

RegisterNetEvent('qb-gangmenu:client:HireMembers', function()
    openHireMembers('gang')
end)

RegisterNetEvent('qb-orgmenu:client:TransferOwnership', function(data)
    local preferredType = type(data) == 'table' and data.orgType or nil
    local orgType, org = GetActiveOrg(preferredType)
    if not orgType or not org then return end
    if not canOpenMenu(false) then return end

    local orgName = org.name
    local orgLabel = org.label or orgName

    beginAsyncMenuWait()
    QBCore.Functions.TriggerCallback('qb-orgmenu:server:GetEmployees', function(employees)
        if not canOpenMenu(false) then
            pendingCallbackAt = nil
            return
        end
        local menu = {
            {
                header = '🔑 Transfer Ownership - ' .. string.upper(orgLabel),
                txt = 'Choose a successor to become the new Boss',
                isMenuHeader = true,
                icon = 'fa-solid fa-crown',
            },
        }

        local hasOnlineMembers = false
        for _, v in pairs(employees or {}) do
            if v.isOnline and not v.isboss then
                hasOnlineMembers = true
                local gradeName = v.grade and v.grade.name or ''
                local gradeLevel = v.grade and v.grade.level or 0
                menu[#menu + 1] = {
                    header = v.name,
                    txt = gradeName .. ' (Level ' .. tostring(gradeLevel) .. ')',
                    icon = 'fa-solid fa-user-plus',
                    params = {
                        event = 'qb-orgmenu:client:ConfirmTransfer',
                        args = {
                            successorCid = v.empSource,
                            successorName = tostring(v.name):gsub('🟢 ', ''),
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
                args = { orgType = orgType, preserveZone = true },
            }
        }
        openManagedMenu(menu, { preserveZone = true })
    end, orgName)
end)

RegisterNetEvent('qb-orgmenu:client:ConfirmTransfer', function(data)
    if type(data) ~= 'table' then return end
    if not canOpenMenu(false) then return end

    local menu = {
        {
            header = '⚠️ Confirm Ownership Transfer',
            txt = 'This action is IRREVERSIBLE!',
            isMenuHeader = true,
            icon = 'fa-solid fa-triangle-exclamation',
        },
        {
            header = 'You are about to transfer:',
            txt = tostring(data.orgLabel) .. ' → ' .. tostring(data.successorName),
            icon = 'fa-solid fa-info-circle',
            disabled = true,
        },
        {
            header = '✅ YES — Transfer Now',
            txt = 'I confirm. Pass ownership to ' .. tostring(data.successorName),
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
                args = { orgType = data.orgType },
            }
        },
    }

    openManagedMenu(menu, { preserveZone = true })
end)

-- ==============================================================
-- 单一交互入口注册：同一坐标只注册一次（Target 或 [E] 提示）
-- ==============================================================

local function coordKey(coords)
    return string.format('%.2f:%.2f:%.2f', coords.x, coords.y, coords.z)
end

local function registerTargetZonesOnce()
    local seenCoords = {}

    local function addZoneOnce(zoneName, coords, radius, options)
        local key = coordKey(coords)
        if seenCoords[key] then return end
        seenCoords[key] = zoneName
        exports[QB_TARGET]:AddCircleZone(zoneName, coords, radius, {
            name = zoneName,
            debugPoly = false,
            useZ = true,
        }, {
            options = options,
            distance = 2.5,
        })
    end

    if Config and Config.BossMenus then
        for job, zones in pairs(Config.BossMenus) do
            for index, coords in ipairs(zones) do
                addZoneOnce(job .. '_orgmenu_' .. index, coords, 0.5, {
                    {
                        type = 'client',
                        event = 'qb-orgmenu:client:OpenMenu',
                        icon = 'fas fa-sign-in-alt',
                        label = 'Boss Menu',
                        canInteract = function()
                            local pData = getPlayerData()
                            return pData and pData.job and pData.job.name == job and pData.job.isboss == true
                        end,
                    },
                })
            end
        end
    end

    if Config and Config.GangMenus then
        for gang, zones in pairs(Config.GangMenus) do
            for index, coords in ipairs(zones) do
                local options = {
                    {
                        type = 'client',
                        event = 'qb-orgmenu:client:OpenMenu',
                        icon = 'fas fa-sign-in-alt',
                        label = 'Gang Menu',
                        canInteract = function()
                            local pData = getPlayerData()
                            return pData and pData.gang and pData.gang.name == gang and pData.gang.isboss == true
                        end,
                    },
                }
                if gang == 'cartel' then
                    options[#options + 1] = {
                        type = 'client',
                        event = 'qb-gangmenu:client:OpenMemberMenu',
                        icon = 'fas fa-door-open',
                        label = '打开个人更衣与储物',
                        canInteract = function()
                            local pData = getPlayerData()
                            return pData and pData.gang and pData.gang.name == 'cartel'
                        end,
                    }
                end
                addZoneOnce(gang .. '_gangmenu_' .. index, coords, 1.2, options)
            end
        end
    end

    -- Cartel 首脑套房办公桌（与大门共用单点定义，不重复注册坐标）
    addZoneOnce('cartel_boss_office', vector3(1407.92, 1141.29, 113.84), 1.2, {
        {
            type = 'client',
            event = 'qb-orgmenu:client:OpenMenu',
            icon = 'fas fa-crown',
            label = '打开首脑控制台',
            canInteract = function()
                local pData = getPlayerData()
                return pData and pData.gang and pData.gang.name == 'cartel' and pData.gang.isboss == true
            end,
        },
    })
end

local function findNearestBossPrompt(pos, pData)
    if type(pData) ~= 'table' or pos == nil then
        return nil, nil, false
    end
    local seen = {}
    local inRange = false
    local candidates = {}

    if type(pData.job) == 'table' and pData.job.isboss then
        local zones = GetMenuConfig('job', pData.job.name)
        if zones then
            candidates[#candidates + 1] = { orgType = 'job', zones = zones }
        end
    end
    if type(pData.gang) == 'table' and pData.gang.isboss then
        local zones = GetMenuConfig('gang', pData.gang.name)
        if zones then
            candidates[#candidates + 1] = { orgType = 'gang', zones = zones }
        end
    end

    for _, entry in ipairs(candidates) do
        for _, coords in ipairs(entry.zones) do
            local key = coordKey(coords)
            if not seen[key] then
                seen[key] = true
                local dist = #(pos - coords)
                if dist < 5.0 then
                    inRange = true
                    if dist <= 1.5 then
                        return entry.orgType, coords, true
                    end
                end
            end
        end
    end

    return nil, nil, inRange
end

local function stepPromptLoop()
    local pData = getPlayerData()
    local pos = GetEntityCoords(PlayerPedId())
    local nearOrgType, nearCoords, inRange = findNearestBossPrompt(pos, pData)
    local uiBusy = uiIsTaken()

    if nearCoords then
        if uiBusy or activeMenuOwner == RESOURCE_OWNER then
            if uiStarted() and not uiBusy and not isAsyncMenuPending() and activeMenuOwner == RESOURCE_OWNER then
                clearOwnedMenuState()
                showPrompt(nearOrgType)
            else
                hidePrompt()
            end
        else
            showPrompt(nearOrgType)
            if IsControlJustReleased(0, 38) then
                hidePrompt()
                openOrgMenu(nearOrgType, {
                    fromPrompt = true,
                    fromZone = true,
                    zoneCoords = nearCoords,
                })
            end
        end
    else
        hidePrompt()
        if activeMenuOwner == RESOURCE_OWNER and activeZoneCoords ~= nil then
            local activeType, _ = GetActiveOrg(nil, pData)
            local stillNear = activeType ~= nil and #(pos - activeZoneCoords) <= 1.5
            if not stillNear then
                CloseMenuFull(RESOURCE_OWNER)
            end
        end
    end

    return inRange and 0 or 500
end

CreateThread(function()
    if Config and Config.UseTarget and not Config.ManagementUsePrompt then
        registerTargetZonesOnce()
    else
        while true do
            local waitMs = stepPromptLoop()
            Wait(waitMs)
        end
    end
end)
