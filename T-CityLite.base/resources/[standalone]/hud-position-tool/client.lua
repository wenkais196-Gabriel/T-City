-- ═══════════════════════════════════════════════════════════
-- hud-position-tool v2 — 实时 HUD 定位调试器
-- 命令:
--   /mapsize <50-150>    — 缩放地图
--   /mapsize square|circle — 切换形状
--   /ringpos center|<x> <y>|reset — 状态环位置
--   /gauges <x> <y>|reset — 仪表盘整体偏移
--   /wpdist <x> <y>|reset  — 目的地距离位置
--   /mapcomp list|<name> <posX> <posY> <sizeX> <sizeY>|reset — 逐组件调参
--   /mapdump             — 打印当前全部 minimap 组件值
--   /ringdiag            — 诊断 ringpos 事件链路
--   /huddebug            — 切换调试叠加层
-- ═══════════════════════════════════════════════════════════

-- ━━━ 基础 minimap 参数 (从 qb-hud client.lua 提取) ━━━
local basePositions = {
    square = {
        minimap      = { posX = 0.0,    posY = -0.047, sizeX = 0.164,  sizeY = 0.183 },
        minimap_mask = { posX = -0.01,  posY = 0.025,  sizeX = 0.262,  sizeY = 0.300 },
        minimap_blur = { posX = -0.01,  posY = 0.025,  sizeX = 0.262,  sizeY = 0.300 },
    },
    circle = {
        minimap      = { posX = -0.01, posY = -0.030, sizeX = 0.180,  sizeY = 0.258 },
        minimap_mask = { posX = 0.200, posY = 0.0,    sizeX = 0.065,  sizeY = 0.20  },
        minimap_blur = { posX = 0.0,   posY = 0.015,  sizeX = 0.252,  sizeY = 0.338 },
    },
}

-- ━━━ 状态 ━━━
local mapScale = 87.5
local mapShape = 'circle'
local ringX = '50%'
local ringY = '0.2vw'
local ringMode = '居中'
local gaugeX = nil    -- nil = 使用 CSS 默认
local gaugeY = nil
local wpDistX = nil
local wpDistY = nil
local overlayVisible = false
local minimapOffset = 0

-- 当前生效的 minimap 参数 (会随 /mapcomp 修改)
local currentPositions = {}

-- ━━━ 分辨率补偿 ━━━
local function recalcOffset()
    local defaultAspectRatio = 1920 / 1080
    local resolutionX, resolutionY = GetActiveScreenResolution()
    local aspectRatio = resolutionX / resolutionY
    if aspectRatio > defaultAspectRatio then
        minimapOffset = ((defaultAspectRatio - aspectRatio) / 3.6) - 0.008
    else
        minimapOffset = 0
    end
end

-- ━━━ 初始化 currentPositions (深拷贝 base) ━━━
local function resetCurrentPositions()
    local base = basePositions[mapShape]
    currentPositions = {}
    for k, v in pairs(base) do
        currentPositions[k] = {
            posX = v.posX,
            posY = v.posY,
            sizeX = v.sizeX,
            sizeY = v.sizeY,
        }
    end
end

-- ━━━ 应用地图 (统一入口) ━━━
local function applyMap()
    recalcOffset()
    if not currentPositions or not next(currentPositions) then
        resetCurrentPositions()
    end
    local s = mapScale / 100.0

    for compName, params in pairs(currentPositions) do
        SetMinimapComponentPosition(
            compName, 'L', 'B',
            params.posX + minimapOffset,
            params.posY,
            params.sizeX * s,
            params.sizeY * s
        )
    end
end

-- ━━━ NUI 通知辅助 ━━━
local function sendToQbHud(eventName, data)
    TriggerEvent(eventName, data)
end

local function refreshOverlay()
    SendNUIMessage({
        action = 'update',
        scale = mapScale,
        shape = mapShape,
        ringX = ringX,
        ringY = ringY,
        ringMode = ringMode,
        gaugeX = gaugeX or 'CSS',
        gaugeY = gaugeY or 'CSS',
        wpDistX = wpDistX or 'CSS',
        wpDistY = wpDistY or 'CSS',
    })
end

-- ═══════════════════════════════════════════════════════════
-- /mapsize
-- ═══════════════════════════════════════════════════════════
RegisterCommand('mapsize', function(_, args)
    if not args[1] then
        print('^3[mapsize]^7 缩放:' .. mapScale .. '%  形状:' .. mapShape)
        print('^3[mapsize]^7 用法: /mapsize <50-150> | square|circle')
        return
    end

    local arg = args[1]:lower()

    if arg == 'square' or arg == 'circle' then
        mapShape = arg
        resetCurrentPositions()
        print('^2[mapsize]^7 形状 → ' .. mapShape)
        applyMap()
        refreshOverlay()
        return
    end

    local val = tonumber(arg)
    if val and val >= 50 and val <= 150 then
        mapScale = val
        print('^2[mapsize]^7 缩放 → ' .. mapScale .. '%')
        applyMap()
        refreshOverlay()
    else
        print('^1[mapsize]^7 无效: ' .. tostring(arg))
    end
end, false)

-- ═══════════════════════════════════════════════════════════
-- /ringpos
-- ═══════════════════════════════════════════════════════════
RegisterCommand('ringpos', function(_, args)
    if not args[1] then
        print('^3[ringpos]^7 ' .. ringX .. ' / ' .. ringY .. ' (' .. ringMode .. ')')
        print('^3[ringpos]^7 用法: center | <x> <y> | reset')
        return
    end

    local arg = args[1]:lower()

    if arg == 'center' then
        ringX, ringY, ringMode = '50%', '0.2vw', '居中'
    elseif arg == 'reset' then
        ringX, ringY, ringMode = '3vh', '0.2vw', '默认'
    elseif args[2] then
        ringX, ringY, ringMode = args[1], args[2], '自定义'
    else
        print('^1[ringpos]^7 需 2 个参数 (x y) 或 center/reset')
        return
    end

    print('^2[ringpos]^7 → ' .. ringX .. ' / ' .. ringY .. ' (' .. ringMode .. ')')
    sendToQbHud('hud-position-tool:ringPosition', { x = ringX, y = ringY, mode = ringMode })
    refreshOverlay()
end, false)

-- ═══════════════════════════════════════════════════════════
-- /gauges — 仪表盘整体偏移 (speedo + fuel + altitude + seatbelt)
-- ═══════════════════════════════════════════════════════════
RegisterCommand('gauges', function(_, args)
    if not args[1] then
        print('^3[gauges]^7 X:' .. (gaugeX or 'CSS') .. ' Y:' .. (gaugeY or 'CSS'))
        print('^3[gauges]^7 用法: /gauges <x> <y> | reset')
        return
    end

    if args[1]:lower() == 'reset' then
        gaugeX, gaugeY = nil, nil
        print('^2[gauges]^7 → 恢复 CSS 默认')
        sendToQbHud('hud-position-tool:gaugePosition', { reset = true })
    elseif args[2] then
        gaugeX, gaugeY = args[1], args[2]
        print('^2[gauges]^7 → ' .. gaugeX .. ' / ' .. gaugeY)
        sendToQbHud('hud-position-tool:gaugePosition', { x = gaugeX, y = gaugeY })
    else
        print('^1[gauges]^7 需 <x> <y> 两个参数')
        return
    end
    refreshOverlay()
end, false)

-- ═══════════════════════════════════════════════════════════
-- /wpdist — 目的地距离位置
-- ═══════════════════════════════════════════════════════════
RegisterCommand('wpdist', function(_, args)
    if not args[1] then
        print('^3[wpdist]^7 X:' .. (wpDistX or 'CSS') .. ' Y:' .. (wpDistY or 'CSS'))
        print('^3[wpdist]^7 用法: /wpdist <x> <y> | reset')
        return
    end

    if args[1]:lower() == 'reset' then
        wpDistX, wpDistY = nil, nil
        print('^2[wpdist]^7 → 恢复 CSS 默认')
        sendToQbHud('hud-position-tool:wpDistPosition', { reset = true })
    elseif args[2] then
        wpDistX, wpDistY = args[1], args[2]
        print('^2[wpdist]^7 → ' .. wpDistX .. ' / ' .. wpDistY)
        sendToQbHud('hud-position-tool:wpDistPosition', { x = wpDistX, y = wpDistY })
    else
        print('^1[wpdist]^7 需 <x> <y> 两个参数')
        return
    end
    refreshOverlay()
end, false)

-- ═══════════════════════════════════════════════════════════
-- /mapcomp — 逐个组件调参 (核心: 解决 blip 边界错位)
-- ═══════════════════════════════════════════════════════════
RegisterCommand('mapcomp', function(_, args)
    if not args[1] then
        print('^3[mapcomp]^7 用法:')
        print('  /mapcomp list              — 列出当前组件参数')
        print('  /mapcomp <name> <pX> <pY> <sX> <sY> — 直接设置')
        print('  /mapcomp <name> reset      — 恢复该组件到默认')
        print('  组件名: minimap | minimap_mask | minimap_blur')
        return
    end

    local name = args[1]:lower()

    if name == 'list' then
        print('^6══════ 当前 minimap 组件 (缩放 ' .. mapScale .. '%) ══════^7')
        local s = mapScale / 100.0
        for compName, p in pairs(currentPositions) do
            print(string.format('  %-14s  pos(%+0.4f, %+0.4f)  size(%0.4f→%0.4f, %0.4f→%0.4f)',
                compName,
                p.posX + minimapOffset, p.posY,
                p.sizeX, p.sizeX * s,
                p.sizeY, p.sizeY * s))
        end
        print('^6══════════════════════════════════════════^7')
        return
    end

    if not currentPositions[name] then
        print('^1[mapcomp]^7 未知组件: ' .. name .. ' (可用: minimap, minimap_mask, minimap_blur)')
        return
    end

    if args[2] and args[2]:lower() == 'reset' then
        local base = basePositions[mapShape][name]
        currentPositions[name] = {
            posX = base.posX, posY = base.posY,
            sizeX = base.sizeX, sizeY = base.sizeY,
        }
        print('^2[mapcomp]^7 ' .. name .. ' → 恢复默认')
        applyMap()
        refreshOverlay()
        return
    end

    if not (args[2] and args[3] and args[4] and args[5]) then
        print('^1[mapcomp]^7 需要 5 个参数: <name> <posX> <posY> <sizeX> <sizeY>')
        return
    end

    local posX = tonumber(args[2])
    local posY = tonumber(args[3])
    local sizeX = tonumber(args[4])
    local sizeY = tonumber(args[5])

    if not (posX and posY and sizeX and sizeY) then
        print('^1[mapcomp]^7 参数必须是数字')
        return
    end

    currentPositions[name] = { posX = posX, posY = posY, sizeX = sizeX, sizeY = sizeY }
    print('^2[mapcomp]^7 ' .. name .. string.format(' pos(%+0.4f,%+0.4f) size(%0.4f,%0.4f)',
        posX, posY, sizeX, sizeY))
    applyMap()
    refreshOverlay()
end, false)

-- ═══════════════════════════════════════════════════════════
-- /mapdump — 精简打印 (别名)
-- ═══════════════════════════════════════════════════════════
RegisterCommand('mapdump', function()
    print('^6══ mapdump (' .. mapShape .. ' @ ' .. mapScale .. '%) ══^7')
    local s = mapScale / 100.0
    for compName, p in pairs(currentPositions) do
        local effSizeX = p.sizeX * s
        local effSizeY = p.sizeY * s
        local centerX = (p.posX + minimapOffset) + effSizeX / 2
        local centerY = p.posY + effSizeY / 2
        print(string.format('  %-14s  eff-size(%0.4f,%0.4f)  center(%+0.4f,%+0.4f)',
            compName, effSizeX, effSizeY, centerX, centerY))
    end
end, false)

-- ═══════════════════════════════════════════════════════════
-- /ringdiag
-- ═══════════════════════════════════════════════════════════
RegisterCommand('ringdiag', function()
    print('^6══ ringpos 诊断 ══^7')
    print('  参数: x=' .. ringX .. ' y=' .. ringY .. ' mode=' .. ringMode)
    local ok, err = pcall(function()
        TriggerEvent('hud-position-tool:ringPosition', { x = ringX, y = ringY, mode = ringMode })
    end)
    if ok then
        print('^2  TriggerEvent OK^7')
    else
        print('^1  TriggerEvent FAIL: ' .. tostring(err) .. '^7')
    end
    print('  → 按 F8 看浏览器 console 的 [ringpos] 日志')
end, false)

-- ═══════════════════════════════════════════════════════════
-- /huddebug
-- ═══════════════════════════════════════════════════════════
RegisterCommand('huddebug', function()
    overlayVisible = not overlayVisible
    if overlayVisible then
        SendNUIMessage({ action = 'show' })
        refreshOverlay()
        print('^2[huddebug]^7 叠加层 开启')
    else
        SendNUIMessage({ action = 'hide' })
        print('^3[huddebug]^7 叠加层 关闭')
    end
end, false)

-- ═══════════════════════════════════════════════════════════
-- 启动
-- ═══════════════════════════════════════════════════════════
CreateThread(function()
    Wait(3000)
    local ok, shape = pcall(function()
        return exports['qb-hud']:GetCurrentMapShape()
    end)
    if ok and shape then mapShape = shape end
    resetCurrentPositions()
    recalcOffset()
    applyMap()
    -- 初始应用居中 + 发送环位置
    sendToQbHud('hud-position-tool:ringPosition', { x = ringX, y = ringY, mode = ringMode })
    print('^2[hud-position-tool v2]^7 就绪 — /mapsize /ringpos /gauges /wpdist /mapcomp /mapdump /ringdiag /huddebug')
end)
