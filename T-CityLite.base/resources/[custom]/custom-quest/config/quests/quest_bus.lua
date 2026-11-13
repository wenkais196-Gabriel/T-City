-- config/quests/quest_bus.lua — 公交线路（bus）多站路线 v1（R1 · P3）
--
-- 形状与 garbage 同构（报到 → N 个站点 → 交回），差两点：
--   1. 站点是公交换乘点，站距更大；
--   2. 金额按 02-design §2.3 的 bus 档：站×90×tier，三档固定为 $486 / $648 / $810。
--
-- 准点率（punctuality ∈ [0.8, 1.1]）**v1 不做**：它需要逐站到达时窗的记录与结算侧读取，
-- 而 quest 现有的时效倍率只覆盖物流那一条链（CalculateTimeBonus 读的是物流追踪器）。
-- 记在 03-plan.md §7 的已知缺口里，等 P4 数值卡收口时一起定。
--
-- ⚠️ 坐标是真机待复核项：用的是洛圣都主干道公交站的大致位置。

local DEPOT = { x = -268.4, y = -957.5, z = 31.2 }   -- 市中心公交总站

-- 站点池（10 个）。低阶取前 N 个，保证路线是逐级延伸的。
local STOPS = {
    { x = -262.0, y = -1000.0, z = 29.3 },   -- 市中心南
    { x = -600.0, y = -950.0,  z = 22.0 },   -- 小首尔
    { x = -1150.0, y = -900.0, z = 13.9 },   -- Vespucci 北
    { x = -1750.0, y = -600.0, z = 38.0 },   -- Del Perro
    { x = -1900.0, y = 200.0,  z = 88.0 },   -- Richman
    { x = -700.0, y = 300.0,   z = 86.0 },   -- Rockford 西
    { x = 130.0, y = -1050.0,  z = 29.3 },   -- Pillbox
    { x = 425.0, y = -1400.0,  z = 29.3 },   -- Davis
    { x = 810.0, y = -1500.0,  z = 27.0 },   -- La Mesa
    { x = 1180.0, y = -310.0,  z = 69.0 },   -- Mirror Park
}

--- 组装一条线路：报到 → N 站（validator）→ 交回
---@param stops number
---@return table steps
local function buildSteps(stops)
    local steps = {
        {
            id = 'step_clock_in',
            title = '签到',
            description = '到公交总站签到并领取线路单',
            type = 'interact',
            data = {
                coords = DEPOT, radius = 8.0, duration = 3000,
                label = '领取线路单...', in_vehicle = false,
            },
        },
    }

    for index = 1, stops do
        local point = STOPS[index]
        steps[#steps + 1] = {
            id = ('step_stop_%02d'):format(index),
            title = ('站点 %d/%d'):format(index, stops),
            description = '按线路依次停靠',
            type = 'validator',
            data = {
                -- 顶层 coords 给客户端画交互点；validator_data 里那份给服务端校验器
                coords = point,
                radius = 14.0,
                validator_id = 'validate_route_stop',
                validator_data = {
                    index = index,
                    index_total = stops,
                    job = 'bus',
                    require_duty = true,
                    coords = point,
                    radius = 14.0,
                },
            },
        }
    end

    steps[#steps + 1] = {
        id = 'step_clock_out',
        title = '交班',
        description = '把车开回总站并交回线路单',
        type = 'interact',
        data = {
            coords = DEPOT, radius = 8.0, duration = 3000,
            label = '交回线路单...', in_vehicle = false,
        },
    }

    return steps
end

return {
    {
        id = 'bus_v1_city',
        title = '城区环线（6 站）',
        description = '市中心到小首尔一圈，新手司机的第一条线。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian', job = 'bus' },
        conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 8, require_job = 'bus' },
        rewards = {
            money = { type = 'bank', min = 486, max = 486 },   -- 6×90×0.9
            rep = { bus = 25 },
        },
        steps = buildSteps(6),
    },
    {
        id = 'bus_v1_crosstown',
        title = '横贯线（8 站）',
        description = '过海到 Del Perro 再折返，站距明显拉长。',
        category = 'civilian',
        level = 2,
        required_tags = { role = 'civilian', job = 'bus' },
        conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 8, require_job = 'bus' },
        rewards = {
            money = { type = 'bank', min = 648, max = 648 },   -- 8×90×0.9
            rep = { bus = 25 },
        },
        steps = buildSteps(8),
    },
    {
        id = 'bus_v1_full',
        title = '全城线（10 站）',
        description = '一条线跑遍全城十个换乘点，工时长但一趟顶两趟。',
        category = 'civilian',
        level = 3,
        required_tags = { role = 'civilian', job = 'bus' },
        conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 8, require_job = 'bus' },
        rewards = {
            money = { type = 'bank', min = 810, max = 810 },   -- 10×90×0.9
            rep = { bus = 25 },
        },
        steps = buildSteps(10),
    },
}
