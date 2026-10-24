-- shared/npc_callouts.lua — NPC callout catalogue shared by server and client.
--
-- The server owns *where* and *when* an NPC callout exists (template choice,
-- fixed scene coordinates, active cap, payout). The client only renders the
-- scene and reports the outcome back. Keeping the catalogue here means the
-- spawn logic and the presentation never drift apart.
--
-- Four MVP templates:
--   traffic_accident  10-50  2 damaged cars + 1 injured/dead civilian
--   suspicious_vehicle 10-37 parked car + 1 suspect (may flee or fight)
--   store_robbery       211  2 armed suspects + 1 clerk
--   armed_person      10-32  1 armed suspect
--
-- Every template carries 3 fixed locations. Scene offsets are relative metres
-- around the chosen location and are intentionally plain tables (shared code
-- runs on the server too, where vector3 is not available).

NPCCallouts = {}

-- Scheduling / caps (server only, mirrored here so tests and docs share one
-- source of truth).
NPCCallouts.MAX_ACTIVE = 1
NPCCallouts.INTERVAL_MS = 8 * 60 * 1000 -- one evaluation every 8 minutes
NPCCallouts.SPAWN_CHANCE = 0.30         -- 30% per evaluation
NPCCallouts.START_DELAY_MS = 30000      -- first evaluation 30s after start
NPCCallouts.REWARD = 500                -- bank payout to the closing officer
NPCCallouts.SPAWN_RADIUS = 80.0         -- an officer this close "arrives"
NPCCallouts.DESPAWN_RADIUS = 300.0      -- client-side abandon radius
NPCCallouts.DESPAWN_GRACE_MS = 60 * 1000

local TEMPLATES = {
    traffic_accident = {
        id = 'traffic_accident',
        code = '10-50',
        title = '交通事故',
        label = '10-50 交通事故',
        priority = 2,
        scene_label = '交通事故现场',
        description = '两车相撞，现场有一名伤员。请前往 {location} 处置并疏导交通。',
        locations = {
            { x = 197.8, y = -912.9, z = 30.7, heading = 90.0,  label = 'Pillbox Hill 路口' },
            { x = -763.5, y = -926.5, z = 18.0, heading = 180.0, label = 'La Mesa 工业区' },
            { x = 1712.0, y = 3760.0, z = 34.1, heading = 0.0,   label = 'Sandy Shores 公路' },
        },
        scene = {
            vehicles = {
                { models = { 'asea', 'emperor', 'glendale' }, offset = { x = -7.0, y = 0.0, z = 0.0 }, heading = 8.0,  damaged = true },
                { models = { 'sultan', 'futo', 'buffalo' },   offset = { x = 6.0, y = -1.5, z = 0.0 }, heading = -12.0, damaged = true },
            },
            victims = {
                { models = { 'a_m_y_skater_01', 'a_m_y_hipster_01' }, offset = { x = 0.0, y = 2.5, z = 0.0 }, dead_chance = 0.40 },
            },
            suspects = {},
            bystanders = {},
        },
    },

    suspicious_vehicle = {
        id = 'suspicious_vehicle',
        code = '10-37',
        title = '可疑车辆',
        label = '10-37 可疑车辆',
        priority = 2,
        scene_label = '可疑车辆现场',
        description = '一辆可疑车辆停靠在 {location}，车内人员形迹可疑，可能逃跑或拒捕。',
        locations = {
            { x = 95.0, y = -1961.0, z = 20.8, heading = 270.0, label = 'Grove Street' },
            { x = 1268.0, y = -314.0, z = 69.0, heading = 90.0,  label = 'Mirror Park 便利店' },
            { x = -320.0, y = 6070.0, z = 31.5, heading = 0.0,   label = 'Paleto Bay 北侧' },
        },
        scene = {
            vehicles = {
                { models = { 'sultan', 'futo', 'ruiner' }, offset = { x = 4.0, y = 0.0, z = 0.0 }, heading = 0.0, damaged = false },
            },
            victims = {},
            suspects = {
                {
                    models = { 'g_m_y_lost_01', 'g_m_y_lost_02', 'g_m_y_ballaeast_01' },
                    offset = { x = -2.0, y = 1.5, z = 0.0 },
                    weapon = 'WEAPON_PISTOL',
                    armour = 25,
                    behavior = 'flee_or_fight',
                    flee_chance = 0.55,
                },
            },
            bystanders = {},
        },
    },

    store_robbery = {
        id = 'store_robbery',
        code = '211',
        title = '商店抢劫',
        label = '211 商店抢劫',
        priority = 1,
        scene_label = '商店抢劫现场',
        description = '{location} 发生持枪抢劫，两名嫌疑人仍在店内，店员被控制。',
        locations = {
            { x = 24.0, y = -1347.0, z = 29.5, heading = 180.0, label = 'Strawberry 24/7' },
            { x = -706.5, y = -914.5, z = 19.2, heading = 90.0, label = 'La Mesa LTD' },
            { x = 1164.0, y = -322.0, z = 69.0, heading = 270.0, label = 'Mirror Park 24/7' },
        },
        scene = {
            vehicles = {},
            victims = {},
            suspects = {
                {
                    models = { 'g_m_y_lost_01', 'g_m_y_ballaeast_01' },
                    offset = { x = -2.5, y = 1.0, z = 0.0 },
                    weapon = 'WEAPON_PISTOL',
                    armour = 35,
                    behavior = 'hostile',
                },
                {
                    models = { 'g_m_y_lost_02', 'g_m_y_mexgang_01' },
                    offset = { x = 2.0, y = 1.5, z = 0.0 },
                    weapon = 'WEAPON_COMBATPISTOL',
                    armour = 35,
                    behavior = 'hostile',
                },
            },
            bystanders = {
                {
                    models = { 'a_f_y_business_01', 'a_f_y_business_02' },
                    offset = { x = 0.0, y = -2.0, z = 0.0 },
                    scenario = 'WORLD_HUMAN_HANDS_UP',
                },
            },
        },
    },

    armed_person = {
        id = 'armed_person',
        code = '10-32',
        title = '持械人员',
        label = '10-32 持械人员',
        priority = 1,
        scene_label = '持械人员现场',
        description = '{location} 有一名持枪人员，对周边构成威胁，请立即前往处置。',
        locations = {
            { x = 430.0, y = -1500.0, z = 29.3, heading = 180.0, label = 'Strawberry 街区' },
            { x = -1200.0, y = -1490.0, z = 4.3, heading = 90.0,  label = 'Vespucci 海滩' },
            { x = 1910.0, y = 4920.0, z = 48.3, heading = 0.0,   label = 'Grapeseed 农场' },
        },
        scene = {
            vehicles = {},
            victims = {},
            suspects = {
                {
                    models = { 'g_m_y_lost_01', 'g_m_y_mexgang_01', 'g_m_y_ballaeast_01' },
                    offset = { x = 0.0, y = 1.0, z = 0.0 },
                    weapon = 'WEAPON_PISTOL',
                    armour = 30,
                    behavior = 'hostile',
                },
            },
            bystanders = {},
        },
    },
}

NPCCallouts.TEMPLATES = TEMPLATES

-- Stable order for random selection and for the console help output.
local ORDER = { 'traffic_accident', 'suspicious_vehicle', 'store_robbery', 'armed_person' }
NPCCallouts.ORDER = ORDER

function NPCCallouts.Get(templateId)
    if type(templateId) ~= 'string' then return nil end
    local id = templateId:lower():match('^%s*(.-)%s*$')
    return TEMPLATES[id]
end

function NPCCallouts.Ids()
    local ids = {}
    for i = 1, #ORDER do ids[i] = ORDER[i] end
    return ids
end

function NPCCallouts.RandomId()
    return ORDER[math.random(1, #ORDER)]
end

function NPCCallouts.Count()
    return #ORDER
end

return NPCCallouts
