-- client/minimap_style.lua — 两个「原版风格」方案，用一个 convar 切换
--
-- 背景：qb-hud 的 square 分支把 mask/blur 放大到 0.2293×0.2625（原生 0.111×0.159），
-- 还替换了雷达遮罩贴图 + 踢 bigmap，于是内容溢出边框、还偶发"倾斜巨图"。
-- 这里给两条干净的路子，都不替换贴图、都不碰 bigmap：
--
--   setr hud_minimap_style "native"  -- A：什么都不做，交给游戏；只在载具上显示雷达
--   setr hud_minimap_style "square"  -- B：方形雷达，但**遮罩与地图严丝合缝**，位置尺寸取原生
--
-- 默认 A。切换后 restart hud-position-tool 生效。

local STYLE = GetConvar('hud_minimap_style', 'native')

local function log(msg)
    if GetConvar('hud_position_tool_debug', '0') == '1' then
        print(('[minimap] %s'):format(msg))
    end
end

--- B 方案的几何：整块雷达沿用原生位置与尺寸，遮罩/模糊与地图同尺寸（关键就在"同尺寸"）
local function applySquare()
    local resolutionX, resolutionY = GetActiveScreenResolution()
    local aspect = resolutionX / resolutionY
    local defaultAspect = 1920 / 1080
    local offset = 0.0
    if aspect > defaultAspect then
        offset = ((defaultAspect - aspect) / 3.6) - 0.008
    end

    SetMinimapClipType(0)   -- 0 = 方形遮罩（不换贴图，用游戏自带的方形遮罩）
    -- 地图本体：原生 X/Y 与尺寸（0.150 × 0.188888）
    SetMinimapComponentPosition('minimap', 'L', 'B', -0.0045 + offset, 0.002, 0.150, 0.188888)
    -- 遮罩与模糊：**与地图同位置同尺寸**，这样不会再出现"内容画到框外"
    SetMinimapComponentPosition('minimap_mask', 'L', 'B', -0.0045 + offset, 0.002, 0.150, 0.188888)
    SetMinimapComponentPosition('minimap_blur', 'L', 'B', -0.0045 + offset, 0.002, 0.150, 0.188888)
    SetBlipAlpha(GetNorthRadarBlip(), 0)
    log('square applied')
end

--- 雷达可见性：步行不显示、载具上与游戏一致（A/B 共用）
local function watchRadar()
    CreateThread(function()
        local last = nil
        while true do
            local ped = PlayerPedId()
            local shouldShow = IsPedInAnyVehicle(ped, false) and true or false
            if shouldShow ~= last then
                last = shouldShow
                DisplayRadar(shouldShow)
            end
            Wait(1000)
        end
    end)
end

CreateThread(function()
    -- 等客户端资源都起来，避免和 qb-hud 抢同一个 tick
    Wait(1500)
    if STYLE == 'square' then
        applySquare()
    else
        log('native (no override)')
    end
    watchRadar()
end)
