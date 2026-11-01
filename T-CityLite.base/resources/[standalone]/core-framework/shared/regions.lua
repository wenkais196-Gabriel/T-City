-- shared/regions.lua — 世界痕迹的区域注册表（纯数据 + 纯函数）
--
-- 为什么在这里：`world_state.region_id` 是**写进数据库的主键**（`world_state` 的
-- unique key 是 `(region_id, state_key)`）。所以区域的 id 与边界属于"世界"这一层，
-- 不属于某个业务资源 —— 警察结案、cartel 地盘、将来的物价波动必须用同一套 id，
-- 否则同一个地方会存成 `west_ls` / `police_west` 两行，永远对不上。
--
-- 纪律：
--   * 本文件**必须是纯的**：不调 FiveM 原生、不碰 DB、不读 convar、不 CreateThread。
--     它要能在离线 lua5.4 harness 里被 dofile 执行（见 tests/unit/layer1_core/test_world_regions.py）。
--   * `id` 一旦写进 DB 就不能"顺手统一"：改名要走迁移；改 `label` 随便。
--   * 坐标全部取自仓库里**已经存在的地点配置**（见每行的 source 注释），不是凭记忆编的。
--
-- 判定语义：坐标落在某个圆的半径内 → 该 region（重叠时取最近的圆心）；
-- 都不在 → `city_wide`。坐标非法（nil / 非数字 / NaN / Inf）→ 同样 `city_wide`，且不抛错。

Regions = Regions or {}
local R = Regions

R.FALLBACK = 'city_wide'
R.FALLBACK_LABEL = '全城'

--- 区域列表。radius 单位是米（与 GTA 坐标同单位）。
--- 城市区域取半径 300–500（覆盖相邻街区但尽量不与邻区重叠）；
--- 远郊取 800（地标稀疏，允许大片覆盖）。
R.LIST = {
    -- 两处南区小店的平均点：qb-storerobbery/config.lua:49-50
    { id = 'south_ls',   label = '南区',     x = -47.91,   y = -1758.43, radius = 300.0 },
    -- 中央区两处：qb-storerobbery/config.lua:55-56
    { id = 'central_ls', label = '市中心',   x = 24.46,    y = -1346.18, radius = 300.0 },
    -- 西区：qb-storerobbery/config.lua:52
    { id = 'west_ls',    label = '西区',     x = -1222.03, y = -908.32,  radius = 350.0 },
    -- 镜园：qb-storerobbery/config.lua:53-54
    { id = 'mirror_park', label = '镜园',    x = -706.12,  y = -914.46,  radius = 300.0 },
    -- 东区三处（跨度 660 m，半径放到 500）：qb-storerobbery/config.lua:57-59
    { id = 'east_ls',    label = '东区',     x = 1154.63,  y = -543.20,  radius = 500.0 },
    -- 富人区：qb-storerobbery/config.lua:60-61
    { id = 'vinewood',   label = '富人区',   x = 372.86,   y = 327.52,   radius = 400.0 },
    -- 西北海岸：qb-storerobbery/config.lua:62-63
    { id = 'west_coast', label = '西北海岸', x = -1819.54, y = 793.59,   radius = 400.0 },
    -- 西北远岸五处（跨度 700 m）：qb-storerobbery/config.lua:64-68
    { id = 'northwest',  label = '北岸',     x = -3106.66, y = 711.88,   radius = 450.0 },
    -- 沙丘镇：qb-drugs/config.lua 的交付点 (1960, 3700)
    { id = 'sandy',      label = '沙丘镇',   x = 1960.0,   y = 3700.0,   radius = 800.0 },
    -- 佩利托湾：qb-drugs/config.lua 的交付点 (-160, 6420)
    { id = 'paleto',     label = '佩利托湾', x = -160.0,   y = 6420.0,   radius = 800.0 },
}

local byId = {}
for i = 1, #R.LIST do
    byId[R.LIST[i].id] = R.LIST[i]
end

--- 按 id 取区域定义。
---@param id any
---@return table|nil
function R.Get(id)
    if type(id) ~= 'string' then return nil end
    return byId[id]
end

--- 这个 id 能不能写进 world_state（含兜底 city_wide）。
---@param id any
---@return boolean
function R.IsValid(id)
    if type(id) ~= 'string' then return false end
    if id == R.FALLBACK then return true end
    return byId[id] ~= nil
end

--- 展示名。兜底与未知 id 都返回兜底标签（UI 不该看到 "nil"）。
---@param id any
---@return string
function R.Label(id)
    local region = R.Get(id)
    if region then return region.label end
    return R.FALLBACK_LABEL
end

--- 坐标 → region_id。纯函数：不抛错、不做 IO。
---@param x any
---@param y any
---@return string
function R.RegionOf(x, y)
    if type(x) ~= 'number' or type(y) ~= 'number' then return R.FALLBACK end
    -- NaN 与 Inf 都会让距离比较变成永假/永真，必须先挡掉。
    if x ~= x or y ~= y then return R.FALLBACK end
    if x == math.huge or x == -math.huge then return R.FALLBACK end
    if y == math.huge or y == -math.huge then return R.FALLBACK end

    local bestId, bestDist = nil, math.huge
    for i = 1, #R.LIST do
        local region = R.LIST[i]
        local dx, dy = x - region.x, y - region.y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= region.radius and dist < bestDist then
            bestId, bestDist = region.id, dist
        end
    end
    return bestId or R.FALLBACK
end
