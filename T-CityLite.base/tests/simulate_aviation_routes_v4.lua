-- tests/simulate_aviation_routes_v4.lua
-- v4: 读取真实 address_pools.lua + same-airport guard
local src = io.open('T-CityLite.base/resources/[custom]/custom-quest/config/quests/address_pools.lua'):read('*all')

local function extractPool(name)
    local s = src:find(name .. '%s*=%s*%{')
    if not s then return {} end
    local d, ps = 0, nil
    for i = s, #src do
        local c = src:sub(i,i)
        if c == '{' then d = d + 1; if not ps then ps = i + 1 end
        elseif c == '}' then d = d - 1
            if d == 0 then
                local content = src:sub(ps, i - 1)
                local entries, pos = {}, 1
                while pos <= #content do
                    local es = content:find('%s*%{%s*coords', pos)
                    if not es then break end
                    local ed, j = 0, es
                    for k = es, #content do
                        local ch = content:sub(k,k)
                        if ch == '{' then ed = ed + 1
                        elseif ch == '}' then ed = ed - 1; if ed == 0 then j = k; break end end
                    end
                    local entry = content:sub(es, j)
                    local cx = entry:match('coords.-x%s*=%s*([%d%.%-]+)')
                    local cy = entry:match('coords.-y%s*=%s*([%d%.%-]+)')
                    local cz = entry:match('coords.-z%s*=%s*([%d%.%-]+)')
                    local label = entry:match("label%s*=%s*'([^']+)'")
                    local etype = entry:match("type%s*=%s*'([^']+)'")
                    local terminal = entry:match('terminal%s*=%s*([%a]+)')
                    local runways = entry:match('runways%s*=%s*(%d+)')
                    local restricted = entry:match('restricted%s*=%s*([%a]+)')
                    local landing = entry:match("landing%s*=%s*'([^']+)'")
                    if cx and cy then
                        table.insert(entries, {
                            x=tonumber(cx), y=tonumber(cy), z=tonumber(cz or '0'),
                            label=label or '?', type=etype, terminal=terminal,
                            runways=tonumber(runways), restricted=restricted=='true',
                            landing=landing,
                        })
                    end
                    pos = j + 1
                end
                return entries
            end
        end
    end
    return {}
end

local airports = extractPool('aviation_airports')
local helipads = extractPool('aviation_helipads')

-- 排除 restricted
local function available(pool)
    local r = {}
    for _, a in ipairs(pool) do if not a.restricted then r[#r+1] = a end end
    return r
end

local airportsFree = available(airports)
local helipadsFree = available(helipads)

-- 过滤
local function filterPool(pool, fn)
    local r = {}
    for _, a in ipairs(pool) do if fn(a) then r[#r+1] = a end end
    return r
end

-- airport name extractor
local function airport(label)
    return label and label:match('^(%S+)') or label
end

-- 动态航路计算
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function computeWP(pct, alt, dep, arr)
    return {
        x = dep.x + (arr.x - dep.x) * pct,
        y = dep.y + (arr.y - dep.y) * pct,
        z = alt < 0 and arr.z + 5 or alt,
    }
end
local function coordStr(c) return string.format('(%.0f, %.0f, %.0fm)', c.x, c.y, c.z) end

local rounds = 500
local sp = string.rep

-- ═══════════════════════════════════════════════════════════
-- ✈️ 固定翼
-- ═══════════════════════════════════════════════════════════
do
    local dCandidates = airportsFree  -- all non-restricted
    local aCandidates = airportsFree

    local depCounts, arrCounts, pairsCounts = {}, {}, {}
    local sampleRoutes = {}

    for _ = 1, rounds do
        local dep = dCandidates[math.random(1, #dCandidates)]
        -- same-airport guard: exclude departure airport from arrival pool
        local depPrefix = airport(dep.label)
        local arrPool = {}
        for _, a in ipairs(aCandidates) do
            if airport(a.label) ~= depPrefix then table.insert(arrPool, a) end
        end
        if #arrPool == 0 then arrPool = aCandidates end  -- fallback
        local arr = arrPool[math.random(1, #arrPool)]

        depCounts[airport(dep.label)] = (depCounts[airport(dep.label)] or 0) + 1
        arrCounts[airport(arr.label)] = (arrCounts[airport(arr.label)] or 0) + 1
        local pk = airport(dep.label) .. ' → ' .. airport(arr.label)
        pairsCounts[pk] = (pairsCounts[pk] or 0) + 1

        if not sampleRoutes[pk] then
            local wps = {}
            for _, wp in ipairs({{pct=0.20,alt=300,cp='🛫爬升'},{pct=0.50,alt=300,cp='🛩️巡航'},{pct=0.80,alt=80,cp='⬇️下降'}}) do
                table.insert(wps, {label=wp.cp, coords=computeWP(wp.pct, wp.alt, dep, arr)})
            end
            sampleRoutes[pk] = { dep=dep, arr=arr, wps=wps, dist=dist(dep,arr) }
        end
    end

    local function sortMap(m)
        local t = {}; for k,v in pairs(m) do t[#t+1]={k,v} end
        table.sort(t, function(a,b) return a[2]>b[2] end); return t
    end

    print(sp('═', 72))
    print('  ✈️  固定翼 — 动态航路模拟 ' .. rounds .. ' 次')
    print(sp('═', 72))

    local totalSpots = #airportsFree
    local lsiaSpots = 0; for _, a in ipairs(airportsFree) do if airport(a.label)=='LSIA' then lsiaSpots=lsiaSpots+1 end end
    print(('\n📊 %d 个停机位: LSIA×%d + Sandy×1 + Grapeseed×1 (Paleto/Zancudo 排除)'):format(totalSpots, lsiaSpots))
    print('🔒 same_airport_allowed=false: 禁止同机场互飞\n')

    print('Departure 机场分布:')
    for _, kv in ipairs(sortMap(depCounts)) do
        print(('  %-10s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, kv[2]/rounds*100, sp('█', kv[2]/rounds/2)))
    end

    print('\nArrival 机场分布:')
    for _, kv in ipairs(sortMap(arrCounts)) do
        print(('  %-10s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, kv[2]/rounds*100, sp('█', kv[2]/rounds/2)))
    end

    print('\n航线组合分布:')
    for _, kv in ipairs(sortMap(pairsCounts)) do
        print(('  %-30s %3d/%-3d %5.1f%%'):format(kv[1], kv[2], rounds, kv[2]/rounds*100))
    end

    print('\n🗺️  每条航线的实际航路坐标:')
    print(sp('─', 72))
    local ss = {}; for k,sr in pairs(sampleRoutes) do ss[#ss+1]={k,sr} end
    table.sort(ss, function(a,b) return a[2].dist < b[2].dist end)
    for _, kv in ipairs(ss) do
        local sr = kv[2]
        print(('\n  %s  (%.0fm, %.1fkm)'):format(kv[1], sr.dist, sr.dist/1000))
        print(('    起飞: %s %s'):format(sr.dep.label, coordStr(sr.dep)))
        for j, wp in ipairs(sr.wps) do
            local dFromDep = dist(sr.dep, wp.coords)
            print(('    航路%d: %s %s  (距起飞 %.0fm)'):format(j, wp.label, coordStr(wp.coords), dFromDep))
        end
        print(('    降落: %s %s'):format(sr.arr.label, coordStr(sr.arr)))
    end
end

-- ═══════════════════════════════════════════════════════════
-- 🚁 直升机
-- ═══════════════════════════════════════════════════════════
do
    local dCandidates = filterPool(helipadsFree, function(a) return a.type == 'public' end)
    local aCandidates = filterPool(helipadsFree, function(a) return a.type == 'hospital' end)

    print('\n\n' .. sp('═', 72))
    print('  🚁 直升机 — 动态航路模拟 ' .. rounds .. ' 次')
    print(sp('═', 72))
    print(('\n📊 %d 个公共停机坪 → %d 个医院停机坪 (same_airport_allowed=true)'):format(#dCandidates, #aCandidates))

    local depCounts, arrCounts, pairsCounts = {}, {}, {}
    local sampleRoutes = {}

    for _ = 1, rounds do
        local dep = dCandidates[math.random(1, #dCandidates)]
        local arr = aCandidates[math.random(1, #aCandidates)]

        depCounts[dep.label] = (depCounts[dep.label] or 0) + 1
        arrCounts[arr.label] = (arrCounts[arr.label] or 0) + 1
        local pk = dep.label .. ' → ' .. arr.label
        pairsCounts[pk] = (pairsCounts[pk] or 0) + 1

        if not sampleRoutes[pk] then
            local wps = {}
            for _, wp in ipairs({{pct=0.25,alt=80,cp='🏙️出航'},{pct=0.60,alt=60,cp='🏥进场'},{pct=0.85,alt=-1,cp='🚁着陆'}}) do
                table.insert(wps, {label=wp.cp, coords=computeWP(wp.pct, wp.alt, dep, arr)})
            end
            sampleRoutes[pk] = { dep=dep, arr=arr, wps=wps, dist=dist(dep,arr) }
        end
    end

    local function sortMap(m)
        local t = {}; for k,v in pairs(m) do t[#t+1]={k,v} end
        table.sort(t, function(a,b) return a[2]>b[2] end); return t
    end

    print('\nDeparture 分布:')
    for _, kv in ipairs(sortMap(depCounts)) do
        print(('  %-30s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, kv[2]/rounds*100, sp('█', kv[2]/rounds/2)))
    end

    print('\nArrival 分布:')
    for _, kv in ipairs(sortMap(arrCounts)) do
        print(('  %-30s %3d/%-3d %5.1f%% %s'):format(kv[1], kv[2], rounds, kv[2]/rounds*100, sp('█', kv[2]/rounds/2)))
    end

    print('\n航线组合分布:')
    for _, kv in ipairs(sortMap(pairsCounts)) do
        print(('  %-55s %3d/%-3d %5.1f%%'):format(kv[1], kv[2], rounds, kv[2]/rounds*100))
    end

    print('\n🗺️  每条航线的实际航路坐标:')
    print(sp('─', 72))
    local ss = {}; for k,sr in pairs(sampleRoutes) do ss[#ss+1]={k,sr} end
    table.sort(ss, function(a,b) return a[2].dist < b[2].dist end)
    for _, kv in ipairs(ss) do
        local sr = kv[2]
        print(('\n  %s  (%.0fm, %.1fkm)'):format(kv[1], sr.dist, sr.dist/1000))
        print(('    起飞: %s %s'):format(sr.dep.label, coordStr(sr.dep)))
        for j, wp in ipairs(sr.wps) do
            print(('    航路%d: %s %s  (z=%d)'):format(j, wp.label, coordStr(wp.coords), wp.coords.z))
        end
        print(('    降落: %s %s'):format(sr.arr.label, coordStr(sr.arr)))
    end
end
print('')
