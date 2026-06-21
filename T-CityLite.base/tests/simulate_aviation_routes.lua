-- tests/simulate_aviation_routes.lua
-- 模拟 Mixed 航空路线随机选择，输出分布统计
-- 用法: lua tests/simulate_aviation_routes.lua [both|airplane|helicopter] [次数]

local filter = arg[1] or 'both'
local rounds = tonumber(arg[2]) or 200

-- ═══ 加载地址池 (直接硬编码 — 避免 Lua 正则解析嵌套 {coords={}} 的复杂度) ═══
local airports = {
    { x=-1150,y=-2650,z=13,  label='LSIA 国际机场',    type='international',terminal='true', runways=3,restricted=false},
    { x=1750, y=3250, z=41,  label='Sandy Shores 机场', type='regional',     terminal='false',runways=2,restricted=false},
    { x=2100, y=4800, z=41,  label='Grapeseed 跑道',    type='rural',         terminal='false',runways=1,restricted=false},
    { x=-400, y=6200, z=32,  label='Paleto Bay 跑道',   type='rural',         terminal='false',runways=1,restricted=false},
    { x=-2300,y=3250, z=33,  label='Fort Zancudo 基地', type='military',      terminal='true', runways=1,restricted=true},
}

local helipads = {
    { x=-725,  y=-1444, z=5,   label='Vespucci 公共北',    type='public',     landing='ground' },
    { x=-745,  y=-1468, z=5,   label='Vespucci 公共南',    type='public',     landing='ground' },
    { x=-1178, y=-2846, z=14,  label='LSIA 直升机区1',     type='airport',    landing='ground' },
    { x=-1146, y=-2865, z=14,  label='LSIA 直升机区2',     type='airport',    landing='ground' },
    { x=-1113, y=-2884, z=14,  label='LSIA 直升机区3',     type='airport',    landing='ground' },
    { x=1770,  y=3240, z=42,   label='Sandy 机场停机坪',   type='airport',    landing='ground' },
    { x=2098,  y=4819, z=41,   label='McKenzie 麦肯齐',    type='airport',    landing='ground' },
    { x=-506,  y=-309, z=73,   label='中心医院西南',       type='hospital',   landing='rooftop' },
    { x=-448,  y=-306, z=78,   label='中心医院东北',       type='hospital',   landing='rooftop' },
    { x=352,   y=-588, z=74,   label='Pillbox Hill 诊所',  type='hospital',   landing='rooftop' },
    { x=1848,  y=3658, z=34,   label='Sandy Shores 诊所',  type='rural',      landing='ground' },
    { x=363,   y=-1598,z=37,   label='Davis 警局屋顶',     type='police',     landing='rooftop' },
    { x=-1095, y=-835, z=37,   label='Vespucci 警局屋顶',  type='police',     landing='rooftop' },
    { x=449,   y=-981, z=43,   label='Mission Row 警局',   type='police',     landing='rooftop' },
    { x=580,   y=12,   z=103,  label='Vinewood 警局屋顶',  type='police',     landing='rooftop' },
    { x=-475,  y=5988, z=31,   label='Paleto Bay 警局',    type='police',     landing='ground' },
    { x=2510,  y=-342, z=118,  label='NOOSE 屋顶北',       type='government', landing='rooftop' },
    { x=2511,  y=-426, z=118,  label='NOOSE 屋顶南',       type='government', landing='rooftop' },
    { x=500,   y=-3100,z=6,    label='军港码头',           type='military',   landing='ground', restricted=true },
    { x=-75,   y=-819, z=326,  label='Maze Bank 塔顶',     type='skyscraper', landing='rooftop' },
    { x=-1582, y=-570, z=116,  label='LomBank 屋顶',       type='building',   landing='rooftop' },
    { x=-1391, y=-478, z=91,   label='Maze Bank 屋顶',     type='building',   landing='rooftop' },
    { x=-1007, y=-415, z=80,   label='市区屋顶 1',         type='building',   landing='rooftop' },
    { x=-913,  y=-378, z=138,  label='市区屋顶 2',         type='building',   landing='rooftop' },
    { x=-1011, y=-757, z=82,   label='市区屋顶 3',         type='building',   landing='rooftop' },
    { x=-1220, y=-832, z=29,   label='市区屋顶 4',         type='building',   landing='rooftop' },
    { x=-583,  y=-931, z=37,   label='市区屋顶 5',         type='building',   landing='rooftop' },
    { x=-144,  y=-593, z=211,  label='Arcadius 商业中心',  type='skyscraper', landing='rooftop' },
    { x=-286,  y=-618, z=50,   label='Daily Globe 报社',   type='journal',    landing='rooftop' },
    { x=1184,  y=-3222,z=6,    label='极速乐园码头',       type='industrial', landing='ground' },
    { x=910,   y=-1681,z=51,   label='工业区屋顶',         type='industrial', landing='rooftop' },
    { x=965,   y=42,   z=123,  label='名钻赌场屋顶',       type='casino',     landing='rooftop' },
    { x=-1396, y=54,   z=53,   label='高尔夫俱乐部',       type='leisure',    landing='ground' },
    { x=-2043, y=-1031,z=12,   label='太平洋超级游艇',     type='leisure',    landing='rooftop' },
}

print(('📂 硬编码: %d 机场 + %d 停机坪'):format(#airports, #helipads))

-- ═══ 路线定义 ═══
local routes = {}

if filter == 'both' or filter == 'airplane' then
    routes.airplane = {
        name = '✈️  固定翼', rewards = '$2000-3500 + 40 rep',
        depFilter = function(a) return a.terminal == 'true' and not a.restricted end,
        arrFilter = function(a) return a.terminal ~= 'true' and not a.restricted end,
        pool = airports,
        wps = {
            { x=-1000,y=-2400,z=300, label='🛫 爬升航路点',  cp='ring 35m ht=60' },
            { x=1200, y=2800, z=300, label='🛩️ 巡航中点',   cp='ring 40m ht=60' },
            { x=1900, y=4200, z=80,  label='⬇️ 下降进场',   cp='ring 30m ht=50' },
        },
    }
end

if filter == 'both' or filter == 'helicopter' then
    routes.helicopter = {
        name = '🚁 直升机', rewards = '$1200-2200 + 25 rep',
        depFilter = function(a) return a.type == 'public' and not a.restricted end,
        arrFilter = function(a) return a.type == 'hospital' and not a.restricted end,
        pool = helipads,
        wps = {
            { x=-300,y=-1100,z=80,  label='🏙️ 市区低空引导', cp='cylinder 25m ht=40' },
            { x=200, y=-700, z=60,  label='🏥 医院进场点',   cp='cylinder 20m ht=35' },
            { x=300, y=-580, z=43,  label='🚁 楼顶着陆区',   cp='cylinder 15m ht=25' },
        },
    }
end

-- ═══ 模拟 ═══
local function dist(a, b) return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2) end

for rn, route in pairs(routes) do
    local depCounts, arrCounts, pairsCounts = {}, {}, {}
    local totalDist = 0
    local dCandidates, aCandidates = {}, {}

    -- 统计候选池
    for _, a in ipairs(route.pool) do
        if route.depFilter(a) then table.insert(dCandidates, a) end
        if route.arrFilter(a) then table.insert(aCandidates, a) end
    end

    for _ = 1, rounds do
        local dc = dCandidates
        local dep = dc[math.random(1, #dc)]
        local ac = {}
        for _, a in ipairs(aCandidates) do
            if a.label ~= dep.label then table.insert(ac, a) end
        end
        if #ac == 0 then ac = aCandidates end
        local arr = ac[math.random(1, #ac)]

        depCounts[dep.label] = (depCounts[dep.label] or 0) + 1
        arrCounts[arr.label] = (arrCounts[arr.label] or 0) + 1
        local pk = dep.label .. ' → ' .. arr.label
        pairsCounts[pk] = (pairsCounts[pk] or 0) + 1
        totalDist = totalDist + dist(dep, arr)
    end

    -- ═══ 输出 ═══
    local function sortMap(m)
        local t = {}; for k, v in pairs(m) do t[#t+1] = {k, v} end
        table.sort(t, function(a,b) return a[2] > b[2] end); return t
    end
    local sp = string.rep

    print('')
    print(sp('═', 65))
    print(('  %s 路线模拟 %d 次'):format(route.name, rounds))
    print(sp('═', 65))

    print('\n🔒 不变项:')
    print('  步骤链: 绑定→装载→航路1→航路2→航路3→降落→卸载→归还 (8步)')
    print(('  奖励: %s'):format(route.rewards))
    for i, wp in ipairs(route.wps) do
        print(('  航路%d: %s (%.0f, %.0f, %.0fm) [%s]'):format(i, wp.label, wp.x, wp.y, wp.z, wp.cp))
    end

    print('\n🎲 Departure 候选: ' .. #dCandidates .. ' 个')
    for _, kv in ipairs(sortMap(depCounts)) do
        local pct = kv[2] / rounds * 100
        print(('  %-28s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, pct, sp('█', pct/2)))
    end

    print('\n🎲 Arrival 候选: ' .. #aCandidates .. ' 个')
    for _, kv in ipairs(sortMap(arrCounts)) do
        local pct = kv[2] / rounds * 100
        print(('  %-28s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, pct, sp('█', pct/2)))
    end

    print('\n🗺️  Top 15 出发→到达:')
    local spairs = sortMap(pairsCounts)
    for i = 1, math.min(15, #spairs) do
        local kv = spairs[i]
        print(('  %2d. %s  (%d次, %.1f%%)'):format(i, kv[1], kv[2], kv[2]/rounds*100))
    end

    print(('\n📏 平均距离: %.0fm (%.1fkm) | 候选组合: %d×%d = %d 种'):format(
        totalDist/rounds, totalDist/rounds/1000, #dCandidates, #aCandidates, #dCandidates * #aCandidates))
end
print('')
