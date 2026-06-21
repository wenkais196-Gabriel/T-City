-- quest_address_resolver.lua — 配送地址池解析器 (v0.8b)
--
-- 职责:
--   1. 加载 config/quests/address_pools.lua 中的地址池
--   2. 按距离约束随机选取地址
--   3. 为任务模板中的 address_pool 引用注入具体坐标
--
-- 使用方式:
--   在任务步骤的 data 中用 address_pool 替代 coords:
--     address_pool = { pool = 'downtown_residential', min_dist = 500, max_dist = 5000 }
--
--   TriggerQuest 时由 ResolveQuestAddresses 自动解析

QuestAddressResolver = {}

-- 加载地址池
local pools = nil

local function loadPools()
    if pools then return pools end
    local raw = LoadResourceFile(GetCurrentResourceName(), 'config/quests/address_pools.lua')
    if not raw then
        print('[quest-address-resolver] ⚠️ LoadResourceFile 返回 nil — 文件未找到或未在 fxmanifest files{} 中声明')
    else
        print(('[quest-address-resolver] 📂 LoadResourceFile 成功，大小: %d bytes'):format(#raw))
        -- pcall(load(raw)) = pcall(load返回的函数) → 直接执行 chunk
        -- result = chunk 的返回值（table），不是函数!
        local ok, result = pcall(load(raw))
        if not ok then
            print(('[quest-address-resolver] ❌ 加载/执行失败: %s'):format(tostring(result)))
        elseif type(result) == 'table' then
            pools = result
            local count = 0
            for _ in pairs(pools) do count = count + 1 end
            print(('[quest-address-resolver] 📂 地址池加载成功: %d 个池'):format(count))
        else
            print(('[quest-address-resolver] ❌ 返回值类型异常: %s'):format(type(result)))
        end
    end
    if not pools then
        pools = {}
        print('[quest-address-resolver] ⚠️ 地址池加载失败，返回空池')
    end
    return pools
end

--- 随机选取一个满足距离约束的地址
---@param poolName string
---@param originCoords table {x,y,z}
---@param minDist number 最小距离（米），默认 100
---@param maxDist number 最大距离（米），默认 10000
---@return table|nil { coords={x,y,z}, label, district }
function QuestAddressResolver.PickAddress(poolName, originCoords, minDist, maxDist)
    local allPools = loadPools()
    local pool = allPools[poolName]
    if not pool or #pool == 0 then
        print(('[quest-address-resolver] ⚠️ 地址池 "%s" 不存在或为空'):format(poolName))
        return nil
    end

    minDist = minDist or 100
    maxDist = maxDist or 10000

    -- 打乱顺序以避免每次都选前几个
    local shuffled = {}
    for i, addr in ipairs(pool) do
        shuffled[i] = addr
    end
    for i = #shuffled, 2, -1 do
        local j = math.random(1, i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end

    for _, addr in ipairs(shuffled) do
        local dx = originCoords.x - addr.coords.x
        local dy = originCoords.y - addr.coords.y
        local dz = (originCoords.z or 0) - (addr.coords.z or 0)
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist >= minDist and dist <= maxDist then
            return { coords = addr.coords, label = addr.label, district = addr.district, distance = math.floor(dist) }
        end
    end

    -- 没有满足距离约束的 → 返回距离最近的那个
    print(('[quest-address-resolver] ⚠️ 池 "%s" 中无满足距离 [%d, %d]m 的地址，返回最近地址'):format(
        poolName, minDist, maxDist))
    return pool[math.random(1, #pool)]
end

--- 选取 N 个不相邻的地址（用于多站配送）
---@param poolName string
---@param originCoords table
---@param count number
---@param minDistBetween number 站间最小距离（默认 400m）
---@param maxDist number 最远距离（默认 10000）
---@return table[] 地址列表
function QuestAddressResolver.PickMultiple(poolName, originCoords, count, minDistBetween, maxDist)
    local allPools = loadPools()
    local pool = allPools[poolName]
    if not pool or #pool == 0 then return {} end

    minDistBetween = minDistBetween or 400
    maxDist = maxDist or 10000
    count = math.min(count or 3, #pool)

    local selected = {}
    local attempts = 0
    local maxAttempts = 100

    while #selected < count and attempts < maxAttempts do
        attempts = attempts + 1
        local addr = pool[math.random(1, #pool)]

        -- 距离原点检查
        local dx = originCoords.x - addr.coords.x
        local dy = originCoords.y - addr.coords.y
        local dz = (originCoords.z or 0) - (addr.coords.z or 0)
        local distOrigin = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distOrigin <= maxDist then
            -- 距离已选地址检查
            local tooClose = false
            for _, existing in ipairs(selected) do
                local dx2 = addr.coords.x - existing.coords.x
                local dy2 = addr.coords.y - existing.coords.y
                local dz2 = (addr.coords.z or 0) - (existing.coords.z or 0)
                local d = math.sqrt(dx2 * dx2 + dy2 * dy2 + dz2 * dz2)
                if d < minDistBetween then tooClose = true; break end
            end
            if not tooClose then
                selected[#selected + 1] = {
                    coords = addr.coords,
                    label = addr.label,
                    district = addr.district,
                    distance = math.floor(distOrigin),
                }
            end
        end
    end

    return selected
end

--- 从任务模板中解析 address_pool 引用，注入具体坐标
--- 同时更新同步骤的 validator_data.destCoords 和紧随其后的 interact 步骤
---@param template table 任务模板
---@param pickupCoords table 取货点坐标（用于距离计算）
function QuestAddressResolver.ResolveQuestAddresses(template, pickupCoords)
    if not template or not template.steps then return end
    if not pickupCoords then
        pickupCoords = { x = 0, y = 0, z = 0 }
    end

    for i, step in ipairs(template.steps) do
        if step.data and step.data.address_pool then
            local poolRef = step.data.address_pool
            local poolName = poolRef.pool
            local minDist = poolRef.min_distance
            local maxDist = poolRef.max_distance or 15000

            if poolRef.count and poolRef.count > 1 then
                -- 多站选取
                local addresses = QuestAddressResolver.PickMultiple(
                    poolName, pickupCoords, poolRef.count,
                    poolRef.min_dist_between or 400, maxDist)
                step.data._resolved_addresses = addresses
                step.data.address_pool = nil
            else
                -- 单站选取
                local addr = QuestAddressResolver.PickAddress(poolName, pickupCoords, minDist, maxDist)
                if addr then
                    -- 主步骤坐标
                    step.data.coords = addr.coords
                    -- validator_data 中的 destCoords（如果存在）
                    if step.data.validator_data and step.data.validator_data.destCoords then
                        step.data.validator_data.destCoords = addr.coords
                    end
                    -- 紧随其后的 interact/unload 步骤也用同一坐标
                    local nextStep = template.steps[i + 1]
                    if nextStep and nextStep.type == 'interact' then
                        if nextStep.data then
                            nextStep.data.coords = addr.coords
                        end
                    end
                    step.data._resolved_label = addr.label
                    step.data._resolved_distance = addr.distance
                    step.data.address_pool = nil
                    print(('[quest-address-resolver] 📍 %s → %s (%.0fm)'):format(
                        poolName, addr.label, addr.distance or 0))
                end
            end
        end
    end
end

-- 启动时加载
CreateThread(function()
    Wait(1000)
    loadPools()
    local count = 0
    for name, pool in pairs(pools) do
        count = count + #pool
    end
    print(('[quest-address-resolver] ✅ 已加载 %d 个地址池，共 %d 个地址'):format(
        tablelength(pools), count))
end)

-- 辅助: 表长度
function tablelength(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

--- v0.11: 解析单个地址池引用（用于 aviation_routes departure/arrival）
---@param routeRef table { pool = 'aviation_helipads', filter = { type = 'public' } }
---@param excludePrefix string|nil  排除 label 以此前缀开头的地址 (用于 same-airport guard)
---@return table|nil { x, y, z, label }
function QuestAddressResolver.ResolveSingleAddress(routeRef, excludePrefix)
    if not routeRef or not routeRef.pool then return nil end

    local allPools = loadPools()
    local pool = allPools[routeRef.pool]
    if not pool or #pool == 0 then
        print(('[quest-address-resolver] ⚠️ 地址池不存在或为空: %s'):format(tostring(routeRef.pool)))
        return nil
    end

    -- 过滤
    local candidates = {}
    for _, addr in ipairs(pool) do
        local excluded = excludePrefix and addr.label and addr.label:match('^' .. excludePrefix)
        if not excluded then
            if routeRef.filter then
                local match = true
                for k, v in pairs(routeRef.filter) do
                    if addr[k] ~= v then match = false; break end
                end
                if match then table.insert(candidates, addr) end
            else
                table.insert(candidates, addr)
            end
        end
    end

    if #candidates == 0 then
        -- 排除后无候选 → 回退到不排除（兜底）
        candidates = {}
        for _, addr in ipairs(pool) do table.insert(candidates, addr) end
    end

    -- 随机选取
    local addr = candidates[math.random(1, #candidates)]
    return {
        x = addr.coords.x,
        y = addr.coords.y,
        z = addr.coords.z,
        label = addr.label,
    }
end

print('[quest-address-resolver] 📍 地址池解析器已就绪')