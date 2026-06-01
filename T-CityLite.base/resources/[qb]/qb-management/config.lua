-- Zones for Menus
Config = Config or {}

Config.UseTarget = GetConvar('UseTarget', 'false') == 'true' -- Use qb-target interactions (don't change this, go to your server.cfg and add `setr UseTarget true` to use this and just that from true to false or the other way around)

Config.BossMenus = {
    police = {
        vector3(447.16, -974.31, 30.47),
    },
    ambulance = {
        vector3(311.21, -599.36, 43.29),
    },
    cardealer = {
        vector3(-32.94, -1114.64, 26.42),
    },
    mechanic = {
        vector3(-347.59, -133.35, 39.01),
    },
}

Config.GangMenus = {
    lostmc = {
        vector3(982.26, -104.22, 74.85), -- Lost MC Clubhouse front door
    },
    ballas = {
        vector3(98.15, -1929.74, 20.80), -- Ballas house on Grove Street
    },
    vagos = {
        vector3(336.57, -2012.39, 22.31), -- Vagos headquarters at Rancho
    },
    cartel = {
        vector3(1395.80, 1141.74, 115.24), -- Madrazo Ranch / Cartel HQ (Perfect door handle center alignment, Z lowered by 0.3m)
    },
    families = {
        vector3(-144.13, -1693.93, 29.29), -- Families Chamberlain Hills
    },
}
