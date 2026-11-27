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

local WEATHER_OPTIONS = {
    { id = 'extrasunny', icon = '☀️', label = 'weather.extra_sunny', value = 'EXTRASUNNY', desc = 'weather.extra_sunny_desc' },
    { id = 'clear', icon = '☀️', label = 'weather.clear', value = 'CLEAR', desc = 'weather.clear_desc' },
    { id = 'neutral', icon = '☀️', label = 'weather.neutral', value = 'NEUTRAL', desc = 'weather.neutral_desc' },
    { id = 'smog', icon = '🌁', label = 'weather.smog', value = 'SMOG', desc = 'weather.smog_desc' },
    { id = 'foggy', icon = '🌫️', label = 'weather.foggy', value = 'FOGGY', desc = 'weather.foggy_desc' },
    { id = 'overcast', icon = '⛅', label = 'weather.overcast', value = 'OVERCAST', desc = 'weather.overcast_desc' },
    { id = 'clouds', icon = '☁️', label = 'weather.clouds', value = 'CLOUDS', desc = 'weather.clouds_desc' },
    { id = 'clearing', icon = '🌤️', label = 'weather.clearing', value = 'CLEARING', desc = 'weather.clearing_desc' },
    { id = 'rain', icon = '☂️', label = 'weather.rain', value = 'RAIN', desc = 'weather.rain_desc' },
    { id = 'thunder', icon = '⛈️', label = 'weather.thunder', value = 'THUNDER', desc = 'weather.thunder_desc' },
    { id = 'snow', icon = '❄️', label = 'weather.snow', value = 'SNOW', desc = 'weather.snow_desc' },
    { id = 'blizzard', icon = '🌨️', label = 'weather.blizzard', value = 'BLIZZARD', desc = 'weather.blizzed_desc' },
    { id = 'snowlight', icon = '❄️', label = 'weather.light_snow', value = 'SNOWLIGHT', desc = 'weather.light_snow_desc' },
    { id = 'xmas', icon = '🌨️', label = 'weather.heavy_snow', value = 'XMAS', desc = 'weather.heavy_snow_desc' },
    { id = 'halloween', icon = '🎃', label = 'weather.halloween', value = 'HALLOWEEN', desc = 'weather.halloween_desc' },
}

function AdminMenuSpecs.BuildMenu8(lang)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local items = {}
    for _, opt in ipairs(WEATHER_OPTIONS) do
        local label = tr(opt.label)
        items[#items + 1] = {
            id = opt.id,
            kind = 'action',
            icon = opt.icon,
            label = label,
            description = tr(opt.desc),
            intent = 'adminmenu:action:set_weather',
            args = { value = opt.value, label = label },
        }
    end
    return {
        id = 'qb_adminmenu_menu8',
        title = tr('menu.weather_conditions'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.manage_server'), tr('menu.weather_conditions') },
        items = items,
    }
end

function AdminMenuSpecs.BuildMenu4(lang, players)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local sorted = {}
    for _, v in pairs(players or {}) do
        if type(v) == 'table' then
            sorted[#sorted + 1] = v
        end
    end
    table.sort(sorted, function(a, b)
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)

    local items = {}
    local idPrefix = tr('info.id')
    local desc = tr('info.player_name')
    for idx, v in ipairs(sorted) do
        local pid = v.id
        local pname = v.name or v.cid or tostring(pid or idx)
        items[#items + 1] = {
            id = AdminMenuSpecs.SafeId('ply', idx),
            kind = 'nav',
            icon = '👤',
            label = idPrefix .. tostring(pid) .. ' | ' .. tostring(pname),
            description = desc,
            intent = 'adminmenu:open:player',
            args = { playerKey = tostring(pid or idx) },
        }
    end
    items[#items + 1] = {
        id = 'back_to_main',
        kind = 'nav',
        icon = '↩️',
        label = tr('menu.admin_menu'),
        intent = 'adminmenu:open:menu1',
    }

    return {
        id = 'qb_adminmenu_menu4',
        title = tr('menu.online_players'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players') },
        emptyMessage = tr('menu.online_players'),
        items = items,
    }
end

function AdminMenuSpecs.BuildPlayerMenu(lang, player)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local p = type(player) == 'table' and player or {}
    local cid = tostring(p.cid or p.name or p.id or 'Player')
    local title = cid .. tr('info.options')

    local actions = {
        { id = 'kill', icon = '💀', label = tr('menu.kill'), desc = tr('menu.kill') .. ' ' .. cid },
        { id = 'revive', icon = '🏥', label = tr('menu.revive'), desc = tr('menu.revive') .. ' ' .. cid },
        { id = 'freeze', icon = '🥶', label = tr('menu.freeze'), desc = tr('menu.freeze') .. ' ' .. cid },
        { id = 'spectate', icon = '👀', label = tr('menu.spectate'), desc = tr('menu.spectate') .. ' ' .. cid },
        { id = 'goto', icon = '➡️', label = tr('info.go_to'), desc = tr('info.go_to') .. ' ' .. cid .. tr('info.position') },
        { id = 'bring', icon = '⬅️', label = tr('menu.bring'), desc = tr('menu.bring') .. ' ' .. cid .. ' ' .. tr('info.your_position') },
        { id = 'intovehicle', icon = '🚗', label = tr('menu.sit_in_vehicle'), desc = tr('desc.sit_in_veh_desc') .. ' ' .. cid .. ' ' .. tr('desc.sit_in_veh_desc2') },
        { id = 'inventory', icon = '🎒', label = tr('menu.open_inv'), desc = tr('info.open') .. ' ' .. cid .. tr('info.inventories') },
        { id = 'cloth', icon = '👕', label = tr('menu.give_clothing_menu'), desc = tr('desc.clothing_menu_desc') .. ' ' .. cid },
    }

    local items = {}
    for _, act in ipairs(actions) do
        items[#items + 1] = {
            id = act.id,
            kind = 'action',
            icon = act.icon,
            label = act.label,
            description = act.desc,
            intent = 'adminmenu:action:player_action',
            args = { action = act.id },
        }
    end

    items[#items + 1] = {
        id = 'kick',
        kind = 'nav',
        icon = '🥾',
        label = tr('menu.kick'),
        description = tr('menu.kick') .. ' ' .. cid .. ' ' .. tr('info.reason'),
        intent = 'adminmenu:open:menu10',
    }
    items[#items + 1] = {
        id = 'ban',
        kind = 'nav',
        icon = '🚫',
        label = tr('menu.ban'),
        description = tr('menu.ban') .. ' ' .. cid .. ' ' .. tr('info.reason'),
        intent = 'adminmenu:open:menu9',
    }
    items[#items + 1] = {
        id = 'perms',
        kind = 'nav',
        icon = '🎟️',
        label = tr('menu.permissions'),
        description = tr('info.give') .. ' ' .. cid .. ' ' .. tr('menu.permissions'),
        intent = 'adminmenu:open:menu11',
    }

    return {
        id = 'qb_adminmenu_player',
        title = title,
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players'), cid },
        items = items,
    }
end

function AdminMenuSpecs.BuildMenu10(lang, player)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local p = type(player) == 'table' and player or {}
    local cid = tostring(p.cid or p.name or p.id or 'Player')
    return {
        id = 'qb_adminmenu_menu10',
        title = tr('menu.kick'),
        subtitle = cid,
        surface = 'form',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players'), cid, tr('menu.kick') },
        submitLabel = tr('info.confirm'),
        intent = 'adminmenu:action:kick_submit',
        items = {
            {
                id = 'reason',
                kind = 'input',
                inputType = 'text',
                label = tr('info.reason'),
                placeholder = tr('desc.kick_reason'),
                hint = tr('desc.kick_reason'),
                required = true,
                maxLength = 255,
            },
        },
    }
end

local BAN_PRESETS = {
    { id = '1h', key = 'time.onehour', value = '3600' },
    { id = '6h', key = 'time.sixhour', value = '21600' },
    { id = '12h', key = 'time.twelvehour', value = '43200' },
    { id = '1d', key = 'time.oneday', value = '86400' },
    { id = '3d', key = 'time.threeday', value = '259200' },
    { id = '1w', key = 'time.oneweek', value = '604800' },
    { id = '1m', key = 'time.onemonth', value = '2678400' },
    { id = '3m', key = 'time.threemonth', value = '8035200' },
    { id = '6m', key = 'time.sixmonth', value = '16070400' },
    { id = '1y', key = 'time.oneyear', value = '32140800' },
    { id = 'perm', key = 'time.permanent', value = '99999999999' },
}

function AdminMenuSpecs.BuildMenu9(lang, player)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local p = type(player) == 'table' and player or {}
    local cid = tostring(p.cid or p.name or p.id or 'Player')
    local desc = tr('time.ban_length')
    local items = {}

    for _, preset in ipairs(BAN_PRESETS) do
        local label = tr(preset.key)
        items[#items + 1] = {
            id = 'ban_' .. preset.id,
            kind = 'nav',
            icon = '⏲️',
            label = label,
            description = desc,
            intent = 'adminmenu:open:menu9_form',
            args = { length = preset.value, label = label, custom = false },
        }
    end

    local selfLabel = tr('time.self')
    items[#items + 1] = {
        id = 'ban_self',
        kind = 'nav',
        icon = '⌨️',
        label = selfLabel,
        description = desc,
        intent = 'adminmenu:open:menu9_form',
        args = { custom = true, label = selfLabel },
    }

    return {
        id = 'qb_adminmenu_menu9',
        title = tr('menu.ban'),
        subtitle = cid .. ' · ' .. tr('info.length'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players'), cid, tr('menu.ban') },
        items = items,
    }
end

function AdminMenuSpecs.BuildMenu9Form(lang, player, opts)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local p = type(player) == 'table' and player or {}
    local o = type(opts) == 'table' and opts or {}
    local cid = tostring(p.cid or p.name or p.id or 'Player')
    local items = {}

    if o.custom then
        items[#items + 1] = {
            id = 'length',
            kind = 'input',
            inputType = 'number',
            label = tr('info.length'),
            placeholder = '3600',
            hint = tr('time.ban_length'),
            min = 1,
            maxLength = 11,
            required = true,
        }
    end

    items[#items + 1] = {
        id = 'reason',
        kind = 'input',
        inputType = 'text',
        label = tr('info.reason'),
        placeholder = tr('desc.ban_reason'),
        hint = tr('desc.confirm_ban'),
        required = true,
        maxLength = 255,
    }

    return {
        id = 'qb_adminmenu_menu9_form',
        title = tr('menu.ban'),
        subtitle = cid .. ' · ' .. tostring(o.label or o.length or tr('time.ban_length')),
        surface = 'form',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players'), cid, tr('menu.ban') },
        submitLabel = tr('info.confirm'),
        intent = 'adminmenu:action:ban_submit',
        items = items,
    }
end

local PERMISSION_GROUPS = {
    { id = 'perm_user', rank = 'user', label = 'User' },
    { id = 'perm_admin', rank = 'admin', label = 'Admin' },
    { id = 'perm_god', rank = 'god', label = 'God' },
}

function AdminMenuSpecs.BuildMenu11(lang, player)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local p = type(player) == 'table' and player or {}
    local cid = tostring(p.cid or p.name or p.id or 'Player')
    local items = {}

    for _, g in ipairs(PERMISSION_GROUPS) do
        items[#items + 1] = {
            id = g.id,
            kind = 'nav',
            icon = '🎟️',
            label = g.label,
            description = 'Give the permission group',
            intent = 'adminmenu:open:menu11_confirm',
            args = { rank = g.rank, label = g.label },
        }
    end
    items[#items + 1] = {
        id = 'back_to_player',
        kind = 'nav',
        icon = '↩️',
        label = cid .. tr('info.options'),
        intent = 'adminmenu:open:player',
    }

    return {
        id = 'qb_adminmenu_menu11',
        title = tr('menu.permissions'),
        subtitle = cid,
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players'), cid, tr('menu.permissions') },
        items = items,
    }
end

function AdminMenuSpecs.BuildMenu11Confirm(lang, player, group)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local p = type(player) == 'table' and player or {}
    local g = type(group) == 'table' and group or {}
    local cid = tostring(p.cid or p.name or p.id or 'Player')
    local groupLabel = tostring(g.label or g.rank or 'User')
    local confirmLabel = tr('info.confirm')

    return {
        id = 'qb_adminmenu_menu11_confirm',
        title = tr('menu.permissions'),
        subtitle = cid .. ' · ' .. groupLabel,
        surface = 'confirm',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.online_players'), cid, tr('menu.permissions') },
        message = ('%s -> %s'):format(cid, groupLabel),
        confirmLabel = confirmLabel,
        intent = 'adminmenu:action:perms_confirm',
        items = {
            {
                id = 'giveperms',
                kind = 'confirm',
                label = confirmLabel,
                description = 'Give the permission group',
                intent = 'adminmenu:action:perms_confirm',
            },
        },
    }
end

function AdminMenuSpecs.BuildMenu5(lang)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    return {
        id = 'qb_adminmenu_menu5',
        title = tr('menu.vehicle_options'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.vehicle_options') },
        items = {
            {
                id = 'spawn_vehicle',
                kind = 'nav',
                icon = '🚗',
                label = tr('menu.spawn_vehicle'),
                description = tr('desc.spawn_vehicle_desc'),
                intent = 'adminmenu:open:menu12',
            },
            {
                id = 'fix_vehicle',
                kind = 'action',
                icon = '🔧',
                label = tr('menu.fix_vehicle'),
                description = tr('desc.fix_vehicle_desc'),
                intent = 'adminmenu:action:veh_command',
                args = { cmd = 'fix' },
            },
            {
                id = 'buy_vehicle',
                kind = 'action',
                icon = '💲',
                label = tr('menu.buy'),
                description = tr('desc.buy_desc'),
                intent = 'adminmenu:action:veh_command',
                args = { cmd = 'admincar' },
            },
            {
                id = 'remove_vehicle',
                kind = 'action',
                icon = '🗑️',
                label = tr('menu.remove_vehicle'),
                description = tr('desc.remove_vehicle_desc'),
                intent = 'adminmenu:action:veh_command',
                args = { cmd = 'dv' },
            },
            {
                id = 'max_mods',
                kind = 'action',
                icon = '⚡️',
                label = tr('menu.max_mods'),
                description = tr('desc.max_mod_desc'),
                intent = 'adminmenu:action:veh_command',
                args = { cmd = 'maxmods' },
            },
        },
    }
end

local function firstToUpper(str, qbShared)
    if qbShared and type(qbShared.FirstToUpper) == 'function' then
        local ok, out = pcall(qbShared.FirstToUpper, str)
        if ok and type(out) == 'string' and #out > 0 then
            return out
        end
    end
    local s = tostring(str or '')
    return (s:gsub('^%l', string.upper))
end

function AdminMenuSpecs.CollectVehicleCategories(vehiclesTable)
    local byCat = {}
    for k, v in pairs(vehiclesTable or {}) do
        if type(v) == 'table' then
            local cat = tostring(v['category'] or 'other')
            if byCat[cat] == nil then
                byCat[cat] = {}
            end
            byCat[cat][k] = v
        end
    end
    return byCat
end

function AdminMenuSpecs.BuildMenu12(lang, qbShared)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local shared = qbShared or (QBCore and QBCore.Shared) or {}
    local byCat = AdminMenuSpecs.CollectVehicleCategories(shared.Vehicles)
    local catNames = {}
    for cat, _ in pairs(byCat) do
        catNames[#catNames + 1] = cat
    end
    table.sort(catNames, function(a, b)
        return a:lower() < b:lower()
    end)

    local items = {}
    local desc = tr('menu.category_name')
    for idx, cat in ipairs(catNames) do
        items[#items + 1] = {
            id = AdminMenuSpecs.SafeId('vehcat', idx),
            kind = 'nav',
            icon = '🚗',
            label = AdminMenuSpecs.SafeLabel(firstToUpper(cat, shared), cat),
            description = desc,
            intent = 'adminmenu:open:menu13',
            args = { category = cat, label = firstToUpper(cat, shared) },
        }
    end

    return {
        id = 'qb_adminmenu_menu12',
        title = tr('menu.vehicle_categories'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.vehicle_options'), tr('menu.vehicle_categories') },
        emptyMessage = tr('menu.vehicle_categories'),
        items = items,
    }
end

function AdminMenuSpecs.BuildMenu13(lang, categoryName, qbShared)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local shared = qbShared or (QBCore and QBCore.Shared) or {}
    local byCat = AdminMenuSpecs.CollectVehicleCategories(shared.Vehicles)
    local cat = type(categoryName) == 'string' and byCat[categoryName] or {}
    local entries = {}
    for k, v in pairs(cat) do
        local label = AdminMenuSpecs.SafeLabel(v and v['name'], tostring(k))
        entries[#entries + 1] = { model = tostring(k), label = label }
    end
    table.sort(entries, function(a, b)
        return a.label:lower() < b.label:lower()
    end)

    local items = {}
    for idx, entry in ipairs(entries) do
        items[#items + 1] = {
            id = AdminMenuSpecs.SafeId('veh', idx),
            kind = 'action',
            icon = '🚗',
            label = entry.label,
            description = 'Spawn ' .. entry.label,
            intent = 'adminmenu:action:veh_command',
            args = { cmd = 'car', model = entry.model },
        }
    end

    local catLabel = categoryName and firstToUpper(categoryName, shared) or tr('menu.vehicle_models')
    return {
        id = 'qb_adminmenu_menu13',
        title = tr('menu.vehicle_models'),
        subtitle = catLabel,
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.vehicle_options'), tr('menu.vehicle_categories'), catLabel },
        emptyMessage = tr('menu.vehicle_models'),
        items = items,
    }
end

function AdminMenuSpecs.BuildMenu6(lang, dealers)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local sorted = {}
    for _, v in pairs(dealers or {}) do
        if type(v) == 'table' and v['name'] ~= nil then
            sorted[#sorted + 1] = v
        end
    end
    table.sort(sorted, function(a, b)
        return tostring(a['name']):lower() < tostring(b['name']):lower()
    end)

    local items = {}
    local desc = tr('menu.dealer_name')
    for idx, v in ipairs(sorted) do
        local name = tostring(v['name'])
        items[#items + 1] = {
            id = AdminMenuSpecs.SafeId('dealer', idx),
            kind = 'nav',
            icon = '💊',
            label = AdminMenuSpecs.SafeLabel(name, 'Dealer ' .. idx),
            description = desc,
            intent = 'adminmenu:open:dealer',
            args = { dealerName = name },
        }
    end
    items[#items + 1] = {
        id = 'back_to_main',
        kind = 'nav',
        icon = '↩️',
        label = tr('menu.admin_menu'),
        intent = 'adminmenu:open:menu1',
    }

    return {
        id = 'qb_adminmenu_menu6',
        title = tr('menu.dealer_list'),
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.dealer_list') },
        emptyMessage = tr('menu.dealer_list'),
        items = items,
    }
end

function AdminMenuSpecs.BuildDealerMenu(lang, dealer)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local d = type(dealer) == 'table' and dealer or {}
    local name = tostring(d['name'] or 'Dealer')
    return {
        id = 'qb_adminmenu_dealer',
        title = tr('menu.edit_dealer') .. name,
        surface = 'list',
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.dealer_list'), name },
        items = {
            {
                id = 'dealer_goto',
                kind = 'action',
                icon = '➡️',
                label = ' ' .. tr('info.go_to') .. ' ' .. name,
                description = tr('desc.dealergoto_desc') .. ' ' .. name,
                intent = 'adminmenu:action:dealer_goto',
            },
            {
                id = 'dealer_remove',
                kind = 'nav',
                icon = '☠',
                label = ' ' .. tr('info.remove') .. ' ' .. name,
                description = tr('desc.dealerremove_desc') .. ' ' .. name,
                tone = 'danger',
                danger = true,
                intent = 'adminmenu:open:dealer_delete_confirm',
            },
        },
    }
end

function AdminMenuSpecs.BuildDealerDeleteConfirm(lang, dealer)
    local tr = function(key)
        return AdminMenuSpecs.Translate(lang, key)
    end
    local d = type(dealer) == 'table' and dealer or {}
    local name = tostring(d['name'] or 'Dealer')
    local confirmLabel = tr('info.confirm')
    return {
        id = 'qb_adminmenu_dealer_delete_confirm',
        title = tr('info.remove') .. ' ' .. name,
        surface = 'confirm',
        danger = true,
        breadcrumbs = { tr('menu.admin_menu'), tr('menu.dealer_list'), name },
        message = tr('desc.dealerremove_desc') .. ' ' .. name,
        confirmLabel = confirmLabel,
        intent = 'adminmenu:action:dealer_delete',
        items = {
            {
                id = 'confirm_delete_dealer',
                kind = 'confirm',
                label = confirmLabel,
                danger = true,
                intent = 'adminmenu:action:dealer_delete',
            },
        },
    }
end

return AdminMenuSpecs
