-- tests/simulate_aviation_routes_v3.lua
-- v3: 读取实际 address_pools.lua 中的真实坐标
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
                    if cx and cy then
                        table.insert(entries, {
                            x=tonumber(cx), y=tonumber(cy), z=tonumber(cz or '0'),
                            label=label or '?', type=etype, terminal=terminal,
                            runways=tonumber(runways), restricted=restricted=='true',
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

print(('📂 真实配置: %d 机场 + %d 停机坪'):format(#airports, #helipads))

-- 统计
local function countFilter(pool, fn)
    local n = 0; for _, a in ipairs(pool) do if fn(a) then n = n + 1 end end; return n
end

print('\n✈️  机场分布:')
for _, a in ipairs(airports) do
    local tags = {}
    if a.restricted then table.insert(tags, '⚠️restricted') end
    if a.terminal == 'true' then table.insert(tags, 'terminal') end
    print(('  %-35s (%.0f, %.0f, %.0fm) runways=%s %s'):format(
        a.label, a.x, a.y, a.z, tostring(a.runways), table.concat(tags, ' ')))
end

print('\n🚁 停机坪类型分布:')
local htypes = {}
for _, h in ipairs(helipads) do htypes[h.type] = (htypes[h.type] or 0) + 1 end
for t, n in pairs(htypes) do print(('  %-15s %d 个'):format(t, n)) end

-- 检查问题
print('\n🔍 检查:')
-- 重复坐标
local seen = {}
for _, a in ipairs(airports) do
    local key = ('%.0f,%.0f'):format(a.x, a.y)
    if seen[key] then
        print(('  ⚠️ 重复坐标: %s ↔ %s (%s)'):format(a.label, seen[key], key))
    else seen[key] = a.label end
end
for _, h in ipairs(helipads) do
    local key = ('%.0f,%.0f'):format(h.x, h.y)
    if seen[key] then
        print(('  ⚠️ 重复坐标: %s ↔ %s (%s)'):format(h.label, seen[key], key))
    end
end

-- restricted 机场是否会被选中
local restrictedCount = countFilter(airports, function(a) return a.restricted end)
if restrictedCount > 0 then
    print(('  ⚠️ %d 个 restricted 机场当前会被 civilian quest 随机选中 (Fort Zancudo)!'):format(restrictedCount))
    print('    建议: departure/arrival 加 filter = { restricted = false }')
end

-- Paleto 是否缺失
local hasPaleto = false
for _, a in ipairs(airports) do if a.label:find('Paleto') then hasPaleto = true end end
if not hasPaleto then
    print('  ⚠️ Paleto Bay 跑道缺失 (旧坐标 -400, 6200, 32)，确认是有意删除?')
end

-- LSIA 占比
local lsiaCount = countFilter(airports, function(a) return a.label:find('LSIA') ~= nil end)
print(('  📊 LSIA 占 %d/%d = %.0f%%，Departure 将高度偏向 LSIA'):format(lsiaCount, #airports, lsiaCount/#airports*100))
print('')
