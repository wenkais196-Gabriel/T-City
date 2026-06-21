-- tests/simulate_aviation_routes_v2.lua
-- v2: 动态航路点 (pct+alt → 实际坐标) 模拟
-- 用法: lua tests/simulate_aviation_routes_v2.lua [both|airplane|helicopter] [次数]

local filter = arg[1] or 'both'
local rounds = tonumber(arg[2]) or 100

-- ═══ 地址池 ═══
local airports = {
    { x=-1150,y=-2650,z=13,  label='LSIA 国际机场',    terminal='true'},
    { x=1750, y=3250, z=41,  label='Sandy Shores 机场', terminal='false'},
    { x=2100, y=4800, z=41,  label='Grapeseed 跑道',    terminal='false'},
    { x=-400, y=6200, z=32,  label='Paleto Bay 跑道',   terminal='false'},
}

local helipads = {
    { x=-725,y=-1444,z=5,   label='Vespucci 公共北',  type='public'},
    { x=-745,y=-1468,z=5,   label='Vespucci 公共南',  type='public'},
    { x=-506,y=-309, z=73,  label='中心医院西南',    type='hospital'},
    { x=-448,y=-306, z=78,  label='中心医院东北',    type='hospital'},
    { x=352, y=-588, z=74,  label='Pillbox Hill 诊所',type='hospital'},
}

-- ═══ 路线定义 ═══
local routes = {}

if filter == 'both' or filter == 'airplane' then
    routes.airplane = {
        name='✈️  固定翼', rewards='$2000-3500 +40rep',
        depFilter=function(a) return true end,  -- 不限 terminal
        arrFilter=function(a) return true end,
        pool=airports,
        wps={
            { pct=0.20, alt=300, cp='🛫 爬升(ring 35m)' },
            { pct=0.50, alt=300, cp='🛩️ 巡航(ring 40m)' },
            { pct=0.80, alt=80,  cp='⬇️ 下降(ring 30m)' },
        },
    }
end

if filter == 'both' or filter == 'helicopter' then
    routes.helicopter = {
        name='🚁 直升机', rewards='$1200-2200 +25rep',
        depFilter=function(a) return a.type=='public' end,
        arrFilter=function(a) return a.type=='hospital' end,
        pool=helipads,
        wps={
            { pct=0.25, alt=80,  cp='🏙️ 出航(cyl 25m)' },
            { pct=0.60, alt=60,  cp='🏥 进场(cyl 20m)' },
            { pct=0.85, alt=-1,  cp='🚁 着陆(cyl 15m)' },
        },
    }
end

-- ═══ 模拟 ═══
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function computeWP(pct, alt, dep, arr)
    return {
        x = dep.x + (arr.x - dep.x) * pct,
        y = dep.y + (arr.y - dep.y) * pct,
        z = alt < 0 and arr.z + 5 or alt,
    }
end

local function coordStr(c) return string.format('(%.0f, %.0f, %.0fm)', c.x, c.y, c.z) end

for rn, route in pairs(routes) do
    local depCounts, arrCounts, pairsCounts = {}, {}, {}
    local dCandidates, aCandidates = {}, {}

    for _, a in ipairs(route.pool) do
        if route.depFilter(a) then table.insert(dCandidates, a) end
        if route.arrFilter(a) then table.insert(aCandidates, a) end
    end

    -- 收集每条 dep→arr 组合的航路坐标 (只模拟一次取样本)
    local sampleRoutes = {}

    for _ = 1, rounds do
        local dep = dCandidates[math.random(1, #dCandidates)]
        local ac = {}
        for _, a in ipairs(aCandidates) do if a.label ~= dep.label then table.insert(ac, a) end end
        if #ac == 0 then ac = aCandidates end
        local arr = ac[math.random(1, #ac)]

        depCounts[dep.label] = (depCounts[dep.label] or 0) + 1
        arrCounts[arr.label] = (arrCounts[arr.label] or 0) + 1
        local pk = dep.label .. ' → ' .. arr.label
        pairsCounts[pk] = (pairsCounts[pk] or 0) + 1

        -- 记录每条组合的航路点(只记录第一次)
        if not sampleRoutes[pk] then
            local wps = {}
            for _, wp in ipairs(route.wps) do
                local c = computeWP(wp.pct, wp.alt, dep, arr)
                table.insert(wps, { label=wp.cp, coords=c })
            end
            sampleRoutes[pk] = { dep=dep, arr=arr, wps=wps, dist=dist(dep,arr) }
        end
    end

    -- ═══ 输出 ═══
    local function sortMap(m)
        local t = {}; for k,v in pairs(m) do t[#t+1]={k,v} end
        table.sort(t, function(a,b) return a[2]>b[2] end); return t
    end
    local sp = string.rep

    print('')
    print(sp('═', 72))
    print(('  %s — 动态航路模拟 %d 次'):format(route.name, rounds))
    print(sp('═', 72))

    -- 不变项
    print('\n🔒 不变项:')
    print('  步骤链: 绑定→装载→航路1→航路2→航路3→降落→卸载→归还 (8步)')
    print(('  奖励: %s'):format(route.rewards))
    print('  航路参数:')
    for i, wp in ipairs(route.wps) do
        local altStr = wp.alt < 0 and 'arr.z+5' or tostring(wp.alt)
        print(('    航路%d: pct=%.2f alt=%s [%s]'):format(i, wp.pct, altStr, wp.cp))
    end

    -- Departure 分布
    print(('\n🎲 Departure (%d候选):'):format(#dCandidates))
    for _, kv in ipairs(sortMap(depCounts)) do
        local pct = kv[2]/rounds*100
        print(('  %-25s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, pct, sp('█', pct/2)))
    end

    -- Arrival 分布
    print(('\n🎲 Arrival (%d候选):'):format(#aCandidates))
    for _, kv in ipairs(sortMap(arrCounts)) do
        local pct = kv[2]/rounds*100
        print(('  %-25s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, pct, sp('█', pct/2)))
    end

    -- 每条组合的详细航路 (按距离排序)
    print('\n🗺️  每条 dep→arr 组合的实际航路坐标:')
    print(sp('─', 72))
    local sortedSamples = {}
    for k, sr in pairs(sampleRoutes) do table.insert(sortedSamples, {k, sr}) end
    table.sort(sortedSamples, function(a,b) return a[2].dist < b[2].dist end)
    for i = 1, math.min(15, #sortedSamples) do
        local kv = sortedSamples[i]
        local sr = kv[2]
        print(('\n  #%d %s  (%.0fm, %.1fkm)'):format(i, kv[1], sr.dist, sr.dist/1000))
        print(('    起飞: %s'):format(coordStr(sr.dep)))
        for j, wp in ipairs(sr.wps) do
            print(('    航路%d: %s  %s'):format(j, coordStr(wp.coords), wp.label))
        end
        print(('    降落: %s'):format(coordStr(sr.arr)))
    end
end
print('')
