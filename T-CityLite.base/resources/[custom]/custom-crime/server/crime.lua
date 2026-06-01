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
        TriggerClientEvent('QBCore:Notify', src, "该犯罪玩法目前已禁用", "error")
        return false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    -- 1. 警察在线数量检查
    local minPolice = GetIntConvar("crime_min_police_storerobbery", 0)
    local policeCount = QBCore.Functions.GetDutyCount('police')
    if policeCount < minPolice then
        TriggerClientEvent('QBCore:Notify', src, ("需要至少 %d 名执勤警察才能进行此活动"):format(minPolice), "error")
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
        TriggerClientEvent('QBCore:Notify', src, "该位置刚刚被抢过，目前没有任何有价值的财务", "error")
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
        TriggerClientEvent('QBCore:Notify', src, "该犯罪玩法目前已禁用", "error")
        return false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    -- 1. 警察在线数量检查
    local minPolice = GetIntConvar("crime_min_police_houserobbery", 0)
    local policeCount = QBCore.Functions.GetDutyCount('police')
    if policeCount < minPolice then
        TriggerClientEvent('QBCore:Notify', src, ("需要至少 %d 名执勤警察才能进行此活动"):format(minPolice), "error")
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
        TriggerClientEvent('QBCore:Notify', src, "该犯罪玩法目前已禁用", "error")
        return false
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    -- 1. 警察在线数量检查
    local minPolice = GetIntConvar("crime_min_police_drugs", 0)
    local policeCount = QBCore.Functions.GetDutyCount('police')
    if policeCount < minPolice then
        TriggerClientEvent('QBCore:Notify', src, ("需要至少 %d 名执勤警察才能进行此活动"):format(minPolice), "error")
        return false
    end

    -- 2. 冷却时间校验
    local now = os.time()
    local drugCD = GetIntConvar("crime_cooldown_drugs", 300)
    local lastPlayerRob = Cooldowns.DrugsPlayer[Player.PlayerData.citizenid] or 0
    local diff = now - lastPlayerRob
    if diff < drugCD then
        TriggerClientEvent('QBCore:Notify', src, ("交付过于频繁，请等待 %d 秒"):format(drugCD - diff), "error")
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
