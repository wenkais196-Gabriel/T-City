-- server/sobriety.lua — 酒精读数（P3-2 的数据源）
--
-- 为什么要有这个文件：本服没有 qb-smallresources，也没有任何"喝醉"状态，
-- 酒测如果没有数据源就只能编一个随机数 —— 那是假结果，比没有更糟。
-- 这里用最小实现补上：喝啤酒/伏特加 → 读数上升 → 随时间衰减。
--
-- 读数 0.0–1.0：
--   < 0.20 清醒   0.20–0.50 微醺   > 0.50 醉
--
-- 只在内存里，重启清零（酒精时效本来就短，不需要落库）。

Sobriety = Sobriety or {}

local levels = {}          -- citizenid -> level
local lastUpdate = {}      -- citizenid -> ms
local DECAY_PER_SECOND = 0.01

-- 能让人上头的物品与增量（qb-core 的 items 里只有这两个）
local DRINKS = {
    beer = 0.25,
    vodka = 0.50,
}

local function now()
    return GetGameTimer()
end

local function applyDecay(cid)
    local level = levels[cid]
    if not level then return 0.0 end
    local last = lastUpdate[cid] or now()
    local elapsed = math.max(0, (now() - last) / 1000)
    lastUpdate[cid] = now()
    level = math.max(0.0, level - elapsed * DECAY_PER_SECOND)
    levels[cid] = level
    return level
end

--- 喝了一口。
function Sobriety.Drink(citizenid, item)
    local gain = DRINKS[tostring(item or '')]
    if not gain then return nil end
    local current = applyDecay(citizenid)
    levels[citizenid] = math.min(1.0, current + gain)
    lastUpdate[citizenid] = now()
    return levels[citizenid]
end

--- 当前读数（0.0–1.0），顺手结算衰减。
function Sobriety.Level(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0.0 end
    return applyDecay(citizenid)
end

--- 分档：清醒 / 微醺 / 醉。
function Sobriety.Label(level)
    if level >= 0.50 then return 'drunk' end
    if level >= 0.20 then return 'tipsy' end
    return 'sober'
end

--- 重置（测试用）。
function Sobriety.Reset()
    levels = {}
    lastUpdate = {}
end

-- 物品使用钩子：qb-inventory 里 useable 的物品走这个事件
RegisterNetEvent('qb-inventory:server:UseItem', function(item)
    local src = source
    if type(item) ~= 'table' then return end
    local name = tostring(item.name or '')
    if not DRINKS[name] then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 归属校验：客户端可以随便发 UseItem，没这瓶酒就不该上头
    if not Player.Functions.GetItemByName(name) then return end
    Sobriety.Drink(Player.PlayerData.citizenid, name)
end)

