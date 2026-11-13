-- config/quests/quest_garbage.lua — 环卫（garbage）多站路线 v1（R1 · P2）
--
-- 形状：
--   报到（interact，depot）→ N 个收运点（validator: validate_route_stop）→ 交回（interact，depot）
-- 收运点用 `validator` 而不是 `interact`：走的是 R1·P1 的服务端校验器
-- （顺序 / 职业 / 在岗 / 距离 / 载具），客户端只上报"我到了"。
--
-- 数值（docs/plan/jobs-content/02-design.md §2.3）：
--   每站 $30 + 每袋 $25，乘以时效倍率与损伤倍率。
--   4 站 10 袋 = $370；6 站 21 袋 = $705；8 站 36 袋 = $1,140。
--   折算 1,388 / 1,763 / 2,138 每小时，落在低技能带（1.4k–2.8k）。
--
-- ⚠️ 坐标是真机待复核项：本文件用的是洛圣都常驻垃圾点的大致位置，
--    P2 验收要求「先在 dev 服跑一条真实任务」，跑之前不要对外声称可用。

local DEPOT = { x = -322.0, y = -1546.0, z = 30.0 }   -- 环卫局院内（与旧壳任务同一片）

-- 收运点池（10 个）。每档从前到后取前 N 个，保证低阶是高阶的子集，玩家学得会路线。
local STOPS = {
    { x = 200.5,   y = -1700.0, z = 29.5 },   -- Mirror Park
    { x = -1450.0, y = -520.0,  z = 34.5 },   -- Del Perro
    { x = 425.0,   y = -1400.0, z = 29.3 },   -- Davis
    { x = 810.0,   y = -1500.0, z = 27.0 },   -- La Mesa
    { x = 130.0,   y = -1050.0, z = 29.3 },   -- Pillbox 北
    { x = -700.0,  y = -900.0,  z = 22.0 },   -- Vespucci
    { x = 1180.0,  y = -310.0,  z = 69.0 },   -- Mirror Park 东
    { x = -1900.0, y = 200.0,   z = 88.0 },   -- Richman
    { x = 70.0,    y = 120.0,   z = 79.0 },   -- Vinewood
    { x = 500.0,   y = 100.0,   z = 96.0 },   -- Rockford Hills
}

--- 组装一条路线的 steps：报到 → N 个收运点（validator）→ 交回
---@param stops number 收运点数量
---@return table steps
local function buildSteps(stops)
    local steps = {
        {
            id = 'step_report_in',
            title = '报到',
            description = '到环卫局领车与收运单',
            type = 'interact',
            data = {
                coords = DEPOT, radius = 8.0, duration = 3000,
                label = '领取收运单...', in_vehicle = false,
            },
        },
    }

    for index = 1, stops do
        local point = STOPS[index]
        steps[#steps + 1] = {
            id = ('step_stop_%02d'):format(index),
            title = ('收运点 %d/%d'):format(index, stops),
            description = '把该点的垃圾袋装车',
            type = 'validator',
            data = {
                coords = point,
                radius = 12.0,
                validator_id = 'validate_route_stop',
                validator_data = {
                    index = index,
                    index_total = stops,
                    job = 'garbage',
                    require_duty = true,
                },
            },
        }
    end

    steps[#steps + 1] = {
        id = 'step_report_out',
        title = '交回',
        description = '把车开回环卫局并交回收运单',
        type = 'interact',
        data = {
            coords = DEPOT, radius = 8.0, duration = 3000,
            label = '交回收运单...', in_vehicle = false,
        },
    }

    return steps
end

return {
    {
        id = 'garbage_v1_city',
        title = '城区收运（4 站）',
        description = '沿最近的四个收运点走一圈，适合刚上岗的环卫工。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 8 },
        rewards = {
            money = { type = 'bank', min = 370, max = 370 },   -- 4×30 + 10×25
            rep = { garbage = 8 },                              -- 5 + 10/3
        },
        steps = buildSteps(4),
    },
    {
        id = 'garbage_v1_district',
        title = '片区收运（6 站）',
        description = '六个收运点，跨两个片区，垃圾袋比城区多一倍。',
        category = 'civilian',
        level = 2,
        required_tags = { role = 'civilian' },
        conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 8 },
        rewards = {
            money = { type = 'bank', min = 705, max = 705 },   -- 6×30 + 21×25
            rep = { garbage = 12 },                             -- 5 + 21/3
        },
        steps = buildSteps(6),
    },
    {
        id = 'garbage_v1_full',
        title = '全城收运（8 站）',
        description = '八个收运点跑遍全城，一趟抵别人两趟。',
        category = 'civilian',
        level = 3,
        required_tags = { role = 'civilian' },
        conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 8 },
        rewards = {
            money = { type = 'bank', min = 1140, max = 1140 },  -- 8×30 + 36×25
            rep = { garbage = 17 },                             -- 5 + 36/3
        },
        steps = buildSteps(8),
    },
}
