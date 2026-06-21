-- key_manager.lua — 服务端权威钥匙管理器
--
-- 核心数据结构: 内存 O(1) 哈希表
--   Keys[plate] = { [citizenid] = KeyType, _owner = citizenid }
--
-- KeyType: 'owner' | 'shared' | 'temp' | 'hotwired'
--
-- 设计原则:
--   - 所有钥匙操作服务端权威，客户端零信任
--   - 哈希表 O(1) 查询，无 DB 依赖
--   - 临时钥匙下线自动释放
--   - 无持久化——钥匙仅在会话期有效（自有车从 DB 的 player_vehicles 验证）

KeyManager = {}

-- ==============================================================
-- 核心数据结构
-- ==============================================================

---@class VehicleKeyStore
---@field _owner string citizenid 车主
---@field [citizenid] string KeyType

---@type table<string, VehicleKeyStore> plate → KeyStore
KeyManager._keys = {}

-- ==============================================================
-- 内部: 钥匙类型常量
-- ==============================================================

local KEY = Config.Vehicles.KeyTypes

-- ==============================================================
-- 公开 API
-- ==============================================================

--- 授予钥匙
---@param plate string 车牌号
---@param citizenid string 玩家 citizenid
---@param keyType string|nil 钥匙类型 (默认 'owner')
---@return boolean success
function KeyManager.GiveKeys(plate, citizenid, keyType)
    if not plate or not citizenid then return false end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()
    keyType = keyType or KEY.OWNER

    if not KeyManager._keys[plate] then
        KeyManager._keys[plate] = { _owner = citizenid }
    end

    KeyManager._keys[plate][citizenid] = keyType
    return true
end

--- 移除钥匙
---@param plate string 车牌号
---@param citizenid string 玩家 citizenid
---@return boolean success
function KeyManager.RemoveKeys(plate, citizenid)
    if not plate or not citizenid then return false end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()

    local store = KeyManager._keys[plate]
    if not store then return false end

    store[citizenid] = nil

    -- 如果没有任何持钥人，清理整个 store
    local hasKeys = false
    for k, _ in pairs(store) do
        if k ~= '_owner' then
            hasKeys = true
            break
        end
    end
    if not hasKeys then
        KeyManager._keys[plate] = nil
    end

    return true
end

--- 检查玩家是否有指定车辆的钥匙
---@param plate string 车牌号
---@param citizenid string 玩家 citizenid
---@return boolean hasKey
---@return string|nil keyType
function KeyManager.HasKeys(plate, citizenid)
    if not plate or not citizenid then return false, nil end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()

    local store = KeyManager._keys[plate]
    if not store then return false, nil end

    local kt = store[citizenid]
    if kt then return true, kt end

    return false, nil
end

--- 获取车辆所有持钥人
---@param plate string
---@return table<string, string> citizenid → KeyType
function KeyManager.GetKeyHolders(plate)
    if not plate then return {} end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()

    local store = KeyManager._keys[plate]
    if not store then return {} end

    local holders = {}
    for cid, kt in pairs(store) do
        if cid ~= '_owner' then
            holders[cid] = kt
        end
    end
    return holders
end

--- 获取车主
---@param plate string
---@return string|nil citizenid
function KeyManager.GetOwner(plate)
    if not plate then return nil end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()

    local store = KeyManager._keys[plate]
    if not store then return nil end
    return store._owner
end

--- 设置车主
---@param plate string
---@param citizenid string
function KeyManager.SetOwner(plate, citizenid)
    if not plate or not citizenid then return end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()

    if not KeyManager._keys[plate] then
        KeyManager._keys[plate] = { _owner = citizenid }
    else
        KeyManager._keys[plate]._owner = citizenid
    end

    -- 自动给车主 owner 钥匙
    KeyManager._keys[plate][citizenid] = KEY.OWNER
end

--- 授予临时钥匙（任务/租车，下线自动释放）
---@param plate string
---@param citizenid string
---@return boolean success
function KeyManager.GiveTempKeys(plate, citizenid)
    return KeyManager.GiveKeys(plate, citizenid, KEY.TEMP)
end

--- 清除玩家所有临时钥匙（下线时调用）
---@param citizenid string
function KeyManager.ClearTempKeys(citizenid)
    if not citizenid then return end
    local cleared = 0
    for plate, store in pairs(KeyManager._keys) do
        if store[citizenid] == KEY.TEMP then
            store[citizenid] = nil
            cleared = cleared + 1
        end
    end
    return cleared
end

--- 清除玩家所有热线钥匙（超时后调用）
---@param citizenid string
function KeyManager.ClearHotwiredKeys(citizenid)
    if not citizenid then return end
    for plate, store in pairs(KeyManager._keys) do
        if store[citizenid] == KEY.HOTWIRED then
            store[citizenid] = nil
        end
    end
end

--- 获取指定玩家拥有的所有钥匙
---@param citizenid string
---@return table[] { plate, keyType, isOwner }
function KeyManager.GetKeysForCitizen(citizenid)
    if not citizenid then return {} end
    local keys = {}
    for plate, store in pairs(KeyManager._keys) do
        if store[citizenid] then
            keys[#keys + 1] = {
                plate = plate,
                keyType = store[citizenid],
                isOwner = store._owner == citizenid,
            }
        end
    end
    return keys
end

--- 获取统计信息
---@return table
function KeyManager.Stats()
    local vehicleCount = 0
    local totalHolders = 0
    for plate, store in pairs(KeyManager._keys) do
        vehicleCount = vehicleCount + 1
        for cid, _ in pairs(store) do
            if cid ~= '_owner' then
                totalHolders = totalHolders + 1
            end
        end
    end
    return {
        vehicles = vehicleCount,
        total_holders = totalHolders,
    }
end

print('[custom-vehicles] 🔑 KeyManager 已就绪 — O(1) 内存哈希表')
