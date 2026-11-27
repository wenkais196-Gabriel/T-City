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

return AdminMenuSpecs
