-- server/main.lua — 饥渴/酒精/药物的唯一写者（custom-consumables）
--
-- 为什么要有这个资源：本服没有 qb-smallresources，qb-core 只在 `loops.lua` 里**读**
-- metadata.hunger/thirst 来扣血，没有任何地方写它 —— 于是食物吃了不顶饿、HUD 永远 100、
-- 酒测也没有数据源。这个资源补的就是"谁在写这几个数"。
--
-- 设计：
--   * 状态存在 PlayerData.metadata（hunger / thirst / alcohol / drug_level），
--     qb-hud 与警用酒测因此都能直接读到，不需要各自再存一份；
--   * 物品使用严格校验归属（没这瓶水就不该涨），并有每物品冷却；
--   * 衰减只在这个资源的线程里做（单一写者），别的资源只读。

local QBCore = exports['qb-core']:GetCoreObject()

local lastUse = {}       -- 'cid:item' -> 毫秒时间戳
local lastTick = {}      -- cid -> 上次结算代谢的毫秒时间戳

local function now()
    return GetGameTimer()
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--- 把玩家身上的状态读成一张表（缺省按满值/清醒算）。
local function statusOf(player)
    local meta = player.PlayerData.metadata or {}
    return {
        hunger = tonumber(meta.hunger) or 100.0,
        thirst = tonumber(meta.thirst) or 100.0,
        alcohol = tonumber(meta.alcohol) or 0.0,
        drug = tonumber(meta.drug_level) or 0.0,
    }
end

--- 结算酒精/药物的自然代谢（按时间差，不按调用次数）。
local function metabolize(player)
    local cid = player.PlayerData.citizenid
    local meta = player.PlayerData.metadata or {}
    local alcohol = tonumber(meta.alcohol) or 0.0
    local drug = tonumber(meta.drug_level) or 0.0
    if alcohol <= 0 and drug <= 0 then
        lastTick[cid] = now()
        return
    end
    local last = lastTick[cid] or now()
    local elapsed = math.max(0, (now() - last) / 1000)
    lastTick[cid] = now()
    if alcohol > 0 then
        alcohol = clamp(alcohol - elapsed * Config.AlcoholDecayPerSecond, 0.0, 1.0)
        player.Functions.SetMetaData('alcohol', alcohol)
    end
    if drug > 0 then
        drug = clamp(drug - elapsed * Config.DrugDecayPerSecond, 0.0, 1.0)
        player.Functions.SetMetaData('drug_level', drug)
    end
end

--- 吃/喝一个物品。
---@return table|nil result { hunger, thirst, alcohol, drug }
---@return string|nil reason
local function consume(player, itemName)
    local spec = Config.Consumables[itemName]
    if not spec then return nil, 'not_consumable' end

    local cid = player.PlayerData.citizenid
    local key = cid .. ':' .. itemName
    local cooldown = tonumber(spec.cooldownMs) or 0
    if cooldown > 0 and lastUse[key] and (now() - lastUse[key]) < cooldown then
        return nil, 'cooldown'
    end
    lastUse[key] = now()

    local status = statusOf(player)
    local hunger = clamp(status.hunger + (tonumber(spec.hunger) or 0), 0.0, 100.0)
    local thirst = clamp(status.thirst + (tonumber(spec.thirst) or 0), 0.0, 100.0)
    local alcohol = clamp(status.alcohol + (tonumber(spec.alcohol) or 0), 0.0, 1.0)
    local drug = clamp(status.drug + (tonumber(spec.drug) or 0), 0.0, 1.0)

    player.Functions.SetMetaData('hunger', hunger)
    player.Functions.SetMetaData('thirst', thirst)
    if spec.alcohol then player.Functions.SetMetaData('alcohol', alcohol) end
    if spec.drug then player.Functions.SetMetaData('drug_level', drug) end

    return { hunger = hunger, thirst = thirst, alcohol = alcohol, drug = drug }
end

--- 物品使用入口。
---
--- ⚠ 走 `QBCore.Functions.CreateUseableItem`，**不要**监听 `qb-inventory:server:UseItem`：
--- qb-inventory 的用物品路径是 `UseItem(name, src, itemData)` → `QBCore.Functions.CanUseItem`
--- → 调注册进来的回调，它**从来不**发那个网络事件。原来只挂 `RegisterNetEvent`，
--- 于是吃了完全没反应（2026-11-10 真机：买了水和食物，用了既不涨饥渴也不消耗）。
local function notifyNeeds(src, itemName, result)
    -- P2 试点：结果类通知走三层分派（左下角 feed），老 API 作为回退。
    -- 入口是 custom-notify 的 export —— `_G.Bus` 是每个资源自己的 state，跨资源看不到。
    local pushed = pcall(function()
        exports['custom-notify']:Push(src, 'feed',
            ('%s：饥饿 %d / 口渴 %d'):format(itemName, math.floor(result.hunger),
                math.floor(result.thirst)), nil, { icon = '🍽' })
    end)
    if not pushed then
        TriggerClientEvent('QBCore:Notify', src,
            ('%s：饥饿 %d / 口渴 %d'):format(itemName, math.floor(result.hunger), math.floor(result.thirst)),
            'success', 3500)
    end
    -- qb-hud 的圆环只认这个事件（qb-core 自己扣饥饿时也发它）
    TriggerClientEvent('hud:client:UpdateNeeds', src, result.hunger, result.thirst)
end

for itemName in pairs(Config.Consumables) do
    QBCore.Functions.CreateUseableItem(itemName, function(src)
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then return end
        -- 真的持有才生效：没这件物品就不该涨饥渴
        local item = Player.Functions.GetItemByName(itemName)
        if not item then return end

        local result = consume(Player, itemName)
        if not result then return end

        Player.Functions.RemoveItem(itemName, 1)
        notifyNeeds(src, itemName, result)
    end)
end

-- 定时衰减：单一写者，客户端不参与
CreateThread(function()
    while true do
        Wait(Config.DecayIntervalMs)
        for _, src in ipairs(QBCore.Functions.GetPlayers()) do
            local Player = QBCore.Functions.GetPlayer(src)
            if Player and Player.PlayerData.metadata and Player.PlayerData.metadata.isdead ~= true then
                local status = statusOf(Player)
                Player.Functions.SetMetaData('hunger', clamp(status.hunger - Config.DecayHunger, 0.0, 100.0))
                Player.Functions.SetMetaData('thirst', clamp(status.thirst - Config.DecayThirst, 0.0, 100.0))
                metabolize(Player)
            end
        end
    end
end)

--- 供其它资源读（警用酒测/药检）。
--- 复活后把饥渴"抬到下限"（M-3）。饥渴的唯一写者是本资源，所以别的地方只能调这个。
--- 语义：只抬不压 —— 如果玩家原本更饱，就保持原值（不让救人反而变饿）。
---@param src number 玩家 server id
---@param floor number|nil 下限，默认 50
---@return table|nil result { hunger, thirst }
local function RestoreAfterRevive(src, floor)
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return nil end
    local target = clamp(tonumber(floor) or 50.0, 0.0, 100.0)
    local status = statusOf(player)
    local hunger = math.max(status.hunger, target)
    local thirst = math.max(status.thirst, target)

    player.Functions.SetMetaData('hunger', hunger)
    player.Functions.SetMetaData('thirst', thirst)
    TriggerClientEvent('hud:client:UpdateNeeds', src, hunger, thirst)
    return { hunger = hunger, thirst = thirst }
end

exports('RestoreAfterRevive', RestoreAfterRevive)

--- 复活流程的服务端入口（M-3）。
--- 只作用于 **调用者自己**：不接受 source/target 参数，所以没人能借它给别人抬饥渴。
local reviveRestoreAt = {}
RegisterNetEvent('custom-consumables:server:RestoreAfterRevive', function()
    local src = source
    if not src or src <= 0 then return end
    local nowSec = os.time()
    if reviveRestoreAt[src] and nowSec - reviveRestoreAt[src] < 10 then return end
    reviveRestoreAt[src] = nowSec
    RestoreAfterRevive(src, 50.0)
end)


exports('GetStatus', function(srcOrCid)
    local Player
    if type(srcOrCid) == 'number' then
        Player = QBCore.Functions.GetPlayer(srcOrCid)
    else
        Player = QBCore.Functions.GetPlayerByCitizenId(tostring(srcOrCid or ''))
    end
    if not Player then return nil end
    return statusOf(Player)
end)

exports('GetAlcohol', function(srcOrCid)
    local Player
    if type(srcOrCid) == 'number' then
        Player = QBCore.Functions.GetPlayer(srcOrCid)
    else
        Player = QBCore.Functions.GetPlayerByCitizenId(tostring(srcOrCid or ''))
    end
    if not Player then return 0.0 end
    return statusOf(Player).alcohol
end)

print('[custom-consumables] 饥渴/酒精/药物状态已接管（单一写者）')

--- 诊断：控制台看一眼某人身上的状态（默认关，`setr consumables_dev 1` 打开）。
RegisterCommand('consumables_status', function(src, args)
    if src ~= 0 then return end
    if GetConvar('consumables_dev', '0') ~= '1' then
        print('[custom-consumables] consumables_status 已关闭（setr consumables_dev 1 打开）')
        return
    end
    local target = tonumber(args and args[1]) or 0
    local Player = target ~= 0 and QBCore.Functions.GetPlayer(target) or nil
    if not Player then print('[custom-consumables] 该 source 不在线'); return end
    local s = statusOf(Player)
    print(('[custom-consumables] cid=%s hunger=%.1f thirst=%.1f alcohol=%.2f drug=%.2f'):format(
        tostring(Player.PlayerData.citizenid), s.hunger, s.thirst, s.alcohol, s.drug))
end, false)
