-- ============================================================================
-- ItemDurabilityService — 物品耐久归零销毁系统 (v1.0.0)
-- ============================================================================
-- 核心原则: "物品彻底消失制" — 耐久归零后物品从背包永久移除
--   迫使玩家不断投入资金购买新材料，驱动经济循环
--
-- 机制:
--   - 武器: 每发射 N 发子弹消耗 1 耐久，归零后武器报废
--   - 防弹衣: 每次被击中消耗 1 耐久，归零后防弹衣消失
--   - 工具 (开锁器/维修包): 每次使用消耗 1 耐久，归零即销毁
--   - 维修: 走 SinkService.Withdraw('weapon_repair')
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ── 配置 ──────────────────────────────────────────────────────────────

-- 耐久配置: { [itemName] = { maxDurability = N, degradePerUse = M, repairBaseCost = P } }
local DurabilityConfig = {
    -- 武器类 (每次射击消耗 1 耐久)
    weapon_pistol =       { maxDurability = 500,  degradePerUse = 1, repairCost = 500 },
    weapon_combatpistol = { maxDurability = 400,  degradePerUse = 1, repairCost = 650 },
    weapon_microsmg =     { maxDurability = 350,  degradePerUse = 1, repairCost = 800 },
    weapon_smg =          { maxDurability = 300,  degradePerUse = 1, repairCost = 1000 },
    weapon_carbinerifle = { maxDurability = 250,  degradePerUse = 1, repairCost = 1500 },
    weapon_pumpshotgun =  { maxDurability = 200,  degradePerUse = 2, repairCost = 1200 },
    weapon_sniperrifle =  { maxDurability = 150,  degradePerUse = 2, repairCost = 2000 },

    -- 防弹衣 (每次被击中消耗 1 耐久)
    armor =               { maxDurability = 5,    degradePerUse = 1, repairCost = 0 }, -- 不可维修，直接报废

    -- 工具类 (每次使用消耗 1 耐久)
    lockpick =            { maxDurability = 10,   degradePerUse = 1, repairCost = 0 }, -- 一次性工具
    advancedlockpick =    { maxDurability = 20,   degradePerUse = 1, repairCost = 0 },
    repairkit =           { maxDurability = 5,    degradePerUse = 1, repairCost = 300 },
    advancedrepairkit =   { maxDurability = 8,    degradePerUse = 1, repairCost = 500 },
}

-- ── 内部: durability metadata 读写 ────────────────────────────────────

---从物品 metadata 中读取耐久度
---@param itemInfo table 物品信息 (含 .info 字段)
---@return number currentDurability
local function getDurability(itemInfo)
    if not itemInfo or not itemInfo.info then
        return nil -- 无 metadata → 视为全新
    end
    local info = itemInfo.info
    if type(info) == 'string' then
        local ok, decoded = pcall(json.decode, info)
        if ok and type(decoded) == 'table' then
            info = decoded
        else
            return nil
        end
    end
    return tonumber(info.durability)
end

---设置物品耐久度
---@param itemInfo table
---@param durability number
---@return table newInfo
local function setDurability(itemInfo, durability)
    local info = itemInfo.info or {}
    if type(info) == 'string' then
        local ok, decoded = pcall(json.decode, info)
        if ok and type(decoded) == 'table' then
            info = decoded
        else
            info = {}
        end
    end
    info.durability = durability
    return info
end

-- ── 公开 API ──────────────────────────────────────────────────────────

---物品使用后降低耐久度
---@param source number
---@param itemName string
---@param slot number|nil 物品槽位 (可选)
---@return boolean destroyed 是否已销毁
---@return number|nil remainingDurability
function DegradeItem(source, itemName, slot)
    local config = DurabilityConfig[itemName]
    if not config then return false, nil end -- 不在耐久管理范围内

    if GetResourceState('qb-inventory') == 'missing' then
        return false, nil
    end

    -- 获取物品当前耐久
    local itemData = exports['qb-inventory']:GetItemBySlot(source, slot or 1)
    if not itemData then return false, nil end

    local currentDurability = getDurability(itemData)
    if currentDurability == nil then
        currentDurability = config.maxDurability -- 首次使用，设为满耐久
    end

    -- 降低耐久
    local degradeAmount = config.degradePerUse or 1
    local newDurability = currentDurability - degradeAmount

    if newDurability <= 0 then
        -- 耐久归零 → 物品销毁
        exports['qb-inventory']:RemoveItem(source, itemName, 1, slot)
        TriggerClientEvent('QBCore:Notify', source,
            ('%s has broken and been destroyed!'):format(itemName), 'error')

        -- 触发事件供日志
        TriggerEvent('durability:server:itemDestroyed', source, itemName, 0)
        return true, 0
    end

    -- 更新耐久 metadata
    local newInfo = setDurability(itemData, newDurability)
    exports['qb-inventory']:SetItemInfo(source, slot, newInfo)

    -- 低耐久警告 (20% 以下)
    local pct = newDurability / config.maxDurability
    if pct <= 0.2 then
        TriggerClientEvent('QBCore:Notify', source,
            ('⚠️ %s durability low: %d/%d'):format(itemName, newDurability, config.maxDurability), 'primary')
    end

    return false, newDurability
end

---维修物品 (恢复耐久)
---@param source number
---@param itemName string
---@param slot number
---@return boolean repaired
---@return number cost
function RepairItem(source, itemName, slot)
    local config = DurabilityConfig[itemName]
    if not config then return false, 0 end
    if config.repairCost <= 0 then return false, 0 end

    local cost = config.repairCost

    -- 扣款走 SinkService
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false, 0 end

    if _G.Bus and _G.Bus.SinkService then
        local ok = _G.Bus.SinkService.Withdraw(source, cost, 'weapon_repair',
            ('repair:%s'):format(itemName))
        if not ok then return false, 0 end
    else
        Player.Functions.RemoveMoney('bank', cost, ('repair:%s'):format(itemName))
    end

    -- 恢复耐久
    if GetResourceState('qb-inventory') ~= 'missing' then
        local newInfo = { durability = config.maxDurability }
        exports['qb-inventory']:SetItemInfo(source, slot, newInfo)
    end

    TriggerClientEvent('QBCore:Notify', source,
        ('%s repaired to full durability for $%d'):format(itemName, cost), 'success')
    return true, cost
end

---获取物品耐久百分比
---@param itemName string
---@param itemInfo table
---@return number|nil percentage (0-100)
function GetDurabilityPercent(itemName, itemInfo)
    local config = DurabilityConfig[itemName]
    if not config then return nil end

    local current = getDurability(itemInfo)
    if current == nil then return 100 end

    return math.floor(current / config.maxDurability * 100)
end

-- ── 事件监听: 武器射击耐久消耗 ──────────────────────────────────────

-- 注意: 武器射击事件需要由 qb-weapons 或相关武器脚本触发
-- 这里注册监听器等待外部脚本调用
RegisterNetEvent('durability:server:onWeaponFired', function(itemName)
    local src = source
    if not DurabilityConfig[itemName] then return end
    -- 找到该武器的槽位
    -- 简单实现: 从第一个匹配的物品开始消耗耐久
    local destroyed, remaining = DegradeItem(src, itemName, nil)
    if destroyed then
        TriggerClientEvent('QBCore:Notify', src, 'Your weapon has been destroyed!', 'error')
    end
end)

print('[ItemDurability] ✅ 物品耐久系统已启动')
print(('[ItemDurability]   管理物品: %d 种 | 归零即销毁 | 维修走 SinkService'):format(
    (function() local c = 0; for _ in pairs(DurabilityConfig) do c = c + 1 end; return c end)()))
