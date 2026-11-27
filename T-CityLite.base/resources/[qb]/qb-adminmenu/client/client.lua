local developermode = false
local showCoords = false
local vehicleDevMode = false
local menuLocation = 'topright' -- e.g. topright (default), topleft, bottomright, bottomleft

local CUSTOM_MENU_RESOURCE = 'custom-menu'
local customMenuHandlers = {}

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
    return { ok = false, reason = 'unhandled_intent' }
end

if type(exports) == 'function' then
    exports(AdminMenuSpecs.EXPORT_METHOD, dispatchAdminMenuIntent)
end

local toggleState = {
    noclip = false,
    invisible = false,
    godmode = false,
    godmodeLoop = false,
    names = false,
    blips = false,
    ev_freeaim = false,
    ev_vehicle = false,
    ev_ped = false,
    ev_object = false,
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
local dealersByName = {}
local activeDealer = nil
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

customMenuHandlers['adminmenu:open:menu6'] = function()
    return runSyncOrAsyncCallback('test:getdealers', nil, function(dealers)
        dealersByName = {}
        for _, v in pairs(dealers or {}) do
            if type(v) == 'table' and v['name'] ~= nil then
                dealersByName[tostring(v['name'])] = v
            end
        end
        return AdminMenuSpecs.BuildMenu6(Lang, dealers), true
    end)
end

customMenuHandlers['adminmenu:open:dealer'] = function(ctx)
    local name = type(ctx.args) == 'table' and ctx.args.dealerName or nil
    if name ~= nil then
        local selected = dealersByName[tostring(name)]
        if not selected then
            return { ok = false, reason = 'dealer_not_found' }
        end
        activeDealer = selected
    end
    if not activeDealer then
        return { ok = false, reason = 'no_active_dealer' }
    end
    return { ok = true, spec = AdminMenuSpecs.BuildDealerMenu(Lang, activeDealer) }
end

customMenuHandlers['adminmenu:open:dealer_delete_confirm'] = function()
    if not activeDealer then
        return { ok = false, reason = 'no_active_dealer' }
    end
    return { ok = true, spec = AdminMenuSpecs.BuildDealerDeleteConfirm(Lang, activeDealer) }
end

customMenuHandlers['adminmenu:action:dealer_goto'] = function()
    if not activeDealer then
        return { ok = false, reason = 'no_active_dealer' }
    end
    TriggerServerEvent('QBCore:CallCommand', 'dealergoto', { activeDealer['name'] })
    return { ok = true, dispatched = 'dealer_goto' }
end

customMenuHandlers['adminmenu:action:dealer_delete'] = function()
    if not activeDealer then
        return { ok = false, reason = 'no_active_dealer' }
    end
    TriggerServerEvent('QBCore:CallCommand', 'deletedealer', { activeDealer['name'] })
    activeDealer = nil
    closeCustomMenu('dealer_deleted')
    return { ok = true, dispatched = 'dealer_delete' }
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

customMenuHandlers['adminmenu:open:menu7'] = function()
    return {
        ok = true,
        spec = AdminMenuSpecs.BuildMenu7(Lang, {
            coords = showCoords,
            veh_dev = vehicleDevMode,
            hud_dev = developermode,
            noclip = toggleState.noclip,
        }),
    }
end

local function currentEntityDistanceMeters()
    local units = type(GetCurrentEntityViewDistance) == 'function' and GetCurrentEntityViewDistance() or 2
    return (tonumber(units) or 2) * 5
end

customMenuHandlers['adminmenu:open:menu14'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu14(Lang, toggleState, currentEntityDistanceMeters()) }
end

customMenuHandlers['adminmenu:open:menu14_distance'] = function()
    return { ok = true, spec = AdminMenuSpecs.BuildMenu14Distance(Lang, currentEntityDistanceMeters()) }
end

customMenuHandlers['adminmenu:action:set_entity_distance'] = function(ctx)
    local raw = type(ctx.values) == 'table' and ctx.values.value or nil
    local meters = tonumber(raw)
    if not meters then
        return { ok = false, reason = 'invalid_distance' }
    end
    meters = math.floor((meters + 2.5) / 5) * 5
    if meters < 5 then meters = 5 elseif meters > 50 then meters = 50 end
    SetEntityViewDistance(tostring(meters))
    QBCore.Functions.Notify(Lang:t('info.entity_view_distance', { distance = tostring(meters) }))
    return { ok = true, dispatched = 'set_entity_distance', distance = meters }
end

RegisterNetEvent('qb-admin:client:openMenu', function()
    openCustomMenu(AdminMenuSpecs.BuildMenu1(Lang))
end)

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

customMenuHandlers['adminmenu:action:copy'] = function(ctx)
    local dataType = type(ctx.args) == 'table' and ctx.args.dataType or nil
    if type(dataType) ~= 'string' or #dataType == 0 then
        return { ok = false, reason = 'missing_copy_type' }
    end
    CopyToClipboard(dataType)
    return { ok = true, dispatched = 'copy', dataType = dataType }
end

toggleOptionHandlers.coords = function(ctx)
    local nextVal = resolveNextBool(showCoords, ctx)
    if nextVal ~= showCoords then
        ToggleShowCoordinates()
    end
end

toggleOptionHandlers.veh_dev = function(ctx)
    local nextVal = resolveNextBool(vehicleDevMode, ctx)
    if nextVal ~= vehicleDevMode then
        ToggleVehicleDeveloperMode()
    end
end

toggleOptionHandlers.hud_dev = function(ctx)
    local nextVal = resolveNextBool(developermode, ctx)
    if nextVal ~= developermode then
        developermode = nextVal
        TriggerEvent('qb-admin:client:ToggleDevmode')
        SetPlayerInvincible(PlayerId(), developermode == true)
    end
end

toggleOptionHandlers.ev_freeaim = function(ctx)
    local nextVal = resolveNextBool(toggleState.ev_freeaim, ctx)
    if nextVal ~= toggleState.ev_freeaim then
        toggleState.ev_freeaim = nextVal
        ToggleEntityFreeView()
    end
end

toggleOptionHandlers.ev_vehicle = function(ctx)
    local nextVal = resolveNextBool(toggleState.ev_vehicle, ctx)
    if nextVal ~= toggleState.ev_vehicle then
        toggleState.ev_vehicle = nextVal
        ToggleEntityVehicleView()
    end
end

toggleOptionHandlers.ev_object = function(ctx)
    local nextVal = resolveNextBool(toggleState.ev_object, ctx)
    if nextVal ~= toggleState.ev_object then
        toggleState.ev_object = nextVal
        ToggleEntityObjectView()
    end
end

toggleOptionHandlers.ev_ped = function(ctx)
    local nextVal = resolveNextBool(toggleState.ev_ped, ctx)
    if nextVal ~= toggleState.ev_ped then
        toggleState.ev_ped = nextVal
        ToggleEntityPedView()
    end
end

--[[
    Dealer List
--]]
-- Dealer List migrated to custom-menu (menu6 / EditDealer).
