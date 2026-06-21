-- ============================================================================
-- 🗑️ BEFORE: 旧版采矿脚本 (重构前 — 死亡硬编码模式)
-- ============================================================================
-- 问题清单:
--   1. 奖励数值硬编码在脚本里 ($200)，改价需要改代码
--   2. while true 死循环轮询玩家坐标 — CPU 黑洞
--   3. 重复造轮子 — 每个采矿点都要复制粘贴同样的逻辑
--   4. 没有任何经济系数 — 不管服务器是否通胀都发 $200
-- ============================================================================

--[[
-- 旧版: 每个采矿点都像这样写一遍
local miningSpots = {
    { coords = vector3(100.0, 200.0, 30.0), oreType = 'iron' },
    { coords = vector3(150.0, 250.0, 35.0), oreType = 'copper' },
    -- ... 20+ 个采矿点, 每个都硬编码坐标
}

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)  -- 每 0.5 秒轮询一次 — 100 个矿工同时在线 = 每秒 200 次坐标计算!
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        for _, spot in ipairs(miningSpots) do
            local distance = #(playerCoords - spot.coords)
            if distance < 2.0 then
                -- 显示按 E 提示
                if IsControlJustPressed(0, 38) then
                    -- 播放动画
                    TaskStartScenarioInPlace(playerPed, 'WORLD_HUMAN_GARDENER_PLANT', 0, true)
                    Citizen.Wait(3000)

                    -- 硬编码奖励!
                    TriggerServerEvent('mining:giveReward', 'iron_ore', 200)

                    -- 随机给物品
                    local chance = math.random(1, 100)
                    if chance > 80 then
                        TriggerServerEvent('mining:giveItem', 'iron_ore')
                    end
                end
            end
        end
    end
end)

-- 服务端 (又是硬编码)
RegisterNetEvent('mining:giveReward', function(oreType, amount)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    Player.Functions.AddMoney('bank', amount, 'mining')  -- 直接发钱, 无系数, 无热度!
end)
]]


-- ============================================================================
-- ✅ AFTER: 新版采矿 (重构后 — 统一网关 + 事件驱动 + JSON 配置)
-- ============================================================================
-- 改进清单:
--   1. 奖励完全由 core_economy 网关决定 (base × global × heat × bonus)
--   2. PolyZone 事件驱动 — 玩家走入区域才触发, 零轮询
--   3. 新增采矿点 = 新增一行 JSON, 零代码
--   4. 管理员一键改全局乘数, 全服所有采矿点收益同步缩放
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════
-- 配置文件: config/mining_spots.json  (只写一次!)
-- ═══════════════════════════════════════════════════════════════════════
--[[
{
  "activityId": "mining",
  "baseReward": 50,
  "spots": [
    { "coords": {"x":100,"y":200,"z":30}, "oreType": "iron_ore",  "radius": 2.0 },
    { "coords": {"x":150,"y":250,"z":35}, "oreType": "copper_ore", "radius": 2.0 },
    { "coords": {"x":300,"y":180,"z":40}, "oreType": "gold_ore",   "radius": 3.0 }
  ]
}
]]

-- ═══════════════════════════════════════════════════════════════════════
-- 客户端: client/mining.lua  (只写一次, 适用于所有采矿点!)
-- ═══════════════════════════════════════════════════════════════════════
--[[
local config = LoadResourceFile(GetCurrentResourceName(), 'config/mining_spots.json')
local data = json.decode(config)

for _, spot in ipairs(data.spots) do
    local zone = PolyZone:Create(
        vector3(spot.coords.x, spot.coords.y, spot.coords.z),
        { name = 'mining_' .. spot.oreType,
          offset = {0,0,0},
          scale = {spot.radius, spot.radius, 5.0},
          debugPoly = false }
    )

    zone:onPlayerInOut(function(isInside)
        if isInside then
            -- 玩家进入采矿区 → 显示按 E 提示 (零轮询!)
            lib.showTextUI('[E] Mine ' .. spot.oreType)

            -- 等待 E 键 → 播放动画 → 上报服务端
            Citizen.CreateThread(function()
                while isInside do
                    if IsControlJustPressed(0, 38) then
                        TaskStartScenarioInPlace(PlayerPedId(), 'WORLD_HUMAN_GARDENER_PLANT', 0, true)
                        if lib.progressBar then
                            if lib.progressBar({ duration=3000, label='Mining...', canCancel=true }) then
                                TriggerServerEvent('mining:nodeComplete', data.activityId, spot.oreType)
                            end
                        else
                            Citizen.Wait(3000)
                            TriggerServerEvent('mining:nodeComplete', data.activityId, spot.oreType)
                        end
                    end
                    Citizen.Wait(0)
                end
            end)
        else
            lib.hideTextUI()
        end
    end)
end
]]

-- ═══════════════════════════════════════════════════════════════════════
-- 服务端: server/mining.lua  (只写一次!!)
-- ═══════════════════════════════════════════════════════════════════════
--[[
RegisterNetEvent('mining:nodeComplete', function(activityId, oreType)
    local src = source

    -- 🎯 全服唯一入口 — 自动计算 base × global × heat × bonus
    --    global_multiplier: 管理员 set convar economy_global_multiplier 80 → 全服挖矿打八折
    --    heat_coefficient: 挖矿太热门 → 自动从 1.0 降到 0.7
    local baseReward = GetConvarInt('mining_base_reward', 50)  -- 从 economy_baseline.json 读取

    exports['core_economy']:TriggerReward(src, activityId, baseReward, {
        moneytype = 'bank',
        reason = ('mining:%s'):format(oreType),
    })

    -- 随机给矿石 (概率不受经济系数影响)
    if math.random(1, 100) > 70 then
        exports['qb-inventory']:AddItem(src, oreType, 1)
    end
end)
]]
