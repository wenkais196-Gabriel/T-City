local QBCore = exports['qb-core']:GetCoreObject()
local PlayerGang = QBCore.Functions.GetPlayerData().gang
local shownGangMenu = false
local DynamicMenuItems = {}

-- UTIL
local function CloseMenuFullGang()
    exports['qb-menu']:closeMenu()
    exports['qb-core']:HideText()
    shownGangMenu = false
end

--//Events
local gangBlips = {}

local function ClearGangBlips()
    for _, blip in ipairs(gangBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    gangBlips = {}
end

local function UpdateGangBlips()
    ClearGangBlips()
    
    if PlayerGang and PlayerGang.name == 'cartel' then
        -- 1. Cartel HQ (Boss Menu / Member Menu Entrance)
        local hqBlip = AddBlipForCoord(1395.80, 1141.74, 115.24)
        SetBlipSprite(hqBlip, 84) -- Business/Organization
        SetBlipDisplay(hqBlip, 4)
        SetBlipScale(hqBlip, 0.8)
        SetBlipColour(hqBlip, 1) -- Red
        SetBlipAsShortRange(hqBlip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName("卡特尔总部 (Cartel HQ)")
        EndTextCommandSetBlipName(hqBlip)
        gangBlips[#gangBlips + 1] = hqBlip

        -- 2. Cartel Garage
        local garageBlip = AddBlipForCoord(1411.67, 1117.80, 114.84)
        SetBlipSprite(garageBlip, 357) -- Garage
        SetBlipDisplay(garageBlip, 4)
        SetBlipScale(garageBlip, 0.7)
        SetBlipColour(garageBlip, 1) -- Red
        SetBlipAsShortRange(garageBlip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName("卡特尔车库 (Cartel Garage)")
        EndTextCommandSetBlipName(garageBlip)
        gangBlips[#gangBlips + 1] = garageBlip

        -- 3. Cartel Boss Office (Visible ONLY to cartel bosses!)
        if PlayerGang.isboss then
            local bossBlip = AddBlipForCoord(1407.92, 1141.29, 113.84)
            SetBlipSprite(bossBlip, 438) -- Golden Crown (King/Boss!)
            SetBlipDisplay(bossBlip, 4)
            SetBlipScale(bossBlip, 0.8)
            SetBlipColour(bossBlip, 28) -- Gold color!
            SetBlipAsShortRange(bossBlip, true)
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName("卡特尔首脑控制台 (Cartel Boss Suite)")
            EndTextCommandSetBlipName(bossBlip)
            gangBlips[#gangBlips + 1] = bossBlip
        end
    end
end

AddEventHandler('onResourceStart', function(resource) --if you restart the resource
    if resource == GetCurrentResourceName() then
        Wait(200)
        PlayerGang = QBCore.Functions.GetPlayerData().gang
        UpdateGangBlips()
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerGang = QBCore.Functions.GetPlayerData().gang
    UpdateGangBlips()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    PlayerGang = nil
    ClearGangBlips()
end)

RegisterNetEvent('QBCore:Client:OnGangUpdate', function(InfoGang)
    PlayerGang = InfoGang
    UpdateGangBlips()
end)

RegisterNetEvent('qb-gangmenu:client:Warbobe', function()
    TriggerEvent('qb-clothing:client:openOutfitMenu')
end)

-- Member-only menu for all Cartel members
RegisterNetEvent('qb-gangmenu:client:OpenMemberMenu', function()
    local memberMenu = {
        {
            header = "卡特尔个人面板",
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
        {
            header = "个人储物箱",
            txt = "打开您个人的专属独立保险箱",
            icon = 'fa-solid fa-box-open',
            params = {
                isServer = true,
                event = 'qb-gangmenu:server:personalStash',
            }
        },
        {
            header = "个人更衣室",
            txt = "更换您保存过的精美帮派服装",
            icon = 'fa-solid fa-shirt',
            params = {
                event = 'qb-gangmenu:client:Warbobe',
            }
        },
        {
            header = Lang:t('bodygang.exit'),
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-menu:closeMenu',
            }
        }
    }
    exports['qb-menu']:openMenu(memberMenu)
end)

local function AddGangMenuItem(data, id)
    local menuID = id or (#DynamicMenuItems + 1)
    DynamicMenuItems[menuID] = deepcopy(data)
    return menuID
end

exports('AddGangMenuItem', AddGangMenuItem)

local function RemoveGangMenuItem(id)
    DynamicMenuItems[id] = nil
end

exports('RemoveGangMenuItem', RemoveGangMenuItem)

RegisterNetEvent('qb-gangmenu:client:OpenMenu', function()
    shownGangMenu = true
    local gangMenu = {
        {
            header = Lang:t('headersgang.bsm') .. string.upper(PlayerGang.label),
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
        {
            header = Lang:t('bodygang.manage'),
            txt = Lang:t('bodygang.managed'),
            icon = 'fa-solid fa-list',
            params = {
                event = 'qb-gangmenu:client:ManageGang',
            }
        },
        {
            header = Lang:t('bodygang.hire'),
            txt = Lang:t('bodygang.hired'),
            icon = 'fa-solid fa-hand-holding',
            params = {
                event = 'qb-gangmenu:client:HireMembers',
            }
        },
        {
            header = Lang:t('bodygang.storage'),
            txt = Lang:t('bodygang.storaged'),
            icon = 'fa-solid fa-box-open',
            params = {
                isServer = true,
                event = 'qb-gangmenu:server:stash',
            }
        },
        {
            header = Lang:t('bodygang.outfits'),
            txt = Lang:t('bodygang.outfitsd'),
            icon = 'fa-solid fa-shirt',
            params = {
                event = 'qb-gangmenu:client:Warbobe',
            }
        }
    }

    for _, v in pairs(DynamicMenuItems) do
        gangMenu[#gangMenu + 1] = v
    end

    gangMenu[#gangMenu + 1] = {
        header = Lang:t('bodygang.exit'),
        icon = 'fa-solid fa-angle-left',
        params = {
            event = 'qb-menu:closeMenu',
        }
    }

    exports['qb-menu']:openMenu(gangMenu)
end)

RegisterNetEvent('qb-gangmenu:client:ManageGang', function()
    local GangMembersMenu = {
        {
            header = Lang:t('bodygang.mempl') .. string.upper(PlayerGang.label),
            icon = 'fa-solid fa-circle-info',
            isMenuHeader = true,
        },
    }
    QBCore.Functions.TriggerCallback('qb-gangmenu:server:GetEmployees', function(cb)
        for _, v in pairs(cb) do
            GangMembersMenu[#GangMembersMenu + 1] = {
                header = v.name,
                txt = v.grade.name,
                icon = 'fa-solid fa-circle-user',
                params = {
                    event = 'qb-gangmenu:lient:ManageMember',
                    args = {
                        player = v,
                        work = PlayerGang
                    }
                }
            }
        end
        GangMembersMenu[#GangMembersMenu + 1] = {
            header = Lang:t('bodygang.return'),
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-gangmenu:client:OpenMenu',
            }
        }
        exports['qb-menu']:openMenu(GangMembersMenu)
    end, PlayerGang.name)
end)

RegisterNetEvent('qb-gangmenu:lient:ManageMember', function(data)
    local MemberMenu = {
        {
            header = Lang:t('bodygang.mngpl') .. data.player.name .. ' - ' .. string.upper(PlayerGang.label),
            isMenuHeader = true,
            icon = 'fa-solid fa-circle-info',
        },
    }
    for k, v in pairs(QBCore.Shared.Gangs[data.work.name].grades) do
        MemberMenu[#MemberMenu + 1] = {
            header = v.name,
            txt = Lang:t('bodygang.grade') .. k,
            params = {
                isServer = true,
                event = 'qb-gangmenu:server:GradeUpdate',
                icon = 'fa-solid fa-file-pen',
                args = {
                    cid = data.player.empSource,
                    grade = tonumber(k),
                    gradename = v.name
                }
            }
        }
    end
    MemberMenu[#MemberMenu + 1] = {
        header = Lang:t('bodygang.fireemp'),
        icon = 'fa-solid fa-user-large-slash',
        params = {
            isServer = true,
            event = 'qb-gangmenu:server:FireMember',
            args = data.player.empSource
        }
    }
    MemberMenu[#MemberMenu + 1] = {
        header = Lang:t('bodygang.return'),
        icon = 'fa-solid fa-angle-left',
        params = {
            event = 'qb-gangmenu:client:ManageGang',
        }
    }
    exports['qb-menu']:openMenu(MemberMenu)
end)

RegisterNetEvent('qb-gangmenu:client:HireMembers', function()
    local HireMembersMenu = {
        {
            header = Lang:t('bodygang.hireemp') .. string.upper(PlayerGang.label),
            isMenuHeader = true,
            icon = 'fa-solid fa-circle-info',
        },
    }
    QBCore.Functions.TriggerCallback('qb-gangmenu:getplayers', function(players)
        for _, v in pairs(players) do
            if v and v ~= PlayerId() then
                HireMembersMenu[#HireMembersMenu + 1] = {
                    header = v.name,
                    txt = Lang:t('bodygang.cid') .. v.citizenid .. ' - ID: ' .. v.sourceplayer,
                    icon = 'fa-solid fa-user-check',
                    params = {
                        isServer = true,
                        event = 'qb-gangmenu:server:HireMember',
                        args = v.sourceplayer
                    }
                }
            end
        end
        HireMembersMenu[#HireMembersMenu + 1] = {
            header = Lang:t('bodygang.return'),
            icon = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-gangmenu:client:OpenMenu',
            }
        }
        exports['qb-menu']:openMenu(HireMembersMenu)
    end)
end)

-- MAIN THREAD

CreateThread(function()
    if Config.UseTarget then
        for gang, zones in pairs(Config.GangMenus) do
            if gang ~= 'cartel' then
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
                                event = 'qb-gangmenu:client:OpenMenu',
                                icon = 'fas fa-sign-in-alt',
                                label = Lang:t('targetgang.label'),
                                canInteract = function(entity, distance, data)
                                    local pData = QBCore.Functions.GetPlayerData()
                                    local currentGang = pData and pData.gang
                                    local currentGangName = currentGang and currentGang.name or "nil"
                                    local currentGangBoss = currentGang and currentGang.isboss or false
                                    print(("[qb-management] Target hover debug -> Required Gang: %s | Player Gang: %s | Is Boss: %s"):format(gang, currentGangName, tostring(currentGangBoss)))
                                    return gang == currentGangName and not not currentGangBoss
                                end,
                            },
                        },
                        distance = 2.5
                    })
                end
            end
        end

        -- 1. Custom Cartel Member HQ Zone (Entrance door)
        exports['qb-target']:AddCircleZone('cartel_hq_member', vector3(1395.80, 1141.74, 115.24), 1.2, {
            name = 'cartel_hq_member',
            debugPoly = false,
            useZ = true
        }, {
            options = {
                {
                    type = 'client',
                    event = 'qb-gangmenu:client:OpenMemberMenu',
                    icon = 'fas fa-door-open',
                    label = "打开个人更衣与储物",
                    canInteract = function(entity, distance, data)
                        local pData = QBCore.Functions.GetPlayerData()
                        local currentGang = pData and pData.gang
                        return currentGang and currentGang.name == 'cartel'
                    end,
                },
            },
            distance = 2.5
        })

        -- 2. Custom Cartel Boss Office Zone (Inside suite office)
        exports['qb-target']:AddCircleZone('cartel_boss_office', vector3(1407.92, 1141.29, 113.84), 1.2, {
            name = 'cartel_boss_office',
            debugPoly = false,
            useZ = true
        }, {
            options = {
                {
                    type = 'client',
                    event = 'qb-gangmenu:client:OpenMenu',
                    icon = 'fas fa-crown',
                    label = "打开首脑控制台",
                    canInteract = function(entity, distance, data)
                        local pData = QBCore.Functions.GetPlayerData()
                        local currentGang = pData and pData.gang
                        return currentGang and currentGang.name == 'cartel' and not not currentGang.isboss
                    end,
                },
            },
            distance = 2.5
        })
    else
        while true do
            local wait = 2500
            local pos = GetEntityCoords(PlayerPedId())
            local inRangeGang = false
            local nearGangmenu = false
            if not PlayerGang or not PlayerGang.name then
                local pData = QBCore.Functions.GetPlayerData()
                if pData and pData.gang then
                    PlayerGang = pData.gang
                end
            end
            if PlayerGang then
                wait = 0
                for k, menus in pairs(Config.GangMenus) do
                    for _, coords in ipairs(menus) do
                        local currentGang = PlayerGang
                        if k == currentGang.name and currentGang.isboss then
                            if #(pos - coords) < 5.0 then
                                inRangeGang = true
                                if #(pos - coords) <= 1.5 then
                                    nearGangmenu = true
                                    if not shownGangMenu then
                                        exports['qb-core']:DrawText(Lang:t('drawtextgang.label'), 'left')
                                        shownGangMenu = true
                                    end

                                    if IsControlJustReleased(0, 38) then
                                        exports['qb-core']:HideText()
                                        TriggerEvent('qb-gangmenu:client:OpenMenu')
                                    end
                                end

                                if not nearGangmenu and shownGangMenu then
                                    CloseMenuFullGang()
                                    shownGangMenu = false
                                end
                            end
                        end
                    end
                end
                if not inRangeGang then
                    Wait(1500)
                    if shownGangMenu then
                        CloseMenuFullGang()
                        shownGangMenu = false
                    end
                end
            end
            Wait(wait)
        end
    end
end)
