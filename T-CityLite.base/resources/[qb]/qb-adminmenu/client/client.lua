local developermode = false
local showCoords = false
local vehicleDevMode = false
local menuLocation = 'topright' -- e.g. topright (default), topleft, bottomright, bottomleft

local CUSTOM_MENU_RESOURCE = 'custom-menu'
local customMenuHandlers = {}
local legacyBridges = {}

local function getCustomMenuApi()
    if type(GetResourceState) == 'function' and GetResourceState(CUSTOM_MENU_RESOURCE) ~= 'started' then
        return nil
    end
    local ok, api = pcall(function()
        return exports[CUSTOM_MENU_RESOURCE]
    end)
    if ok and api then
        return api
    end
    return nil
end

local function ensureCustomMenuIntents()
    local api = getCustomMenuApi()
    if not api or type(api.RegisterIntent) ~= 'function' then
        return false
    end
    for _, intentId in ipairs(AdminMenuSpecs.INTENTS) do
        local route = {
            type = 'resource',
            resource = AdminMenuSpecs.RESOURCE,
            method = AdminMenuSpecs.EXPORT_METHOD,
        }
        local ok, regOk = pcall(api.RegisterIntent, api, intentId, route)
        if not ok or regOk == false then
            return false
        end
    end
    return true
end

local function isCustomMenuOpen()
    local api = getCustomMenuApi()
    if not api or type(api.IsOpen) ~= 'function' then
        return false
    end
    local ok, open = pcall(api.IsOpen, api)
    return ok and open == true
end

local function closeCustomMenu(reason)
    local api = getCustomMenuApi()
    if not api or type(api.Close) ~= 'function' then
        return false
    end
    local ok, closed = pcall(api.Close, api, reason or 'qb_adminmenu_close')
    return ok and closed == true
end

local function openCustomMenu(spec)
    local api = getCustomMenuApi()
    if not api or type(api.Open) ~= 'function' then
        return false, 'custom_menu_unavailable'
    end
    ensureCustomMenuIntents()
    local okCall, opened, err = pcall(api.Open, api, spec, {
        knownIntents = AdminMenuSpecs.KnownIntents(),
    })
    if not okCall then
        return false, tostring(opened)
    end
    if not opened then
        if err == 'custom_ui_taken' and QBCore and QBCore.Functions and QBCore.Functions.Notify then
            QBCore.Functions.Notify('Close the active UI before opening Admin Menu', 'error')
        end
        return false, err
    end
    return true, nil
end

local function dispatchAdminMenuIntent(intent, ctx)
    local handler = customMenuHandlers[intent]
    if handler then
        return handler(ctx or {})
    end
    local legacy = legacyBridges[intent]
    if legacy then
        closeCustomMenu('to_legacy_screen')
        legacy(ctx or {})
        return { ok = true, dispatched = 'legacy_menuv' }
    end
    return { ok = false, reason = 'unhandled_intent' }
end

if type(exports) == 'function' then
    exports(AdminMenuSpecs.EXPORT_METHOD, dispatchAdminMenuIntent)
end

-- Main Menus (pending per-screen migration)
local menu6 = MenuV:CreateMenu(false, Lang:t('menu.dealer_list'), menuLocation, 220, 20, 60, 'size-125', 'none', 'menuv', 'test6')
local menu7 = MenuV:CreateMenu(false, Lang:t('menu.developer_options'), menuLocation, 220, 20, 60, 'size-125', 'none', 'menuv', 'test7')

--Sub Menus
local menu14 = MenuV:CreateMenu(false, Lang:t('menu.entity_view_options'), menuLocation, 220, 20, 60, 'size-125', 'none', 'menuv', 'test14')

local toggleState = {
    noclip = false,
    invisible = false,
    godmode = false,
    godmodeLoop = false,
    names = false,
    blips = false,
}
local toggleOptionHandlers = {}

local function resolveNextBool(current, ctx)
    if ctx and type(ctx.values) == 'table' and type(ctx.values.checked) == 'boolean' then
        return ctx.values.checked
    end
    return not current
end

customMenuHandlers['adminmenu:open:menu1'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu1(Lang) }
end

customMenuHandlers['adminmenu:open:menu2'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu2(Lang, toggleState) }
end

customMenuHandlers['adminmenu:action:toggle_option'] = function(ctx)
    local option = type(ctx.args) == 'table' and ctx.args.option or nil
    local fn = option and toggleOptionHandlers[option] or nil
    if not fn then
        return { ok = false, reason = 'unknown_toggle_option' }
    end
    fn(ctx)
    return { ok = true, dispatched = 'toggle', option = option }
end

customMenuHandlers['adminmenu:action:revive_self'] = function()
    TriggerEvent('hospital:client:Revive', PlayerPedId())
    return { ok = true, dispatched = 'revive_self' }
end

customMenuHandlers['adminmenu:open:menu15'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu15(Lang) }
end

customMenuHandlers['adminmenu:action:give_weapon'] = function(ctx)
    local weaponName = type(ctx.args) == 'table' and ctx.args.weapon or nil
    if type(weaponName) ~= 'string' or #weaponName == 0 then
        return { ok = false, reason = 'missing_weapon' }
    end
    TriggerServerEvent('qb-admin:giveWeapon', weaponName)
    QBCore.Functions.Notify(Lang:t('success.spawn_weapon'))
    return { ok = true, dispatched = 'give_weapon' }
end

customMenuHandlers['adminmenu:open:menu3'] = function()
    local hour = type(GetClockHours) == 'function' and GetClockHours() or 12
    return { ok = true, spec = AdminMenuSpecs.BuildMenu3(Lang, hour) }
end

customMenuHandlers['adminmenu:open:menu3_time'] = function()
    local hour = type(GetClockHours) == 'function' and GetClockHours() or 12
    return { ok = true, spec = AdminMenuSpecs.BuildMenu3Time(Lang, hour) }
end

customMenuHandlers['adminmenu:open:menu8'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu8(Lang) }
end

customMenuHandlers['adminmenu:action:set_weather'] = function(ctx)
    local args = type(ctx.args) == 'table' and ctx.args or {}
    if type(args.value) ~= 'string' or #args.value == 0 then
        return { ok = false, reason = 'missing_weather' }
    end
    TriggerServerEvent('qb-weathersync:server:setWeather', args.value)
    QBCore.Functions.Notify(Lang:t('weather.weather_changed', { value = args.label or args.value }))
    return { ok = true, dispatched = 'set_weather', weather = args.value }
end

customMenuHandlers['adminmenu:action:set_time'] = function(ctx)
    local rawVal = type(ctx.values) == 'table' and ctx.values.value or nil
    local hr = tonumber(rawVal)
    if not hr then
        return { ok = false, reason = 'invalid_hour' }
    end
    hr = math.floor(hr + 0.5)
    if hr < 0 then hr = 0 elseif hr > 23 then hr = 23 end
    local timeStr = ('%02d'):format(hr)
    TriggerServerEvent('qb-weathersync:server:setTime', timeStr, timeStr)
    QBCore.Functions.Notify(Lang:t('time.changed', { time = timeStr }))
    return { ok = true, dispatched = 'set_time', hour = timeStr }
end

local playersByKey = {}
local activePlayer = nil
local pendingBan = nil
local pendingPermsGroup = nil

local function runSyncOrAsyncCallback(cbName, args, buildSpecFn)
    local resolvedSpec = nil
    local callbackExited = false
    local function handleResult(...)
        local spec, ok = buildSpecFn(...)
        if ok == false then
            if not callbackExited then
                resolvedSpec = false
            else
                closeCustomMenu('callback_denied')
            end
            return
        end
        if not callbackExited then
            resolvedSpec = spec
        elseif isCustomMenuOpen() then
            openCustomMenu(spec)
        end
    end

    if args ~= nil then
        QBCore.Functions.TriggerCallback(cbName, handleResult, args)
    else
        QBCore.Functions.TriggerCallback(cbName, handleResult)
    end
    callbackExited = true

    if resolvedSpec == false then
        return { ok = false, reason = 'callback_denied' }
    end
    if resolvedSpec then
        return { ok = true, spec = resolvedSpec }
    end
    return { ok = true, dispatched = 'async_pending' }
end

customMenuHandlers['adminmenu:open:menu4'] = function()
    return runSyncOrAsyncCallback('test:getplayers', nil, function(players)
        playersByKey = {}
        for idx, v in pairs(players or {}) do
            if type(v) == 'table' then
                local key = tostring(v.id or idx)
                playersByKey[key] = v
            end
        end
        return AdminMenuSpecs.BuildMenu4(Lang, players), true
    end)
end

customMenuHandlers['adminmenu:open:player'] = function(ctx)
    local key = type(ctx.args) == 'table' and ctx.args.playerKey or nil
    if key ~= nil then
        local selected = playersByKey[tostring(key)]
        if not selected then
            return { ok = false, reason = 'player_not_found' }
        end
        activePlayer = selected
    end
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    return { ok = true, spec = AdminMenuSpecs.BuildPlayerMenu(Lang, activePlayer) }
end

customMenuHandlers['adminmenu:action:player_action'] = function(ctx)
    local act = type(ctx.args) == 'table' and ctx.args.action or nil
    if type(act) ~= 'string' or #act == 0 or not activePlayer then
        return { ok = false, reason = 'missing_player_action' }
    end
    TriggerServerEvent('qb-admin:server:' .. act, activePlayer)
    return { ok = true, dispatched = 'player_action', action = act }
end

customMenuHandlers['adminmenu:open:menu10'] = function()
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    return { ok = true, spec = AdminMenuSpecs.BuildMenu10(Lang, activePlayer) }
end

customMenuHandlers['adminmenu:action:kick_submit'] = function(ctx)
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    local rawReason = type(ctx.values) == 'table' and ctx.values.reason or ''
    local reason = tostring(rawReason):match('^%s*(.-)%s*$')
    if #reason == 0 or reason == 'Unknown' then
        QBCore.Functions.Notify(Lang:t('error.missing_reason'), 'error')
        return { ok = false, reason = 'missing_reason' }
    end
    TriggerServerEvent('qb-admin:server:kick', activePlayer, reason)
    closeCustomMenu('kick_submitted')
    return { ok = true, dispatched = 'kick' }
end

customMenuHandlers['adminmenu:open:menu9'] = function()
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    pendingBan = nil
    return { ok = true, spec = AdminMenuSpecs.BuildMenu9(Lang, activePlayer) }
end

customMenuHandlers['adminmenu:open:menu9_form'] = function(ctx)
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    local args = type(ctx.args) == 'table' and ctx.args or {}
    pendingBan = {
        custom = args.custom == true,
        length = args.length,
        label = args.label,
    }
    return { ok = true, spec = AdminMenuSpecs.BuildMenu9Form(Lang, activePlayer, pendingBan) }
end

customMenuHandlers['adminmenu:action:ban_submit'] = function(ctx)
    if not activePlayer or not pendingBan then
        return { ok = false, reason = 'no_active_ban_target' }
    end
    local values = type(ctx.values) == 'table' and ctx.values or {}
    local reason = tostring(values.reason or ''):match('^%s*(.-)%s*$')
    local banLength = pendingBan.custom and tonumber(values.length) or pendingBan.length
    if #reason == 0 or reason == 'Unknown' or banLength == nil or (type(banLength) == 'number' and banLength <= 0) then
        QBCore.Functions.Notify(Lang:t('error.invalid_reason_length_ban'), 'error')
        return { ok = false, reason = 'invalid_ban_input' }
    end
    TriggerServerEvent('qb-admin:server:ban', activePlayer, banLength, reason)
    pendingBan = nil
    closeCustomMenu('ban_submitted')
    return { ok = true, dispatched = 'ban' }
end

customMenuHandlers['adminmenu:open:menu11'] = function()
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    return runSyncOrAsyncCallback('qb-admin:server:getrank', nil, function(rank)
        if not rank then
            return nil, false
        end
        pendingPermsGroup = nil
        return AdminMenuSpecs.BuildMenu11(Lang, activePlayer), true
    end)
end

customMenuHandlers['adminmenu:open:menu11_confirm'] = function(ctx)
    if not activePlayer then
        return { ok = false, reason = 'no_active_player' }
    end
    local args = type(ctx.args) == 'table' and ctx.args or {}
    if type(args.rank) ~= 'string' or #args.rank == 0 then
        return { ok = false, reason = 'missing_rank' }
    end
    pendingPermsGroup = { { rank = args.rank, label = args.label or args.rank } }
    return { ok = true, spec = AdminMenuSpecs.BuildMenu11Confirm(Lang, activePlayer, args) }
end

customMenuHandlers['adminmenu:action:perms_confirm'] = function()
    if not activePlayer or type(pendingPermsGroup) ~= 'table' then
        QBCore.Functions.Notify(Lang:t('error.changed_perm_failed'), 'error')
        return { ok = false, reason = 'missing_perm_group' }
    end
    TriggerServerEvent('qb-admin:server:setPermissions', activePlayer.id, pendingPermsGroup)
    QBCore.Functions.Notify(Lang:t('success.changed_perm'), 'success')
    pendingPermsGroup = nil
    return { ok = true, dispatched = 'set_permissions' }
end

customMenuHandlers['adminmenu:open:menu5'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu5(Lang) }
end

customMenuHandlers['adminmenu:open:menu12'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu12(Lang, QBCore and QBCore.Shared) }
end

customMenuHandlers['adminmenu:open:menu13'] = function(ctx)
    local catName = type(ctx.args) == 'table' and ctx.args.category or nil
    if type(catName) ~= 'string' or #catName == 0 then
        return { ok = false, reason = 'missing_vehicle_category' }
    end
    return { ok = true, spec = AdminMenuSpecs.BuildMenu13(Lang, catName, QBCore and QBCore.Shared) }
end

customMenuHandlers['adminmenu:action:veh_command'] = function(ctx)
    local args = type(ctx.args) == 'table' and ctx.args or {}
    local cmd = args.cmd
    if type(cmd) ~= 'string' or #cmd == 0 then
        return { ok = false, reason = 'missing_veh_command' }
    end
    if cmd == 'car' then
        if type(args.model) ~= 'string' or #args.model == 0 then
            return { ok = false, reason = 'missing_vehicle_model' }
        end
        TriggerServerEvent('QBCore:CallCommand', 'car', { args.model })
    else
        TriggerServerEvent('QBCore:CallCommand', cmd, {})
    end
    return { ok = true, dispatched = 'veh_command', cmd = cmd }
end

legacyBridges['adminmenu:open:menu7'] = function() AdminMenuShim.OpenMenu(menu7) end

RegisterNetEvent('qb-admin:client:openMenu', function()
    openCustomMenu(AdminMenuSpecs.BuildMenu1(Lang))
end)

--[[
    Sub Menus for the above main menu's
--]]

-- Developer Options Menu Buttons
local menu7_dev_copy_vec3 = menu7:AddButton({
    icon = '📋',
    label = Lang:t('menu.copy_vector3'),
    value = 'coords',
    description = Lang:t('desc.vector3_desc')
})

local menu7_dev_copy_vec4 = menu7:AddButton({
    icon = '📋',
    label = Lang:t('menu.copy_vector4'),
    value = 'coords',
    description = Lang:t('desc.vector4_desc')
})

local menu7_dev_copy_heading = menu7:AddButton({
    icon = '📋',
    label = Lang:t('menu.copy_heading'),
    value = 'heading',
    description = Lang:t('desc.copy_heading_desc')
})

local menu7_dev_toggle_coords = menu7:AddCheckbox({
    icon = '📍',
    label = Lang:t('menu.display_coords'),
    value = nil,
    description = Lang:t('desc.display_coords_desc')
})

local menu7_dev_vehicle_mode = menu7:AddCheckbox({
    icon = '🚘',
    label = Lang:t('menu.vehicle_dev_mode'),
    value = nil,
    description = Lang:t('desc.vehicle_dev_mode_desc')
})

local menu7_dev_info_mode = menu7:AddCheckbox({
    icon = '⚫',
    label = Lang:t('menu.hud_dev_mode'),
    value = nil,
    description = Lang:t('desc.hud_dev_mode_desc')
})

local menu7_dev_noclip = menu7:AddCheckbox({
    icon = '🎥',
    label = Lang:t('menu.noclip'),
    value = nil,
    description = Lang:t('desc.noclip_desc')
})

--create dev entity view
menu7:AddButton({
    icon = '🔍',
    label = Lang:t('menu.entity_view_options'),
    value = menu14,
    description = Lang:t('desc.entity_view_desc')
})

--[[
    QB Core Admin Menu button functions below.
--]]

--[[
    General Functions
--]]
local function LocalInput(text, number, windows)
    AddTextEntry('FMMC_MPM_NA', text)
    DisplayOnscreenKeyboard(1, 'FMMC_MPM_NA', '', windows or '', '', '', '', number or 30)
    while (UpdateOnscreenKeyboard() == 0) do
        DisableAllControlActions(0)
        Wait(0)
    end

    if (GetOnscreenKeyboardResult()) then
        local result = GetOnscreenKeyboardResult()
        return result
    end
end

local function LocalInputInt(text, number, windows)
    AddTextEntry('FMMC_MPM_NA', text)
    DisplayOnscreenKeyboard(1, 'FMMC_MPM_NA', '', windows or '', '', '', '', number or 30)
    while (UpdateOnscreenKeyboard() == 0) do
        DisableAllControlActions(0)
        Wait(0)
    end
    if (GetOnscreenKeyboardResult()) then
        local result = GetOnscreenKeyboardResult()
        return tonumber(result)
    end
end

--[[
    Admin Options functions
--]]
AddEventHandler('qb-admin:client:toggleNames', function()
    toggleState.names = not toggleState.names
end)

AddEventHandler('qb-admin:client:toggleBlips', function()
    toggleState.blips = not toggleState.blips
end)

AddEventHandler('qb-admin:client:ToggleNoClip', function()
    toggleState.noclip = not toggleState.noclip
end)

toggleOptionHandlers.names = function(ctx)
    local nextVal = resolveNextBool(toggleState.names, ctx)
    if nextVal ~= toggleState.names then
        TriggerEvent('qb-admin:client:toggleNames')
    end
end

toggleOptionHandlers.blips = function(ctx)
    local nextVal = resolveNextBool(toggleState.blips, ctx)
    if nextVal ~= toggleState.blips then
        TriggerEvent('qb-admin:client:toggleBlips')
    end
end

toggleOptionHandlers.noclip = function(ctx)
    local nextVal = resolveNextBool(toggleState.noclip, ctx)
    if nextVal ~= toggleState.noclip then
        toggleState.noclip = nextVal
        ToggleNoClip()
    end
end

toggleOptionHandlers.invisible = function(ctx)
    local nextVal = resolveNextBool(toggleState.invisible, ctx)
    toggleState.invisible = nextVal
    SetEntityVisible(PlayerPedId(), not toggleState.invisible, 0)
end

toggleOptionHandlers.godmode = function(ctx)
    local nextVal = resolveNextBool(toggleState.godmode, ctx)
    toggleState.godmode = nextVal
    if toggleState.godmode and not toggleState.godmodeLoop then
        toggleState.godmodeLoop = true
        CreateThread(function()
            while toggleState.godmode do
                Wait(0)
                SetPlayerInvincible(PlayerId(), true)
            end
            SetPlayerInvincible(PlayerId(), false)
            toggleState.godmodeLoop = false
        end)
    elseif not toggleState.godmode then
        SetPlayerInvincible(PlayerId(), false)
    end
end

-- Player Management Options functions
-- Player Management migrated to custom-menu (menu4 / Players / menu9 / menu10 / menu11).


--[[
    Server Options functions
--]]

-- Server Options migrated to custom-menu (menu3 / menu8).

--[[
    Vehicle Spawner functions
--]]

-- Vehicle Spawner migrated to custom-menu (menu5 / menu12 / menu13).

--[[
    Developer Options functions
--]]
local entity_view_distance = menu14:AddSlider({
    icon = '📏',
    label = Lang:t('menu.entity_view_distance'),
    value = GetCurrentEntityViewDistance(),
    values = { {
        label = '5',
        value = '5',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '10',
        value = '10',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '15',
        value = '15',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '20',
        value = '20',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '25',
        value = '25',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '30',
        value = '30',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '35',
        value = '35',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '40',
        value = '40',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '45',
        value = '45',
        description = Lang:t('menu.entity_view_distance')
    }, {
        label = '50',
        value = '50',
        description = Lang:t('menu.entity_view_distance')
    } }
})

local entity_view_copy_info = menu14:AddButton({
    icon = '📋',
    label = Lang:t('menu.entity_view_freeaim_copy'),
    value = 'freeaimEntity',
    description = Lang:t('desc.entity_view_freeaim_copy_desc')
})

local entity_view_freeaim = menu14:AddCheckbox({
    icon = '🔫',
    label = Lang:t('menu.entity_view_freeaim'),
    value = nil,
    description = Lang:t('desc.entity_view_freeaim_desc')
})

local entity_view_vehicle = menu14:AddCheckbox({
    icon = '🚗',
    label = Lang:t('menu.entity_view_vehicles'),
    value = nil,
    description = Lang:t('desc.entity_view_vehicles_desc')
})

local entity_view_ped = menu14:AddCheckbox({
    icon = '🧍‍♂‍',
    label = Lang:t('menu.entity_view_peds'),
    value = nil,
    description = Lang:t('desc.entity_view_peds_desc')
})

local entity_view_object = menu14:AddCheckbox({
    icon = '📦',
    label = Lang:t('menu.entity_view_objects'),
    value = nil,
    description = Lang:t('desc.entity_view_objects_desc')
})

menu7_dev_info_mode:On('change', function(_, _, _)
    developermode = not developermode
    TriggerEvent('qb-admin:client:ToggleDevmode')
    if developermode then
        SetPlayerInvincible(PlayerId(), true)
    else
        SetPlayerInvincible(PlayerId(), false)
    end
end)

entity_view_freeaim:On('change', function(_, _, _)
    ToggleEntityFreeView()
end)

local function CopyToClipboard(dataType)
    local ped = PlayerPedId()
    if dataType == 'coords2' then
        local coords = GetEntityCoords(ped)
        local x = QBCore.Shared.Round(coords.x, 2)
        local y = QBCore.Shared.Round(coords.y, 2)
        SendNUIMessage({
            string = string.format('vector2(%s, %s)', x, y)
        })
        QBCore.Functions.Notify(Lang:t('success.coords_copied'), 'success')
    elseif dataType == 'coords3' then
        local coords = GetEntityCoords(ped)
        local x = QBCore.Shared.Round(coords.x, 2)
        local y = QBCore.Shared.Round(coords.y, 2)
        local z = QBCore.Shared.Round(coords.z, 2)
        SendNUIMessage({
            string = string.format('vector3(%s, %s, %s)', x, y, z)
        })
        QBCore.Functions.Notify(Lang:t('success.coords_copied'), 'success')
    elseif dataType == 'coords4' then
        local coords = GetEntityCoords(ped)
        local x = QBCore.Shared.Round(coords.x, 2)
        local y = QBCore.Shared.Round(coords.y, 2)
        local z = QBCore.Shared.Round(coords.z, 2)
        local heading = GetEntityHeading(ped)
        local h = QBCore.Shared.Round(heading, 2)
        SendNUIMessage({
            string = string.format('vector4(%s, %s, %s, %s)', x, y, z, h)
        })
        QBCore.Functions.Notify(Lang:t('success.coords_copied'), 'success')
    elseif dataType == 'heading' then
        local heading = GetEntityHeading(ped)
        local h = QBCore.Shared.Round(heading, 2)
        SendNUIMessage({
            string = h
        })
        QBCore.Functions.Notify(Lang:t('success.heading_copied'), 'success')
    elseif dataType == 'freeaimEntity' then
        local entity = GetFreeAimEntity()

        if entity then
            local entityHash = GetEntityModel(entity)
            local entityName = Entities[entityHash] or 'Unknown'
            local entityCoords = GetEntityCoords(entity)
            local entityHeading = GetEntityHeading(entity)
            local entityRotation = GetEntityRotation(entity)
            local x = QBCore.Shared.Round(entityCoords.x, 2)
            local y = QBCore.Shared.Round(entityCoords.y, 2)
            local z = QBCore.Shared.Round(entityCoords.z, 2)
            local rotX = QBCore.Shared.Round(entityRotation.x, 2)
            local rotY = QBCore.Shared.Round(entityRotation.y, 2)
            local rotZ = QBCore.Shared.Round(entityRotation.z, 2)
            local h = QBCore.Shared.Round(entityHeading, 2)
            SendNUIMessage({
                string = string.format('Model Name:\t%s\nModel Hash:\t%s\n\nHeading:\t%s\nCoords:\t\tvector3(%s, %s, %s)\nRotation:\tvector3(%s, %s, %s)', entityName, entityHash, h, x, y, z, rotX, rotY, rotZ)
            })
            QBCore.Functions.Notify(Lang:t('success.entity_copy'), 'success')
        else
            QBCore.Functions.Notify(Lang:t('error.failed_entity_copy'), 'error')
        end
    end
end

RegisterNetEvent('qb-admin:client:copyToClipboard', function(dataType)
    CopyToClipboard(dataType)
end)

local function Draw2DText(content, font, colour, scale, x, y)
    SetTextFont(font)
    SetTextScale(scale, scale)
    SetTextColour(colour[1], colour[2], colour[3], 255)
    BeginTextCommandDisplayText('STRING')
    SetTextDropShadow(0, 0, 0, 0, 255)
    SetTextDropShadow()
    SetTextEdge(4, 0, 0, 0, 255)
    SetTextOutline()
    AddTextComponentSubstringPlayerName(content)
    EndTextCommandDisplayText(x, y)
end

local function ToggleShowCoordinates()
    local x = 0.4
    local y = 0.025
    showCoords = not showCoords
    CreateThread(function()
        while showCoords do
            local coords = GetEntityCoords(PlayerPedId())
            local heading = GetEntityHeading(PlayerPedId())
            local c = {}
            c.x = QBCore.Shared.Round(coords.x, 2)
            c.y = QBCore.Shared.Round(coords.y, 2)
            c.z = QBCore.Shared.Round(coords.z, 2)
            heading = QBCore.Shared.Round(heading, 2)
            Wait(0)
            Draw2DText(string.format('~w~' .. Lang:t('info.ped_coords') .. '~b~ vector4(~w~%s~b~, ~w~%s~b~, ~w~%s~b~, ~w~%s~b~)', c.x, c.y, c.z, heading), 4, { 66, 182, 245 }, 0.4, x + 0.0, y + 0.0)
        end
    end)
end

local function ToggleVehicleDeveloperMode()
    local x = 0.4
    local y = 0.888
    vehicleDevMode = not vehicleDevMode
    CreateThread(function()
        while vehicleDevMode do
            local ped = PlayerPedId()
            Wait(0)
            if IsPedInAnyVehicle(ped, false) then
                local vehicle = GetVehiclePedIsIn(ped, false)
                local netID = VehToNet(vehicle)
                local hash = GetEntityModel(vehicle)
                local modelName = GetLabelText(GetDisplayNameFromVehicleModel(hash))
                local eHealth = GetVehicleEngineHealth(vehicle)
                local bHealth = GetVehicleBodyHealth(vehicle)
                Draw2DText(Lang:t('info.vehicle_dev_data'), 4, { 66, 182, 245 }, 0.4, x + 0.0, y + 0.0)
                Draw2DText(string.format(Lang:t('info.ent_id') .. '~b~%s~s~ | ' .. Lang:t('info.net_id') .. '~b~%s~s~', vehicle, netID), 4, { 255, 255, 255 }, 0.4, x + 0.0, y + 0.025)
                Draw2DText(string.format(Lang:t('info.model') .. '~b~%s~s~ | ' .. Lang:t('info.hash') .. '~b~%s~s~', modelName, hash), 4, { 255, 255, 255 }, 0.4, x + 0.0, y + 0.050)
                Draw2DText(string.format(Lang:t('info.eng_health') .. '~b~%s~s~ | ' .. Lang:t('info.body_health') .. '~b~%s~s~', QBCore.Shared.Round(eHealth, 2), QBCore.Shared.Round(bHealth, 2)), 4, { 255, 255, 255 }, 0.4, x + 0.0, y + 0.075)
            end
        end
    end)
end

RegisterNetEvent('qb-admin:client:ToggleCoords', function()
    ToggleShowCoordinates()
end)

menu7_dev_copy_vec3:On('select', function()
    CopyToClipboard('coords3')
end)

menu7_dev_copy_vec4:On('select', function()
    CopyToClipboard('coords4')
end)

menu7_dev_copy_heading:On('select', function()
    CopyToClipboard('heading')
end)

entity_view_copy_info:On('select', function()
    CopyToClipboard('freeaimEntity')
end)

menu7_dev_vehicle_mode:On('change', function()
    ToggleVehicleDeveloperMode()
end)

menu7_dev_noclip:On('change', function(_, _, _)
    ToggleNoClip()
end)

menu7_dev_toggle_coords:On('change', function()
    ToggleShowCoordinates()
end)

entity_view_distance:On('select', function(_, value)
    SetEntityViewDistance(value)
    QBCore.Functions.Notify(Lang:t('info.entity_view_distance', { distance = value }))
end)

entity_view_vehicle:On('change', function()
    ToggleEntityVehicleView()
end)

entity_view_object:On('change', function()
    ToggleEntityObjectView()
end)

entity_view_ped:On('change', function()
    ToggleEntityPedView()
end)

--[[
    Dealer List
--]]
local function OpenDealerMenu(dealer)
    local EditDealer = MenuV:CreateMenu(false, Lang:t('menu.edit_dealer') .. dealer['name'], menuLocation, 220, 20, 60, 'size-125', 'none', 'menuv')
    EditDealer:ClearItems()
    AdminMenuShim.OpenMenu(EditDealer)
    local elements = {
        [1] = {
            icon = '➡️',
            label = Lang:t('info.go_to') .. ' ' .. dealer['name'],
            value = 'goto',
            description = Lang:t('desc.dealergoto_desc') .. ' ' .. dealer['name']
        },
        [2] = {
            icon = '☠',
            label = Lang:t('info.remove') .. ' ' .. dealer['name'],
            value = 'remove',
            description = Lang:t('desc.dealerremove_desc') .. ' ' .. dealer['name']
        }
    }
    for _, v in ipairs(elements) do
        EditDealer:AddButton({
            icon = v.icon,
            label = ' ' .. v.label,
            value = v.value,
            description = v.description,
            select = function(btn)
                local values = btn.Value
                if values == 'goto' then
                    TriggerServerEvent('QBCore:CallCommand', 'dealergoto', { dealer['name'] })
                elseif values == 'remove' then
                    TriggerServerEvent('QBCore:CallCommand', 'deletedealer', { dealer['name'] })
                    EditDealer:Close()
                    menu6:Close()
                end
            end
        })
    end
end

legacyBridges['adminmenu:open:menu6'] = function()
    menu6:ClearItems()
    QBCore.Functions.TriggerCallback('test:getdealers', function(dealers)
        for _, v in pairs(dealers) do
            menu6:AddButton({
                label = v['name'],
                value = v,
                description = Lang:t('menu.dealer_name'),
                select = function(btn)
                    local select = btn.Value
                    OpenDealerMenu(select)
                end
            })
        end
    end)
    AdminMenuShim.OpenMenu(menu6)
end
