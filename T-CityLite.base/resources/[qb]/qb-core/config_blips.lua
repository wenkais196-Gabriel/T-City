-- ============================================================================
-- config_blips.lua — 大地图侧边栏 Blip 统一分类配置
-- ============================================================================
-- 设计原则:
--   1. 所有显示文本使用 localeKey，由 _L() 在运行时按玩家语言解析
--   2. 大类做折叠容器，子项支持「同类同名」和「同类不同名」
--   3. 每项填 coord + localeKey 即可，sprite/color 继承大类默认值
-- ============================================================================

Config = Config or {}
Config.BlipCategories = {}

local function B(item)
    item.showBlip   = (item.showBlip ~= false)
    item.blipSprite = item.blipSprite or 357
    item.blipColor  = item.blipColor  or 3
    item.blipScale  = item.blipScale  or 0.6
    item.coords     = item.coords     or item.takeVehicle
    return item
end

-- ============================================================================
-- Category 1: 公共停车场 (Public Parking) — 同类不同名
-- ============================================================================
Config.BlipCategories.public_parking = {
    localeKey   = 'blip_cat_parking',
    icon        = 'fa-solid fa-square-parking',
    blipSprite  = 357,
    blipColor   = 3,
    items = {
        B { localeKey = 'blip_parking_motel',         coords = vector3(274.29,  -334.15,  44.92) },
        B { localeKey = 'blip_parking_casino',        coords = vector3(883.96,  -4.71,    78.76) },
        B { localeKey = 'blip_parking_san_andreas',   coords = vector3(-330.01, -780.33,  33.96) },
        B { localeKey = 'blip_parking_spanish',       coords = vector3(-1160.86,-741.41,  19.63) },
        B { localeKey = 'blip_parking_caears24',      coords = vector3(69.84,   12.6,     68.96) },
        B { localeKey = 'blip_parking_caears242',     coords = vector3(-453.7,  -786.78,  30.56) },
        B { localeKey = 'blip_parking_laguna',        coords = vector3(364.37,  297.83,   103.49)},
        B { localeKey = 'blip_parking_airport',       coords = vector3(-773.12, -2033.04, 8.88)  },
        B { localeKey = 'blip_parking_beach',         coords = vector3(-1185.32,-1500.64, 4.38)  },
        B { localeKey = 'blip_parking_motor_hotel',   coords = vector3(1137.77, 2663.54,  37.9)  },
        B { localeKey = 'blip_parking_liqour',        coords = vector3(883.99,  3649.67,  32.87) },
        B { localeKey = 'blip_parking_shore',         coords = vector3(1737.03, 3718.88,  34.05) },
        B { localeKey = 'blip_parking_bell_farms',    coords = vector3(76.88,   6397.3,   31.23) },
        B { localeKey = 'blip_parking_dumbo',         coords = vector3(165.75,  -3227.2,  5.89)  },
        B { localeKey = 'blip_parking_pillbox',       coords = vector3(213.2,   -796.05,  30.86) },
        B { localeKey = 'blip_parking_grapeseed',     coords = vector3(2552.68, 4671.8,   33.95) },
    },
}

-- ============================================================================
-- Category 2: 警察局 (Police Stations) — 同类不同名
-- ============================================================================
Config.BlipCategories.police_stations = {
    localeKey   = 'blip_cat_police',
    icon        = 'fa-solid fa-building-shield',
    blipSprite  = 60,
    blipColor   = 3,
    items = {
        B { localeKey = 'blip_police_mission_row',  coords = vector3(428.23,  -984.28,  29.76) },
        B { localeKey = 'blip_police_paleto',       coords = vector3(-451.55,  6014.25, 31.72) },
        B { localeKey = 'blip_police_sandy',        coords = vector3(1854.82,  3679.4,  33.82) },
        B { localeKey = 'blip_prison',              coords = vector3(1845.90,  2585.87, 45.67) },
    },
}

-- ============================================================================
-- Category 3: 帮派据点 (Gang HQs) — 同类不同名
-- ============================================================================
Config.BlipCategories.gang_hqs = {
    localeKey   = 'blip_cat_gang_hqs',
    icon        = 'fa-solid fa-skull',
    blipSprite  = 499,
    blipColor   = 1,
    items = {
        B { localeKey = 'blip_cartel_hq',     coords = vector3(1395.80, 1141.74, 115.24) },
        B { localeKey = 'blip_cartel_garage', coords = vector3(1411.67, 1117.80, 114.84) },
        B { localeKey = 'blip_ballas_hq',     coords = vector3(98.15,   -1929.74, 20.80) },
        B { localeKey = 'blip_families_hq',   coords = vector3(-144.13, -1693.93, 29.29) },
        B { localeKey = 'blip_lostmc_hq',     coords = vector3(982.26,  -104.22,  74.85) },
        B { localeKey = 'blip_vagos_hq',      coords = vector3(336.57,  -2012.39, 22.31) },
    },
}

-- ============================================================================
-- Category 4: 医院 (Hospitals) — 同类不同名
-- ============================================================================
Config.BlipCategories.hospitals = {
    localeKey   = 'blip_cat_hospitals',
    icon        = 'fa-solid fa-hospital',
    blipSprite  = 61,
    blipColor   = 1,
    items = {
        B { localeKey = 'blip_hospital_pillbox', coords = vector3(311.25,  -592.42,  43.28) },
        B { localeKey = 'blip_hospital_sandy',   coords = vector3(1834.51,  3672.99, 34.28) },
        B { localeKey = 'blip_hospital_paleto',  coords = vector3(-248.03,  6331.03, 32.43) },
    },
}

-- ============================================================================
-- 预留扩展: 机库 (Hangars)、船坞 (Boathouses)、商店 (Shops) 等
-- 按上方格式追加 Config.BlipCategories.hangars / .boathouses / .shops 即可
-- ============================================================================
