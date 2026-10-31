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

--- 物品使用入口。qb-inventory 的物品事件是客户端可触发的，所以归属校验必须在服务端做。
RegisterNetEvent('qb-inventory:server:UseItem', function(item)
    local src = source
    if type(item) ~= 'table' then return end
    local name = tostring(item.name or '')
    if name == '' then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 真的持有才生效：没有这件物品的玩家发这个事件什么都不该发生
    if not Player.Functions.GetItemByName(name) then return end

    local result, reason = consume(Player, name)
    if not result then return end

    TriggerClientEvent('QBCore:Notify', src,
        ('%s：饥饿 %d / 口渴 %d'):format(name, math.floor(result.hunger), math.floor(result.thirst)),
        'success', 3500)
end)

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
