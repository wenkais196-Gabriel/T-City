-- client/core/surface.lua — "哪一面在前台"的唯一状态。
--
-- 不变量：current 只可能是 nil / 'phone' / 'tablet'。
-- 互斥由类型保证，而不是靠两个布尔互相约束：不存在"手机和平板同时开着"这个可达状态。
-- 判定本身在 surface_rules.lua（纯函数），这里只负责持有输入与结果。

Surface = Surface or {}

local current = nil
local viewport = { width = 0, height = 0 }
local preference = 'auto'

function Surface.Current() return current end
function Surface.IsOpen() return current ~= nil end

--- NUI 上报的真实 CSS px（CEF 没上报时用屏幕分辨率兜底）
function Surface.SetViewport(width, height)
    local w, h = tonumber(width), tonumber(height)
    if w and h and w > 0 and h > 0 then
        viewport = { width = w, height = h }
        return true
    end
    return false
end

function Surface.Viewport() return { width = viewport.width, height = viewport.height } end

function Surface.SetPreference(value)
    if value == 'phone' or value == 'tablet' or value == 'auto' then
        preference = value
        return true
    end
    return false
end

function Surface.Preference() return preference end

local function limits()
    local cfg = (Config and Config.Surface) or {}
    return {
        min_width = tonumber(cfg.TabletMinWidth) or 900,
        min_height = tonumber(cfg.TabletMinHeight) or 560,
    }
end

--- 决定这次打开用哪一面。判定顺序见 surface_rules.lua。
---@return string kind, string why
function Surface.Decide(opts)
    opts = opts or {}
    local ped = PlayerPedId()
    local vp = viewport.width > 0 and viewport or nil
    if not vp then
        -- CEF 还没上报：用主屏分辨率当前菜（阈值是 CSS px，可能差一个缩放系数，
        -- 所以这只是兜底，正常路径永远是 NUI 上报）。
        local x, y = GetActiveScreenResolution()
        if tonumber(x) and tonumber(y) then vp = { width = x, height = y } end
    end
    return SurfaceRules.Resolve({
        entry_surface = opts.entry_surface,
        preference = preference,
        viewport = vp,
        in_vehicle = DoesEntityExist(ped) and IsPedInAnyVehicle(ped, false) or false,
        reason = opts.reason,
        limits = limits(),
    })
end

--- 打开后绑定当前形态（只有 main.lua 的 OpenPhone 会调）。
function Surface.Bind(kind)
    if kind ~= 'phone' and kind ~= 'tablet' then return nil end
    current = kind
    return kind
end

--- 关闭/复位。每个关闭路径必须走这里。
function Surface.Reset()
    current = nil
end
