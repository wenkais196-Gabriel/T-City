-- ============================================================================
-- MetadataService — 内存优先元数据操作层
-- ============================================================================
-- 职责:
--   1. 所有玩家 metadata 读写 100% 在内存中完成
--   2. 绝不直接同步 SQL 写入 — 只标记 IsDirty=true 交由 PersistenceManager
--   3. hunger/thirst 高频豁免: 不触发 IsDirty，仅 ForceFlush/PlayerDropped 时落盘
--   4. qualifications (资质) 独立读写接口 — 三位一体第三维度的数据载体
--
-- 调用方式:
--   MetadataService.Set(citizenid, key, value)
--   MetadataService.Get(citizenid, key)
--   MetadataService.HasQualification(citizenid, qual)
-- ============================================================================

local MetadataService = {}

-- ── 内部辅助 ──────────────────────────────────────────────────────────

---高频豁免字段列表 — 这些字段的写入不触发 IsDirty，减少无效 SQL
local HIGH_FREQUENCY_EXEMPT = {
    hunger = true,
    thirst = true,
    stress = true,
    health = true,  -- health 在 Save() 中有独立处理
}

---通过 citizenid 查找在线玩家对象
local function getPlayerByCitizenId(citizenid)
    if not citizenid then return nil end
    for _, player in pairs(QBCore.Players) do
        if player.PlayerData and player.PlayerData.citizenid == citizenid then
            return player
        end
    end
    return nil
end

-- ── 公开 API: 通用元数据 ─────────────────────────────────────────────

---设置单个元数据字段
---@param citizenid string
---@param key string
---@param value any
---@return boolean success
function MetadataService.Set(citizenid, key, value)
    if not citizenid or not key or type(key) ~= 'string' then
        return false
    end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local metadata = player.PlayerData.metadata
    if not metadata then return false end

    -- hunger/thirst 边界钳制
    if key == 'hunger' or key == 'thirst' then
        value = tonumber(value) or 0
        if value > 100 then value = 100 end
        if value < 0 then value = 0 end
    end

    metadata[key] = value

    -- 高频豁免字段不标记 IsDirty
    if not HIGH_FREQUENCY_EXEMPT[key] then
        player.IsDirty = true
    end

    -- 更新客户端
    player.Functions.UpdatePlayerData()

    return true
end

---读取单个元数据字段
---@param citizenid string
---@param key string
---@return any|nil
function MetadataService.Get(citizenid, key)
    if not citizenid or not key or type(key) ~= 'string' then
        return nil
    end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return nil end

    local metadata = player.PlayerData.metadata
    if not metadata then return nil end

    return metadata[key]
end

---批量设置元数据 (用于初始加载或批量更新)
---@param citizenid string
---@param tbl table 键值对表
---@return boolean success
function MetadataService.BatchSet(citizenid, tbl)
    if not citizenid or type(tbl) ~= 'table' then
        return false
    end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local metadata = player.PlayerData.metadata
    if not metadata then return false end

    local hasNonExemptChange = false

    for key, value in pairs(tbl) do
        if key == 'hunger' or key == 'thirst' then
            value = tonumber(value) or 0
            if value > 100 then value = 100 end
            if value < 0 then value = 0 end
        end
        metadata[key] = value
        if not HIGH_FREQUENCY_EXEMPT[key] then
            hasNonExemptChange = true
        end
    end

    if hasNonExemptChange then
        player.IsDirty = true
    end

    player.Functions.UpdatePlayerData()
    return true
end

-- ── 公开 API: 资质 (Qualifications) — 三位一体第三维度 ──────────────

---检查玩家是否拥有某项资质
---@param citizenid string
---@param qualification string 资质标识 (如 'police_heli_pilot')
---@return boolean
function MetadataService.HasQualification(citizenid, qualification)
    if not citizenid or not qualification then return false end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local metadata = player.PlayerData.metadata
    if not metadata then return false end

    -- qualifications 存储在 metadata.qualifications[qual] = true
    local quals = metadata.qualifications
    if not quals or type(quals) ~= 'table' then
        return false
    end

    return quals[qualification] == true
end

---授予资质
---@param citizenid string
---@param qualification string
---@return boolean success
function MetadataService.GrantQualification(citizenid, qualification)
    if not citizenid or not qualification then return false end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local metadata = player.PlayerData.metadata
    if not metadata then return false end

    -- 确保 qualifications 表存在
    if not metadata.qualifications or type(metadata.qualifications) ~= 'table' then
        metadata.qualifications = {}
    end

    if metadata.qualifications[qualification] then
        return true -- 已拥有，幂等成功
    end

    metadata.qualifications[qualification] = true
    player.IsDirty = true
    player.Functions.UpdatePlayerData()

    -- 触发资质变更事件
    TriggerEvent('QBCore:Server:OnQualificationChange', player.PlayerData.source, qualification, 'grant')

    return true
end

---撤销资质
---@param citizenid string
---@param qualification string
---@return boolean success
function MetadataService.RevokeQualification(citizenid, qualification)
    if not citizenid or not qualification then return false end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return false end

    local metadata = player.PlayerData.metadata
    if not metadata then return false end

    if not metadata.qualifications or type(metadata.qualifications) ~= 'table' then
        return false
    end

    if not metadata.qualifications[qualification] then
        return false -- 不拥有
    end

    metadata.qualifications[qualification] = nil
    player.IsDirty = true
    player.Functions.UpdatePlayerData()

    -- 触发资质变更事件
    TriggerEvent('QBCore:Server:OnQualificationChange', player.PlayerData.source, qualification, 'revoke')

    return true
end

---获取玩家全部资质列表
---@param citizenid string
---@return table {[qual] = true, ...}
function MetadataService.GetQualifications(citizenid)
    if not citizenid then return {} end

    local player = getPlayerByCitizenId(citizenid)
    if not player then return {} end

    local metadata = player.PlayerData.metadata
    if not metadata or not metadata.qualifications then
        return {}
    end

    return metadata.qualifications
end

---获取拥有某项资质的所有在线玩家
---@param qualification string
---@return table {source_id, ...}
function MetadataService.GetPlayersByQualification(qualification)
    local players = {}
    if not qualification then return players end

    for src, player in pairs(QBCore.Players) do
        local metadata = player.PlayerData and player.PlayerData.metadata
        if metadata and metadata.qualifications and metadata.qualifications[qualification] then
            players[#players + 1] = src
        end
    end

    return players
end

-- ── 自注册 ────────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if not _G.Bus then _G.Bus = {} end
        _G.Bus.MetadataService = MetadataService
        print('[MetadataService] Registered to _G.Bus.MetadataService')
    end
end)

if not _G.Bus then _G.Bus = {} end
_G.Bus.MetadataService = MetadataService
