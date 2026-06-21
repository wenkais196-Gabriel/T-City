-- config/quests/address_pools.lua — 配送地址池 (v0.8b)
--
-- 坐标来源:
--   downtown + vinewood + burton: dream-postal 真实送件/取件点
--   industrial + port: qb-truckerjob / qb-shops 附近
--   sandy + paleto + grapeseed: GTA V 地图实测近似点
--
-- 每个地址 = { coords = {x,y,z}, label = "地名", district = "区域" }
-- 区域用于距离筛选、难度分级

return {
    -- ═══════════════════════════════════════════════════
    -- downtown_residential: 市中心住宅+商业 — 短距配送 (Lv.1-2)
    -- ═══════════════════════════════════════════════════
    downtown_residential = {
        { coords = { x = 207.21, y = -85.17, z = 69.17 },  label = 'Alta 公寓',       district = 'Alta' },
        { coords = { x = 319.95, y = -121.57, z = 68.35 }, label = 'Pillbox Hill 诊所', district = 'Pillbox Hill' },
        { coords = { x = 330.25, y = -202.46, z = 54.09 }, label = 'Mission Row 写字楼', district = 'Mission Row' },
        { coords = { x = 121.74, y = 40.65, z = 73.52 },   label = 'Burton 排屋',       district = 'Burton' },
        { coords = { x = 401.07, y = 98.84, z = 101.48 },  label = 'Richman 别墅',      district = 'Richman' },
        { coords = { x = -315.44, y = -3.85, z = 48.21 },  label = 'Vinewood Hills 民宅', district = 'Vinewood Hills' },
        { coords = { x = -482.89, y = -17.06, z = 45.11 }, label = 'Vinewood 半山别墅',   district = 'Vinewood Hills' },
        { coords = { x = -85.15, y = 38.50, z = 71.90 },   label = 'Downtown 咖啡馆',    district = 'Downtown Vinewood' },
        { coords = { x = -599.09, y = -251.03, z = 36.28 },label = 'Rockford Hills 商铺', district = 'Rockford Hills' },
        { coords = { x = -722.48, y = -98.19, z = 38.20 }, label = 'Little Seoul 超市',  district = 'Little Seoul' },
        { coords = { x = 825.21, y = -96.19, z = 80.60 },  label = 'La Mesa 汽修店',     district = 'La Mesa' },
        { coords = { x = 172.52, y = 183.49, z = 105.73 }, label = 'Banham Canyon 民宅',  district = 'Banham Canyon' },
        { coords = { x = -88.85, y = 214.90, z = 96.41 },  label = 'Banham 山顶别墅',    district = 'Banham Canyon' },
        { coords = { x = -239.00, y = 205.80, z = 83.88 }, label = 'Vinewood 大道商铺',   district = 'Vinewood' },
        { coords = { x = -323.08, y = 134.50, z = 67.36 }, label = 'Vinewood Hills 公寓', district = 'Vinewood Hills' },
    },

    -- ═══════════════════════════════════════════════════
    -- industrial_south: LS 南部工业区 — 中距配送 (Lv.2-3)
    -- ═══════════════════════════════════════════════════
    industrial_south = {
        { coords = { x = 480.0, y = -1800.0, z = 28.0 },  label = 'Cypress Flats 仓库',  district = 'Cypress Flats' },
        { coords = { x = 200.0, y = -1600.0, z = 28.0 },  label = 'Davis 建材市场',       district = 'Davis' },
        { coords = { x = 50.0,  y = -1900.0, z = 24.0 },  label = 'Strawberry 货运站',    district = 'Strawberry' },
        { coords = { x = 900.0, y = -2200.0, z = 32.0 },  label = 'La Mesa 配送中心',     district = 'La Mesa' },
        { coords = { x = 1100.0,y = -2500.0, z = 20.0 },  label = 'Murrieta Heights 油库',district = 'Murrieta Heights' },
        { coords = { x = 500.0, y = -3000.0, z = 6.0 },   label = 'Elysian Island 码头',  district = 'Elysian Island' },
    },

    -- ═══════════════════════════════════════════════════
    -- sandy_shores_rural: 沙漠乡村 — 长距配送 (Lv.3-4)
    -- ═══════════════════════════════════════════════════
    sandy_shores_rural = {
        { coords = { x = 1700.0, y = 3500.0, z = 35.0 },  label = 'Sandy Shores 工地',     district = 'Sandy Shores' },
        { coords = { x = 1950.0, y = 3700.0, z = 32.0 },  label = 'Sandy Shores 加油站',    district = 'Sandy Shores' },
        { coords = { x = 2100.0, y = 4800.0, z = 41.0 },  label = 'Grapeseed 农贸市场',      district = 'Grapeseed' },
        { coords = { x = 2500.0, y = 4600.0, z = 36.0 },  label = 'Grapeseed 农场仓库',      district = 'Grapeseed' },
        { coords = { x = 600.0,  y = 2800.0, z = 42.0 },  label = 'Harmony 内陆物流园',      district = 'Harmony' },
        { coords = { x = 545.0,  y = 2660.0, z = 42.0 },  label = 'Harmony 加油站',          district = 'Harmony' },
        { coords = { x = -200.0, y = 4000.0, z = 33.0 },  label = 'Great Chaparral 牧场',    district = 'Great Chaparral' },
    },

    -- ═══════════════════════════════════════════════════
    -- paleto_bay_north: 北佩立托湾 — 超长距配送 (Lv.4-5)
    -- ═══════════════════════════════════════════════════
    paleto_bay_north = {
        { coords = { x = -400.0, y = 6200.0, z = 32.0 },  label = 'Paleto Bay 加油站',      district = 'Paleto Bay' },
        { coords = { x = -300.0, y = 6100.0, z = 32.0 },  label = 'Paleto Bay 车行',         district = 'Paleto Bay' },
        { coords = { x = -100.0, y = 6300.0, z = 32.0 },  label = 'Paleto Bay 超市',         district = 'Paleto Bay' },
        { coords = { x = -600.0, y = 5600.0, z = 30.0 },  label = 'Paleto Forest 锯木厂',    district = 'Paleto Forest' },
        { coords = { x = 1600.0, y = 100.0,  z = 80.0 },  label = 'Tongva Hills 水坝工地',   district = 'Tongva Hills' },
        { coords = { x = -1500.0,y = 3800.0, z = 33.0 },  label = 'Zancudo River 仓库',      district = 'Zancudo' },
        { coords = { x = -3100.0,y = 2800.0, z = 12.0 },  label = 'Chumash 海滨仓库',        district = 'Chumash' },
    },

    -- ═══════════════════════════════════════════════════
    -- port_logistics: 港口/物流枢纽 — 集装箱/燃油/大宗货物
    -- ═══════════════════════════════════════════════════
    port_logistics = {
        { coords = { x = 153.68, y = -3211.88, z = 5.91 }, label = 'LS Port 货车总站',      district = 'Port of LS' },
        { coords = { x = 800.0,  y = -3100.0, z = 6.0 },   label = 'LS Port 集装箱堆场',    district = 'Port of LS' },
        { coords = { x = 700.0,  y = -2900.0, z = 6.0 },   label = 'Terminal 燃油库区',     district = 'Terminal' },
        { coords = { x = 1000.0, y = -3000.0, z = 6.0 },   label = 'LS Docks 冷链仓库',     district = 'LS Docks' },
        { coords = { x = 500.0,  y = -2000.0, z = 20.0 },  label = 'La Mesa 车辆仓库',      district = 'La Mesa' },
        { coords = { x = 600.0,  y = -200.0,  z = 35.0 },  label = 'Downtown 建筑工场',     district = 'Downtown' },
        { coords = { x = 69.09,  y = 127.68, z = 79.21 },  label = 'GO Postal 好麦坞总部',  district = 'Vinewood' },
    },

    -- ═══════════════════════════════════════════════════
    -- aviation_airports: 跑道机场 (v0.11 — mixed 航空任务)
    -- ═══════════════════════════════════════════════════
    aviation_airports = {
        { coords = { x = -1253.0, y = -3385.5, z = 14.0 },  label = 'LSIA 国际机场 南机库 1', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1287.0, y = -3371.5, z = 14.0 },  label = 'LSIA 国际机场 南机库 2', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -965.0,  y = -2983.5, z = 14.0 },  label = 'LSIA 国际机场 北机库 1', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -993.5, y = -3023.0, z = 14.0 },  label = 'LSIA 国际机场 北机库 2', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1155.5, y = -2927.0, z = 14.0 },  label = 'LSIA 国际机场 室外 1', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1232.5, y = -2882.5, z = 14.0 },  label = 'LSIA 国际机场 室外 2', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1268.5, y = -2862.0, z = 14.0 },  label = 'LSIA 国际机场 室外 3', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1209.5, y = -2637.5, z = 14.0 },  label = 'LSIA 国际机场 廊桥 1', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1287.5, y = -2592.5, z = 14.0 },  label = 'LSIA 国际机场 廊桥 2', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = -1344.0, y = -2690.5, z = 14.0 },  label = 'LSIA 国际机场 廊桥 3', runways = 3, terminal = true,  type = 'international' },
        { coords = { x = 1733.0, y = 3312.5, z = 41.0 },  label = 'Sandy Shores 机场',    runways = 2, terminal = false, type = 'regional' },
        { coords = { x = 2135.0, y = 4781.5, z = 41.0 },  label = 'Grapeseed 跑道',       runways = 1, terminal = false, type = 'rural' },
        { coords = { x = -1844.5, y = 2984.0,  z = 33.0 },  label = 'Fort Zancudo 基地',    runways = 1, terminal = true,  type = 'military', restricted = true },
    },

    -- ═══════════════════════════════════════════════════
    -- aviation_helipads: 直升机停机坪 (v0.11 — mixed 航空任务)
    -- ═══════════════════════════════════════════════════
    aviation_helipads = {
        { coords = { x = -725.0,  y = -1444.0, z = 5.0 },   label = 'Vespucci 公共直升机场北', type = 'public',    landing = 'ground' },
        { coords = { x = -745.5,  y = -1468.5, z = 5.0 },   label = 'Vespucci 公共直升机场南', type = 'public',    landing = 'ground' },
        { coords = { x = -1178.5, y = -2846.0, z = 14.0 },  label = 'LSIA 直升机区1',          type = 'airport',   landing = 'ground' },
        { coords = { x = -1146.0, y = -2865.0, z = 14.0 },  label = 'LSIA 直升机区2',          type = 'airport',   landing = 'ground' },
        { coords = { x = -1113.0, y = -2884.0, z = 14.0 },  label = 'LSIA 直升机区3',          type = 'airport',   landing = 'ground' },
        { coords = { x = 1770.0,  y = 3240.0,  z = 42.0 },   label = 'Sandy Shores 机场停机坪', type = 'airport',     landing = 'ground' },
        { coords = { x = 2098.0,  y = 4819.5,  z = 41.5 },   label = 'McKenzie 麦肯齐机场',    type = 'airport',     landing = 'ground' },
        { coords = { x = -506.0,  y = -309.5,  z = 73.0 },  label = '中心医院停机坪西南',         type = 'hospital',  landing = 'rooftop' },
        { coords = { x = -448.5,  y = -306.5,  z = 78.0 },  label = '中心医院停机坪东北',         type = 'hospital',  landing = 'rooftop' },
        { coords = { x = -448.5,  y = -306.5,  z = 78.0 },  label = '中心医院停机坪东北',         type = 'hospital',  landing = 'rooftop' },
        { coords = { x = 352.0,   y = -588.5,  z = 74.0 },  label = 'Pillbox Hill 诊所屋顶',  type = 'hospital',  landing = 'rooftop' },
        { coords = { x = 1848.5,  y = 3658.5,  z = 34.0 },  label = 'Sandy Shores 诊所',      type = 'rural',     landing = 'ground' },
        { coords = { x = 363.0,   y = -1598.0, z = 37.0 },  label = 'Davis 警局屋顶',         type = 'police',    landing = 'rooftop' },
        { coords = { x = -1095.5, y = -835.0,  z = 37.5 },  label = 'Vespucci 警局屋顶',      type = 'police',    landing = 'rooftop' },
        { coords = { x = 449.5,   y = -981.5,  z = 43.5 },  label = 'Mission Row 警局屋顶',      type = 'police',    landing = 'rooftop' },
        { coords = { x = 580.0,   y = 12.5,    z = 103.0 },  label = 'Vinewood 警局屋顶',      type = 'police',    landing = 'rooftop' },
        { coords = { x = -475.0,  y = 5988.5,  z = 31.5 },   label = 'Paleto Bay 警局后院',    type = 'police',    landing = 'ground' },
        { coords = { x = 2510.5,  y = -342.0,  z = 118.0 },  label = 'NOOSE 总部屋顶北',         type = 'government',landing = 'rooftop' },
        { coords = { x = 2511.5,  y = -426.5,  z = 118.0 },  label = 'NOOSE 总部屋顶南',         type = 'government',landing = 'rooftop' },
        { coords = { x = 479.0,   y = -3370.0, z = 6.0 },   label = '军港码头停机坪',         type = 'military',  landing = 'ground', restricted = true },
        { coords = { x = -1877.0, y = 2805.5,  z = 33.0 },   label = 'Zancudo 军事基地东南 1', type = 'military',  landing = 'ground', restricted = true },
        { coords = { x = -1860.0, y = 2795.2,  z = 33.0 },   label = 'Zancudo 军事基地东南 2', type = 'military',  landing = 'ground', restricted = true },
        { coords = { x = -75.5,   y = -819.5,  z = 326.0 }, label = 'Maze Bank 塔顶',         type = 'skyscraper',landing = 'rooftop' },
        { coords = { x = -1582.0, y = -570.0,  z = 116.5 }, label = 'LomBank 屋顶',         type = 'building',landing = 'rooftop' },
        { coords = { x = -1391.5, y = -478.0,  z = 91.5 }, label = 'Maze Bank 屋顶',         type = 'building',landing = 'rooftop' },
        { coords = { x = -1007.5, y = -415.5,  z = 80.0 }, label = '市区屋顶 1',         type = 'building',landing = 'rooftop' },
        { coords = { x = -913.5,  y = -378.5,  z = 138.0 }, label = '市区屋顶 2',         type = 'building',landing = 'rooftop' },
        { coords = { x = -1011.0, y = -757.0,  z = 82.0 }, label = '市区屋顶 3',         type = 'building',landing = 'rooftop' },
        { coords = { x = -1220.0, y = -832.0,  z = 29.5 }, label = '市区屋顶 4',         type = 'building',landing = 'rooftop' },
        { coords = { x = -583.5,  y = -931.0,  z = 37.0 }, label = '市区屋顶 5',         type = 'building',landing = 'rooftop' },
        { coords = { x = -144.5,  y = -593.5,  z = 211.5 }, label = 'Arcadius 商业中心',         type = 'skyscraper',landing = 'rooftop' },
        { coords = { x = -286.5,  y = -618.0,  z = 50.5 },  label = 'Daily Globe 报社',         type = 'journal',landing = 'rooftop' },
        { coords = { x = 1184.0,  y = -3222.0, z = 6.0 },    label = '极速乐园码头(工业区)',   type = 'industrial',landing = 'ground' },
        { coords = { x = 910.5,   y = -1681.5, z = 51.0 },    label = '工业区 1',   type = 'industrial',landing = 'rooftop' },
        { coords = { x = 965.5,   y = 42.0,    z = 123.0 },  label = '名钻假日赌场屋顶',      type = 'casino',    landing = 'rooftop' },
        { coords = { x = -1396.5, y = 54.5,    z = 53.5 },   label = '高尔夫球俱乐部停机坪',  type = 'leisure',   landing = 'ground' },
        { coords = { x = -2043.5, y = -1031.5, z = 12.0 },    label = '太平洋离岸超级游艇',    type = 'leisure',   landing = 'rooftop' },
    },
}
