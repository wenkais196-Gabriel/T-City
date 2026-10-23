-- ============================================================================
-- map_sidebar.lua — 大地图侧边栏客户端
-- ============================================================================
-- 职责:
--   1. 从 Config.BlipCategories 收集 blip 数据
--   2. 通过 _L() / Lang:t() 将 localeKey 解析为当前语言文本
--   3. SendNUIMessage 发送给 NUI 前端
--   4. 处理 NUI 回调: 设置 GPS 导航点 / 关闭侧边栏
-- ============================================================================

local isSidebarOpen = false

-- ── 翻译辅助: 优先 _L(), 降级 QBCore Lang:t(), 最终返回 key 本身 ──
local function T(key)
    if not key or key == '' then return '' end

    -- 路径 1: production-freeze 的 _L() 引擎（按玩家 GTA5 语言分流）
    if _L and type(_L) == 'function' then
        local tr = _L(nil, key)
        if tr and type(tr) == 'string' and tr ~= ('[' .. key .. ']') then
            return tr
        end
    end

    -- 路径 2: QBCore 原生 Lang:t() 链
    local ok, tr = pcall(function() return Lang:t(key) end)
    if ok and tr and type(tr) == 'string' and tr ~= key then
        return tr
    end

    -- 路径 3: 兜底返回 key 本身
    return key
end

-- ── 构建发送给前端的 JSON ──
local function BuildBlipPayload()
    local categories = {}
    local catList = Config.BlipCategories

    if not catList then return categories end

    for catKey, catData in pairs(catList) do
        if type(catData) == 'table' and catData.items then
            local items = {}
            for _, item in ipairs(catData.items) do
                if item.showBlip and item.coords then
                    items[#items + 1] = {
                        name   = T(item.localeKey),
                        coords = {
                            x = item.coords.x,
                            y = item.coords.y,
                            z = item.coords.z,
                        },
                        sprite = item.blipSprite or catData.blipSprite or 357,
                        color  = item.blipColor  or catData.blipColor  or 3,
                        scale  = item.blipScale  or catData.blipScale  or 0.6,
                    }
                end
            end

            if #items > 0 then
                categories[#categories + 1] = {
                    id     = catKey,
                    label  = T(catData.localeKey),
                    icon   = catData.icon or 'fa-solid fa-location-dot',
                    sprite = catData.blipSprite or 357,
                    color  = catData.blipColor  or 3,
                    items  = items,
                }
            end
        end
    end

    -- 按 label 字母序排列 (中英文均适用)
    table.sort(categories, function(a, b) return a.label < b.label end)
    return categories
end

-- ── 命令: 切换侧边栏 ──
local function ToggleSidebar()
    isSidebarOpen = not isSidebarOpen
    if isSidebarOpen then
        SetNuiFocus(true, true)
        SendNUIMessage({
            action     = 'mapSidebar:open',
            title      = T('blip_title'),
            categories = BuildBlipPayload(),
        })
    else
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'mapSidebar:close' })
    end
end

RegisterCommand('mapsidebar', ToggleSidebar, false)
RegisterKeyMapping('mapsidebar', 'Toggle Map Sidebar', 'keyboard', 'F9')

-- ── NUI 回调: 设置 GPS 导航点 ──
RegisterNUICallback('mapSidebar:setWaypoint', function(data, cb)
    if data and data.coords then
        SetNewWaypoint(data.coords.x, data.coords.y)
    end
    cb('ok')
end)

-- ── NUI 回调: 关闭侧边栏 ──
RegisterNUICallback('mapSidebar:close', function(_, cb)
    isSidebarOpen = false
    SetNuiFocus(false, false)
    cb('ok')
end)

-- ── 资源停止时清理 ──
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if isSidebarOpen then
            SetNuiFocus(false, false)
        end
    end
end)
