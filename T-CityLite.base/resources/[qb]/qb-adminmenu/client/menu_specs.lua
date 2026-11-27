--[[
    AdminMenuSpecs - Pure MenuSpec builders for qb-adminmenu (M6 #348).
    No runtime side effects on load; all returned tables are JSON-safe for custom-menu.
]]

AdminMenuSpecs = AdminMenuSpecs or {}

AdminMenuSpecs.RESOURCE = 'qb-adminmenu'
AdminMenuSpecs.EXPORT_METHOD = 'AdminMenuIntent'

AdminMenuSpecs.INTENTS = {
    'adminmenu:open:menu1',
    'adminmenu:open:menu2',
    'adminmenu:open:menu15',
    'adminmenu:open:menu3',
    'adminmenu:open:menu8',
    'adminmenu:open:menu3_time',
    'adminmenu:open:menu4',
    'adminmenu:open:player',
    'adminmenu:open:menu9',
    'adminmenu:open:menu9_form',
    'adminmenu:open:menu10',
    'adminmenu:open:menu11',
    'adminmenu:open:menu11_confirm',
    'adminmenu:open:menu5',
    'adminmenu:open:menu12',
    'adminmenu:open:menu13',
    'adminmenu:open:menu6',
    'adminmenu:open:dealer',
    'adminmenu:open:dealer_delete_confirm',
    'adminmenu:open:menu7',
    'adminmenu:open:menu14',
    'adminmenu:open:menu14_distance',
    'adminmenu:action:toggle_option',
    'adminmenu:action:revive_self',
    'adminmenu:action:give_weapon',
    'adminmenu:action:set_weather',
    'adminmenu:action:set_time',
    'adminmenu:action:player_action',
    'adminmenu:action:kick_submit',
    'adminmenu:action:ban_submit',
    'adminmenu:action:perms_confirm',
    'adminmenu:action:veh_command',
    'adminmenu:action:dealer_goto',
    'adminmenu:action:dealer_delete',
    'adminmenu:action:copy',
    'adminmenu:action:set_entity_distance',
}

function AdminMenuSpecs.KnownIntents()
    local known = {}
    for _, id in ipairs(AdminMenuSpecs.INTENTS) do
        known[id] = true
    end
    return known
end

function AdminMenuSpecs.SafeLabel(value, fallback)
    if type(value) == 'string' and #value > 0 then
        return value
    end
    return fallback or 'Item'
end

function AdminMenuSpecs.SafeId(prefix, idx)
    local raw = ('%s_%s'):format(tostring(prefix), tostring(idx))
    if #raw > 64 then
        return string.sub(raw, 1, 64)
    end
    return raw
end

function AdminMenuSpecs.Translate(lang, key, subs)
    if lang and type(lang.t) == 'function' then
        local ok, out = pcall(lang.t, lang, key, subs)
        if ok and type(out) == 'string' and #out > 0 then
            return out
        end
    end
    return tostring(key)
end

function AdminMenuSpecs.BuildMenu1(lang)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local rootLabel = tr('menu.admin_menu')
    return {
        id = 'qb_adminmenu_menu1',
        title = rootLabel,
        surface = 'list',
        breadcrumbs = { rootLabel },
        items = {
            {
                id = 'admin_options',
                kind = 'nav',
                icon = '😃',
                label = tr('menu.admin_options'),
                description = tr('desc.admin_options_desc'),
                intent = 'adminmenu:open:menu2',
            },
            {
                id = 'player_management',
                kind = 'nav',
                icon = '🙍‍♂️',
                label = tr('menu.player_management'),
                description = tr('desc.player_management_desc'),
                intent = 'adminmenu:open:menu4',
            },
            {
                id = 'server_management',
                kind = 'nav',
                icon = '🎮',
                label = tr('menu.server_management'),
                description = tr('desc.server_management_desc'),
                intent = 'adminmenu:open:menu3',
            },
            {
                id = 'vehicles',
                kind = 'nav',
                icon = '🚗',
                label = tr('menu.vehicles'),
                description = tr('desc.vehicles_desc'),
                intent = 'adminmenu:open:menu5',
            },
            {
                id = 'dealer_list',
                kind = 'nav',
                icon = '💊',
                label = tr('menu.dealer_list'),
                description = tr('desc.dealer_desc'),
                intent = 'adminmenu:open:menu6',
            },
            {
                id = 'developer_options',
                kind = 'nav',
                icon = '🔧',
                label = tr('menu.developer_options'),
                description = tr('desc.developer_desc'),
                intent = 'adminmenu:open:menu7',
            },
        },
    }
end

function AdminMenuSpecs.BuildMenu2(lang, state)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local s = state or {}
    return {
        id = 'qb_adminmenu_menu2',
        title = tr('menu.admin_options'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.admin_options') },
        items = {
            {
                id = 'noclip',
                kind = 'toggle',
                icon = '🎥',
                label = tr('menu.noclip'),
                description = tr('desc.noclip_desc'),
                checked = s.noclip == true,
                intent = 'adminmenu:action:toggle_option',
                args = { option = 'noclip' },
            },
            {
                id = 'revive',
                kind = 'action',
                icon = '🏥',
                label = tr('menu.revive'),
                description = tr('desc.revive_desc'),
                intent = 'adminmenu:action:revive_self',
            },
            {
                id = 'invisible',
                kind = 'toggle',
                icon = '👻',
                label = tr('menu.invisible'),
                description = tr('desc.invisible_desc'),
                checked = s.invisible == true,
                intent = 'adminmenu:action:toggle_option',
                args = { option = 'invisible' },
            },
            {
                id = 'godmode',
                kind = 'toggle',
                icon = '⚡',
                label = tr('menu.god'),
                description = tr('desc.god_desc'),
                checked = s.godmode == true,
                intent = 'adminmenu:action:toggle_option',
                args = { option = 'godmode' },
            },
            {
                id = 'names',
                kind = 'toggle',
                icon = '📋',
                label = tr('menu.names'),
                description = tr('desc.names_desc'),
                checked = s.names == true,
                intent = 'adminmenu:action:toggle_option',
                args = { option = 'names' },
            },
            {
                id = 'blips',
                kind = 'toggle',
                icon = '📍',
                label = tr('menu.blips'),
                description = tr('desc.blips_desc'),
                checked = s.blips == true,
                intent = 'adminmenu:action:toggle_option',
                args = { option = 'blips' },
            },
            {
                id = 'spawn_weapons',
                kind = 'nav',
                icon = '🎁',
                label = tr('menu.spawn_weapons'),
                description = tr('desc.spawn_weapons_desc'),
                intent = 'adminmenu:open:menu15',
            },
        },
    }
end

function AdminMenuSpecs.BuildMenu15(lang, weapons)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local src = weapons or (QBCore and QBCore.Shared and QBCore.Shared.Weapons) or {}
    local entries = {}
    for k, v in pairs(src) do
        if type(v) == 'table' then
            local name = v.name or tostring(k)
            local label = AdminMenuSpecs.SafeLabel(v.label, name)
            entries[#entries + 1] = { name = name, label = label }
        end
    end
    table.sort(entries, function(a, b)
        return a.label:lower() < b.label:lower()
    end)

    local items = {}
    local desc = tr('desc.spawn_weapons_desc')
    for idx, entry in ipairs(entries) do
        items[#items + 1] = {
            id = AdminMenuSpecs.SafeId('wep', idx),
            kind = 'action',
            icon = '🎁',
            label = entry.label,
            description = desc,
            intent = 'adminmenu:action:give_weapon',
            args = { weapon = entry.name },
        }
    end

    return {
        id = 'qb_adminmenu_menu15',
        title = tr('menu.spawn_weapons'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.admin_options'), tr('menu.spawn_weapons') },
        emptyMessage = tr('menu.spawn_weapons'),
        items = items,
    }
end

local function clampNumber(value, minVal, maxVal, fallback)
    local n = tonumber(value)
    if not n then
        return fallback
    end
    n = math.floor(n + 0.5)
    if n < minVal then return minVal end
    if n > maxVal then return maxVal end
    return n
end

function AdminMenuSpecs.BuildMenu3(lang, hour)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local hr = clampNumber(hour, 0, 23, 12)
    return {
        id = 'qb_adminmenu_menu3',
        title = tr('menu.manage_server'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.manage_server') },
        items = {
            {
                id = 'weather_options',
                kind = 'nav',
                icon = '🌡️',
                label = tr('menu.weather_options'),
                description = tr('desc.weather_desc'),
                intent = 'adminmenu:open:menu8',
            },
            {
                id = 'server_time',
                kind = 'nav',
                icon = '⏲️',
                label = tr('menu.server_time'),
                description = tr('menu.time'),
                badge = ('%02d:00'):format(hr),
                intent = 'adminmenu:open:menu3_time',
            },
        },
    }
end

function AdminMenuSpecs.BuildMenu3Time(lang, hour)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local hr = clampNumber(hour, 0, 23, 12)
    return {
        id = 'qb_adminmenu_menu3_time',
        title = tr('menu.server_time'),
        surface = 'range',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.manage_server'), tr('menu.server_time') },
        intent = 'adminmenu:action:set_time',
        items = {
            {
                id = 'server_hour',
                kind = 'range',
                label = tr('menu.server_time'),
                description = tr('menu.time'),
                min = 0,
                max = 23,
                step = 1,
                value = hr,
                defaultValue = hr,
                unit = 'h',
                intent = 'adminmenu:action:set_time',
            },
        },
    }
end

return AdminMenuSpecs
