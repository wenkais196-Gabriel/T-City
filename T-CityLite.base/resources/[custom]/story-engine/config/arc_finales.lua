-- config/arc_finales.lua — 终章 quest → 剧情线映射
--
-- 当这些 quest 完成时，对应的剧情线被标记为"已完成"
-- 用于一次性门控

return {
    cartel = {
        'cartel_ch4_benevolent_king',
        'cartel_ch4_fugitive',
        'cartel_ch4_tyrant',
    },
    police = {
        'police_ch4_hero',
        'police_ch4_silent_guardian',
        'police_ch4_martyr',
    },
    civilian = {
        'civilian_ch4_mogul',
        'civilian_ch4_artisan',
        'civilian_ch4_survivor',
    },
}
