local QBCore = exports['qb-core']:GetCoreObject()

-- 状态管理器：用于储存全局/玩家冷却时间
local Cooldowns = {
    StoreRobberyGlobal = {}, -- 商店各收银台/保险箱的全局冷却
    StoreRobberyPlayer = {}, -- 玩家商店抢劫冷却
    HouseRobberyPlayer = {}, -- 玩家房屋搜刮冷却
    HouseRobberyFurniture = {}, -- 家具搜刮防刷状态
    DrugsPlayer = {}         -- 玩家毒品交付冷却
}

-- 调试输出函数
local function DebugPrint(msg)
    -- 默认从系统 Convar 或配置读取调试开关
    local enableDebug = GetConvar("general_enable_debug", "true") == "true"
    if enableDebug then
        print(('[custom-crime] %s'):format(msg))
    end
end

-- ==========================================
--                  配 置 获 取
-- ==========================================

local function GetBoolConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return val == "true" or val == "1" end
    return default
end

local function GetIntConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return math.floor(tonumber(val) or default) end
    return default
end

-- ==========================================
--                  商 店 抢 劫 校验
-- ==========================================

-- @param src number 玩家服务器 ID
-- @param registerId string 收银台或保险箱 ID (如果是保险箱可以以 "safe_" .. id 传入)
-- @param isDone boolean 是否是结算奖励阶段
-- @return boolean 是否允许进行/领取奖励
local function CheckStoreRobbery(src, registerId, isDone)
    if not GetBoolConvar("crime_enable", true) or not GetBoolConvar("crime_enable_storerobbery", true) then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_disabled'), "error")
        return false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    -- 1. Police online check
    local minPolice = GlobalState and GlobalState.crime_min_police_storerobbery
        or GetIntConvar("crime_min_police_storerobbery", 2)
    local policeCount = QBCore.Functions.GetDutyCount('police')
    if policeCount < minPolice then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_need_police', minPolice), "error")
        return false
    end

    -- 2. 玩家冷却时间校验 (防瞬间跨店速刷)
    local now = os.time()
    local playerCD = GetIntConvar("crime_cooldown_storerobbery", 1800)
    local lastPlayerRob = Cooldowns.StoreRobberyPlayer[Player.PlayerData.citizenid] or 0
    local diffPlayer = now - lastPlayerRob
    if diffPlayer < 10 then -- 防客户端多发包瞬间触发
        local alertText = ("**警报级别**: 🚨 异常 (频繁包触发)\n**玩家**: %s (%s)\n**操作**: 商店抢劫 (%s)\n**间隔时间**: %d秒"):format(
            GetPlayerName(src), Player.PlayerData.citizenid, tostring(registerId), diffPlayer
        )
        exports['custom-logs']:LogSecurity("商店抢劫高频调用", alertText)
        return false
    end

    -- 3. 全局目标冷却校验 (针对单个收银机进行 CD 控制)
    local lastGlobalRob = Cooldowns.StoreRobberyGlobal[registerId] or 0
    local diffGlobal = now - lastGlobalRob
    if isDone and diffGlobal < playerCD then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_recently_robbed'), "error")
        return false
    end

    -- 如果是结算阶段，更新冷却时间
    if isDone then
        Cooldowns.StoreRobberyPlayer[Player.PlayerData.citizenid] = now
        Cooldowns.StoreRobberyGlobal[registerId] = now
        
        -- 记录常规审计日志 (使用 custom-logs 导出)
        local logText = ("**玩家**: %s (%s)\n**位置**: 商店收银/保险箱 %s\n**状态**: 成功获取犯罪收益\n**当前在线警察**: %d 名"):format(
            GetPlayerName(src), Player.PlayerData.citizenid, tostring(registerId), policeCount
        )
        exports['custom-logs']:LogGeneric("商店抢劫成功", logText, 65280) -- 绿色
    end

    return true
end

exports('CheckStoreRobbery', CheckStoreRobbery)

-- ==========================================
--                  入 室 盗 窃 校验
-- ==========================================

-- @param src number 玩家服务器 ID
-- @param houseId string 房屋 ID
-- @param cabinId string 柜子/家具 ID
-- @return boolean 是否允许搜刮
local function CheckHouseRobbery(src, houseId, cabinId)
    if not GetBoolConvar("crime_enable", true) or not GetBoolConvar("crime_enable_houserobbery", true) then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_disabled'), "error")
        return false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    -- 1. Police online check
    local minPolice = GetIntConvar("crime_min_police_houserobbery", 0)
    local policeCount = QBCore.Functions.GetDutyCount('police')
    if policeCount < minPolice then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_need_police', minPolice), "error")
        return false
    end

    -- 2. 家具状态唯一性检验 (防止多开并发包刷取)
    local furnitureKey = ("%s_%s"):format(tostring(houseId), tostring(cabinId))
    if Cooldowns.HouseRobberyFurniture[furnitureKey] then
        local alertText = ("**警报级别**: 🚨 重复搜刮企图 (疑似封包篡改)\n**玩家**: %s (%s)\n**位置**: 房屋=%s, 家具=%s"):format(
            GetPlayerName(src), Player.PlayerData.citizenid, tostring(houseId), tostring(cabinId)
        )
        exports['custom-logs']:LogSecurity("房屋重复搜刮拦截", alertText)
        return false
    end

    -- 3. 玩家冷却时间校验
    local now = os.time()
    local lastPlayerRob = Cooldowns.HouseRobberyPlayer[Player.PlayerData.citizenid] or 0
    local playerCD = 3 -- 每次搜刮家具最小间隔 (3秒)，防止瞬间触发全部家具
    if now - lastPlayerRob < playerCD then
        return false
    end

    -- 更新状态
    Cooldowns.HouseRobberyPlayer[Player.PlayerData.citizenid] = now
    Cooldowns.HouseRobberyFurniture[furnitureKey] = true

    -- 定期清理家具缓存，使房屋可在30分钟 (或CD参数) 后被重新搜刮
    local houseCD = GetIntConvar("crime_cooldown_houserobbery", 1800)
    SetTimeout(houseCD * 1000, function()
        Cooldowns.HouseRobberyFurniture[furnitureKey] = nil
    end)

    -- 系统备案日志 (使用 custom-logs 导出)
    local logText = ("**玩家**: %s (%s)\n**房屋**: %s\n**家具**: %s\n**状态**: 成功搜刮柜台"):format(
        GetPlayerName(src), Player.PlayerData.citizenid, tostring(houseId), tostring(cabinId)
    )
    exports['custom-logs']:LogGeneric("房屋搜刮审计", logText, 7434190)

    return true
end

exports('CheckHouseRobbery', CheckHouseRobbery)

-- ==========================================
--                  毒 品 交 付 校验
-- ==========================================

-- @param src number 玩家服务器 ID
-- @return boolean 是否允许交付
local function CheckDrugs(src)
    if not GetBoolConvar("crime_enable", true) or not GetBoolConvar("crime_enable_drugs", true) then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_disabled'), "error")
        return false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    -- 1. Police online check
    local minPolice = GetIntConvar("crime_min_police_drugs", 0)
    local policeCount = QBCore.Functions.GetDutyCount('police')
    if policeCount < minPolice then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_need_police', minPolice), "error")
        return false
    end

    -- 2. 冷却时间校验
    local now = os.time()
    local drugCD = GetIntConvar("crime_cooldown_drugs", 300)
    local lastPlayerRob = Cooldowns.DrugsPlayer[Player.PlayerData.citizenid] or 0
    local diff = now - lastPlayerRob
    if diff < drugCD then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_delivery_cooldown', drugCD - diff), "error")
        return false
    end

    -- 更新状态
    Cooldowns.DrugsPlayer[Player.PlayerData.citizenid] = now

    -- 系统备案日志 (使用 custom-logs 导出)
    local logText = ("**玩家**: %s (%s)\n**行为**: 毒品成功交付\n**当前在线警察**: %d 名"):format(
        GetPlayerName(src), Player.PlayerData.citizenid, policeCount
    )
    exports['custom-logs']:LogGeneric("毒品交易完成", logText, 4289797)

    return true
end

exports('CheckDrugs', CheckDrugs)

-- ==========================================
--          洗 钱 扣 率 折 旧 管 道 (v0.5)
-- ==========================================
--
-- 玩家可将脏钱(cash)通过当铺/洗车行渠道洗白为干净银行资金
-- 洗钱过程伴随固定扣率折旧（默认 25%），大额操作触发 Discord 警报
--
-- 流程:
--   脏钱(cash) ──→ [LaunderMoney] ──→ 干净钱(bank) × (1 - 折旧率)
--                                              ↓
--                                       大额 > $10k → Discord #economy-log

--- 获取当前洗钱折旧率（从 Convar 读取，动态可调）
local function GetLaunderRate()
    local rate = GetConvar("crime_launder_rate", "0.75")
    local num = tonumber(rate)
    if not num or num <= 0 or num > 1 then return 0.75 end
    return num
end

--- 洗钱核心函数
---@param src number 玩家服务器 ID
---@param amount number 要洗的脏钱金额
---@return boolean success, number cleanAmount, string message
local function LaunderMoney(src, amount)
    if not GetBoolConvar("crime_enable", true) then
        return false, 0, "犯罪系统已禁用"
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, 0, "玩家不存在" end

    amount = tonumber(amount) or 0
    if amount <= 0 then return false, 0, "金额无效" end

    -- 1. 最小洗钱金额校验
    local minLaunder = GetIntConvar("crime_launder_min", 1000)
    if amount < minLaunder then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_min_launder', minLaunder), "error")
        return false, 0, "低于最低洗钱限额"
    end

    -- 2. 玩家现金余额检查
    local cashBalance = Player.Functions.GetMoney('cash')
    if cashBalance < amount then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_not_enough_cash'), "error")
        return false, 0, "现金不足"
    end

    -- 3. 警察在线检查（洗钱时警察可能突袭）
    local policeCount = QBCore.Functions.GetDutyCount('police')
    local minPoliceLaunder = GetIntConvar("crime_min_police_launder", 0)
    if policeCount < minPoliceLaunder then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_need_police_launder', minPoliceLaunder), "error")
        return false, 0, "警察不足"
    end

    -- 4. 冷却时间校验（防连续洗钱刷屏）
    local now = os.time()
    local launderCD = GetIntConvar("crime_cooldown_launder", 60)  -- 默认 60 秒冷却
    local lastLaunder = Cooldowns.LaunderPlayer and Cooldowns.LaunderPlayer[Player.PlayerData.citizenid] or 0
    if now - lastLaunder < launderCD then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_launder_cooldown', launderCD - (now - lastLaunder)), "error")
        return false, 0, "冷却中"
    end

    -- 5. 应用折旧率计算净收
    local rate = GetLaunderRate()
    local cleanAmount = math.floor(amount * rate + 0.5)
    local loss = amount - cleanAmount

    -- 6. 先扣脏钱（从 cash 扣）
    local deductSuccess = Player.Functions.RemoveMoney('cash', amount, 'LaunderMoney:deduct')
    if not deductSuccess then
        return false, 0, "扣款失败"
    end

    -- 7. 入干净钱（到 bank）— 经统一经济出口
    if exports['custom-main'] and exports['custom-main'].AddScaledMoney then
        exports['custom-main']:AddScaledMoney(src, 'bank', cleanAmount, 'LaunderMoney:deposit')
    else
        Player.Functions.AddMoney('bank', cleanAmount, 'LaunderMoney:deposit')
    end

    -- 8. 更新冷却状态
    if not Cooldowns.LaunderPlayer then Cooldowns.LaunderPlayer = {} end
    Cooldowns.LaunderPlayer[Player.PlayerData.citizenid] = now

    -- 9. 审计日志
    local logText = ("**玩家**: %s (%s)\n**洗钱金额**: $%d\n**折旧率**: %.0f%%\n**手续费损失**: $%d\n**净入银行**: $%d\n**当前在线警察**: %d 名"):format(
        GetPlayerName(src), Player.PlayerData.citizenid,
        amount, (1 - rate) * 100, loss, cleanAmount, policeCount
    )

    if amount >= 10000 then
        -- 大额洗钱 → Discord #economy-log 红色高亮
        exports['custom-logs']:LogEconomy("🧺 大额洗钱交易", logText, 16744576)
    else
        exports['custom-logs']:LogGeneric("洗钱交易", logText, 16763904)
    end

    -- 10. 通知玩家
    TriggerClientEvent('QBCore:Notify', src, _L(src, 'crime_launder_success', cleanAmount, (1 - rate) * 100, loss), "success")

    return true, cleanAmount, "洗钱成功"
end

exports('LaunderMoney', LaunderMoney)

-- ==========================================
--    多 层 洗 钱 管 道 (v0.7 Phase 3)
-- ==========================================
-- 支持层级递进洗钱，每层不同折旧率和冷却
-- cartel 成员享受专属低折旧率
--
-- 层级:
--   L1: 现金 → 当铺      (75%保留率, 60s冷却)
--   L2: 当铺 → 壳公司    (85%保留率, 300s冷却)
--   L3: 壳公司 → 投资账户 (92%保留率, 900s冷却)
--   L4: 投资 → 银行      (98%保留率, 1800s冷却)
--
-- cartel 专属通道: 每层保留率 +5%

-- 多层冷却追踪
if not Cooldowns.MultiLaunder then
    Cooldowns.MultiLaunder = {}
end

-- 洗钱层级配置
local LaunderTiers = {
    { level = 1, label = '当铺',  fromLabel = '现金', toLabel = '当铺代币',
      baseRate = 0.75, cartelBonus = 0.05, maxAmount = 50000,  cooldown = 60 },
    { level = 2, label = '壳公司', fromLabel = '当铺代币', toLabel = '投资凭证',
      baseRate = 0.85, cartelBonus = 0.05, maxAmount = 150000, cooldown = 300 },
    { level = 3, label = '投资',  fromLabel = '投资凭证', toLabel = '干净资金',
      baseRate = 0.92, cartelBonus = 0.03, maxAmount = 500000, cooldown = 900 },
    { level = 4, label = '银行结算', fromLabel = '干净资金', toLabel = '银行',
      baseRate = 0.98, cartelBonus = 0.02, maxAmount = 1000000, cooldown = 1800 },
}

--- 多层洗钱核心函数
---@param src number 玩家
---@param amount number 金额
---@param tierLevel number 洗钱层级 (1-4)
---@return boolean success, number cleanAmount, string message
local function MultiLaunderMoney(src, amount, tierLevel)
    if not GetBoolConvar("crime_enable", true) then
        return false, 0, "犯罪系统已禁用"
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, 0, "玩家不存在" end

    amount = tonumber(amount) or 0
    tierLevel = tonumber(tierLevel) or 1
    if amount <= 0 then return false, 0, "金额无效"
    elseif tierLevel < 1 or tierLevel > 4 then return false, 0, "无效的洗钱层级" end

    local tier = LaunderTiers[tierLevel]

    -- 1. 单层金额上限
    if amount > tier.maxAmount then
        TriggerClientEvent('QBCore:Notify', src,
            _L(src, 'crime_tier_max', tier.maxAmount), 'error')
        return false, 0, "超出单层限额"
    end

    -- 2. 多层冷却
    local now = os.time()
    if not Cooldowns.MultiLaunder[Player.PlayerData.citizenid] then
        Cooldowns.MultiLaunder[Player.PlayerData.citizenid] = {}
    end
    local lastTier = Cooldowns.MultiLaunder[Player.PlayerData.citizenid][tierLevel] or 0
    if now - lastTier < tier.cooldown then
        TriggerClientEvent('QBCore:Notify', src,
            _L(src, 'crime_tier_cooldown', tier.label, tier.cooldown - (now - lastTier)), 'error')
        return false, 0, "冷却中"
    end

    -- 3. cartel 成员判定
    local isCartel = false
    if Bus and Bus.CartelService then
        isCartel = Bus.CartelService.IsMember(src)
    else
        local gang = Player.PlayerData.gang
        isCartel = gang and gang.name == 'cartel'
    end

    -- 4. 计算折旧率
    local rate = tier.baseRate
    if isCartel then rate = math.min(1.0, rate + tier.cartelBonus) end

    local cleanAmount = math.floor(amount * rate + 0.5)
    local loss = amount - cleanAmount

    -- 5. L1从cash扣，L2+从标记资产扣（简化：直接从cash扣）
    local deductOk = Player.Functions.RemoveMoney('cash', amount, ('MultiLaunder:L%d'):format(tierLevel))
    if not deductOk then return false, 0, "扣款失败" end

    -- 6. 入账
    if tierLevel == 4 then
        -- 最终层: 入 bank
        if exports['custom-main'] and exports['custom-main'].AddScaledMoney then
            exports['custom-main']:AddScaledMoney(src, 'bank', cleanAmount, 'MultiLaunder:L4')
        else
            Player.Functions.AddMoney('bank', cleanAmount, 'MultiLaunder:L4')
        end
    else
        -- 中间层: 入 cash (模拟中间资产)
        Player.Functions.AddMoney('cash', cleanAmount, ('MultiLaunder:L%d'):format(tierLevel))
    end

    -- 7. 冷却
    Cooldowns.MultiLaunder[Player.PlayerData.citizenid][tierLevel] = now

    -- 8. 审计
    local cartelTag = isCartel and ' [Cartel专属]' or ''
    local logText = ('**玩家**: %s (%s)\n**层级**: L%d %s%s\n**洗入**: $%d\n**保留率**: %.0f%%\n**手续费**: $%d\n**净得**: $%d'):format(
        GetPlayerName(src), Player.PlayerData.citizenid,
        tierLevel, tier.label, cartelTag, amount, rate * 100, loss, cleanAmount)

    if exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('多层洗钱', logText, isCartel and 16738657 or 16763904)
    end

    TriggerClientEvent('QBCore:Notify', src,
        ('[L%d] %s: $%d → $%d (%.0f%%%s)'):format(
            tierLevel, tier.label, amount, cleanAmount, rate * 100, cartelTag),
        'success')

    return true, cleanAmount, "洗钱成功"
end

exports('MultiLaunderMoney', MultiLaunderMoney)

--- 获取洗钱层级信息
local function GetLaunderTiers(src)
    local Player = QBCore.Functions.GetPlayer(src)
    local isCartel = false
    if Player then
        local gang = Player.PlayerData.gang
        isCartel = gang and gang.name == 'cartel'
    end

    local tiers = {}
    for _, t in ipairs(LaunderTiers) do
        local rate = t.baseRate
        if isCartel then rate = math.min(1.0, rate + t.cartelBonus) end
        table.insert(tiers, {
            level = t.level,
            label = t.label,
            rate = rate,
            maxAmount = t.maxAmount,
            cooldown = t.cooldown,
            isCartel = isCartel,
        })
    end
    return tiers
end

exports('GetLaunderTiers', GetLaunderTiers)

-- 获取当前洗钱折旧率（供前端展示）
exports('GetLaunderRate', GetLaunderRate)
