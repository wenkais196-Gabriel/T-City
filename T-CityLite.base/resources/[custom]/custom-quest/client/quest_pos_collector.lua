-- client/quest_pos_collector.lua — 航空坐标采集工具 v0.11
--
-- 用法 (F8 控制台):
--   /savepos <name> airport    — 保存为跑道机场坐标
--   /savepos <name> helipad    — 保存为停机坪坐标
--   /savepos <name> waypoint   — 保存为航路点坐标
--   /savepos <name> any        — 保存为通用坐标 (默认)
--   /savepos list              — 列出本次采集的所有坐标
--   /savepos clear             — 清空本次采集缓存
--   /savepos export            — 导出为 address_pools.lua 格式到文件
--
-- 坐标同时输出到:
--   1. F8 控制台 (方便直接复制)
--   2. 服务端文件 pos_collection.json (通过 TriggerServerEvent 持久化)

local QBCore = exports['qb-core']:GetCoreObject()
local collection = {}  -- 本次会话采集的坐标
local nextId = 1

-- GTA V 常用高度基准:
--   地面: ped 脚底 z (GetEntityCoords 返回的高度)
--   跑道: 通常 30-42m (LSIA ~13m, Sandy ~41m, Grapeseed ~41m)
--   航路点: 飞行高度 (玩家需在目标高度悬停后采集)

-- ═══════════════════════════════════════════════════════════
-- /savepos 命令
-- ═══════════════════════════════════════════════════════════

RegisterCommand('savepos', function(source, args)
    local name = args[1]
    local ptype = args[2] or 'any'

    if not name then
        print('^1用法: /savepos <name> [airport|helipad|waypoint|any]^7')
        print('  airport  — 跑道机场 (z取地面)')
        print('  helipad  — 直升机停机坪')
        print('  waypoint — 空中航路点')
        print('  any      — 通用坐标 (默认)')
        print('  list     — 列出本次采集')
        print('  clear    — 清空缓存')
        print('  export   — 导出到文件')
        return
    end

    if name == 'list' then
        if #collection == 0 then
            print('^3📋 本次采集为空^7')
            return
        end
        print('^2════════ 本次采集 (%d 个坐标) ════════^7', #collection)
        for _, entry in ipairs(collection) do
            print(entry.formatted)
        end
        print('^2══════════════════════════════════^7')
        return
    end

    if name == 'clear' then
        collection = {}
        nextId = 1
        print('^2✅ 采集缓存已清空^7')
        return
    end

    if name == 'export' then
        if #collection == 0 then
            print('^3📋 没有坐标可导出^7')
            return
        end
        -- 发送到服务端写入文件
        TriggerServerEvent('quest:server:savePosCollection', collection)
        print('^2✅ 已发送 %d 个坐标到服务端保存 (pos_collection.json)^7', #collection)
        -- 同时输出到控制台
        print('^2════════ 可复制到 address_pools.lua ════════^7')
        for _, entry in ipairs(collection) do
            print(entry.luaCode)
        end
        print('^2══════════════════════════════════════^7')
        return
    end

    -- 采集坐标
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- 根据类型调整 z 取值
    local z = coords.z
    local note = ''
    if ptype == 'airport' then
        -- 跑道: 取地面高度 (玩家可能在飞机里)
        local groundZ
        local found, groundZResult = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z, true)
        if found then
            groundZ = groundZResult
            z = groundZ  -- 跑道坐标用地面高度
            note = ('(地面z=%.1f, 玩家z=%.1f)'):format(groundZ, coords.z)
        end
    elseif ptype == 'helipad' then
        -- 停机坪: 如果是楼顶，保留楼顶高度
        local groundZ
        local found, groundZResult = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z, true)
        if found then
            note = ('(地面z=%.1f, 停机坪z=%.1f)'):format(groundZResult, coords.z)
        end
    elseif ptype == 'waypoint' then
        -- 航路点: 保留当前飞行高度
        note = ('(飞行高度 z=%.1f)'):format(coords.z)
    end

    -- 格式化为 Lua 代码
    local luaCode = string.format(
        '    { coords = { x = %.2f, y = %.2f, z = %.2f }, label = \'%s\', type = \'%s\' },',
        coords.x, coords.y, z, name, ptype
    )

    -- 格式化为可读输出
    local formatted = string.format(
        '^2[#%d]^7 %-20s ^3type=%-10s^7 (%.2f, %.2f, %.2f) heading=%.0f° %s',
        nextId, name, ptype, coords.x, coords.y, z, heading, note
    )

    local entry = {
        id = nextId,
        name = name,
        type = ptype,
        x = coords.x,
        y = coords.y,
        z = z,
        heading = heading,
        rawZ = coords.z,
        formatted = formatted,
        luaCode = luaCode,
    }

    table.insert(collection, entry)
    nextId = nextId + 1

    print(formatted)
    print('  ^5' .. luaCode .. '^7')

    -- 也通过 notify 显示
    QBCore.Functions.Notify(('📍 已采集: %s (%s)'):format(name, ptype), 'success')
end, false)

-- ═══════════════════════════════════════════════════════════
-- 快捷命令: /getpos — 快速获取当前坐标 (不分类)
-- ═══════════════════════════════════════════════════════════

RegisterCommand('getpos', function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local veh = GetVehiclePedIsIn(ped, false)
    local groundZ = 0
    local found = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z, true)
    if found then groundZ = found end

    print('^2══════════════════════════════════^7')
    print(string.format('^3坐标:^7 vec4(%.4f, %.4f, %.4f, %.1f)', coords.x, coords.y, coords.z, heading))
    print(string.format('^3Lua:^7  { x = %.2f, y = %.2f, z = %.2f }', coords.x, coords.y, coords.z))
    print(string.format('^3地面:^7 z = %.2f (玩家 z = %.2f)', groundZ, coords.z))
    if veh and veh ~= 0 then
        local model = GetEntityModel(veh)
        local class = GetVehicleClass(veh)
        print(string.format('^3载具:^7 model=%d class=%d', model, class))
    end
    print('^2══════════════════════════════════^7')
end, false)

print('[quest-pos-collector] ✅ 坐标采集工具已加载')
print('[quest-pos-collector]   /savepos <name> [airport|helipad|waypoint]')
print('[quest-pos-collector]   /getpos — 快速获取当前坐标')
print('[quest-pos-collector]   /savepos list|clear|export')
