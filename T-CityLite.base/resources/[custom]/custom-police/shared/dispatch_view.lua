-- shared/dispatch_view.lua — 警情对外投影（D5：精确坐标永不下发客户端）。
--
-- 任何把警情发给客户端的地方（屏幕提示、地图标记、车机终端、手机）都必须走这里，
-- 否则就会重犯 2026-10-31 那个洞：broadcastIncidentAlert 把 x/y/z 原样广播，
-- 开图的人拿到比调度还准的位置。
--
-- 偏移是**按单号确定性**的：同一张单每次看到的位置一样（不会"地图上跳来跳去"），
-- 不同单号之间用黄金角散开（相邻单不会挤在同一个方向）。

PoliceDispatchView = PoliceDispatchView or {}

local FUZZ_RADIUS = 80.0          -- 与 p0_incidents 的半径一致
local GOLDEN_ANGLE = 137.508

--- 把真实坐标偏移到半径 60–95% 的一个点。
--- @param id number|string 单号
--- @param x number
--- @param y number
--- @param z number
--- @return table { x, y, z, spread }
function PoliceDispatchView.Fuzz(id, x, y, z)
    local seed = tonumber(id) or 1
    local angle = (seed * GOLDEN_ANGLE) % 360.0
    local spread = FUZZ_RADIUS * (0.6 + ((seed % 7) / 7) * 0.35)
    local rad = math.rad(angle)
    return {
        x = (tonumber(x) or 0.0) + math.cos(rad) * spread,
        y = (tonumber(y) or 0.0) + math.sin(rad) * spread,
        z = tonumber(z) or 0.0,
        spread = spread,
    }
end

--- 一张单对外的样子（客户端/车机/手机都只该看到这个）。
function PoliceDispatchView.Public(row)
    if type(row) ~= 'table' then return nil end
    local point = PoliceDispatchView.Fuzz(row.id, row.x, row.y, row.z)
    return {
        id = tonumber(row.id),
        code = tostring(row.code or '911'),
        title = tostring(row.title or ''),
        priority = tonumber(row.priority) or 2,
        status = tostring(row.status or 'open'),
        x = point.x,
        y = point.y,
        z = point.z,
        openedAt = tonumber(row.created_at) or 0,
    }
end

PoliceDispatchView.FUZZ_RADIUS = FUZZ_RADIUS
