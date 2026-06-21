-- ============================================================================
-- QualificationService — 资质系统 (三位一体第三维度)
-- ============================================================================
-- 核心设计原则:
--   "资质只认标签，不认组织" — 资质是跨阵营的专业技术通行证
--
-- 示例逻辑:
--   警用飞行员 = [职业: police] + [组织等级: 基层] + [资质: police_heli_pilot]
--   黑市神医   = [职业: none]   + [组织等级: 无]   + [资质: advanced_surgery]
--
-- 判定规则:
--   - HasQual 只看 metadata.qualifications 表，不看 job 或 gang
--   - GrantQual/RevokeQual 走 SecurityService 校验
--   - 资质定义从 QBCore.Config.Qualifications 读取
-- ============================================================================

local QualificationService = {}

-- ── 公开 API ──────────────────────────────────────────────────────────

---检查玩家是否拥有某项资质 (不看职业、不看等级 — 只看标签)
---@param Player table QBCore Player 对象 (非 citizenid)
---@param qualification string 资质标识
---@return boolean
function QualificationService.HasQual(Player, qualification)
    if not Player or not Player.PlayerData then return false end
    if not qualification then return false end

    local metadata = Player.PlayerData.metadata
    if not metadata then return false end

    local quals = metadata.qualifications
    if not quals or type(quals) ~= 'table' then
        return false
    end

    return quals[qualification] == true
end

---检查玩家是否拥有给定列表中任意一项资质
---@param Player table
---@param qualifications table 资质标识数组
---@return boolean
function QualificationService.HasAnyQual(Player, qualifications)
    if not Player or not qualifications then return false end
    for _, qual in ipairs(qualifications) do
        if QualificationService.HasQual(Player, qual) then
            return true
        end
    end
    return false
end

---检查玩家是否拥有给定列表中全部资质
---@param Player table
---@param qualifications table 资质标识数组
---@return boolean
function QualificationService.HasAllQuals(Player, qualifications)
    if not Player or not qualifications then return false end
    for _, qual in ipairs(qualifications) do
        if not QualificationService.HasQual(Player, qual) then
            return false
        end
    end
    return true
end

---授予资质 (经 SecurityService 校验)
---@param source number 操作者 source (管理员/系统)
---@param targetCitizenId string 目标玩家 citizenid
---@param qualification string 资质标识
---@return boolean success, string|nil errorReason
function QualificationService.GrantQual(source, targetCitizenId, qualification)
    -- SecurityService 校验
    if Bus and Bus.SecurityService then
        local ok, cleanedQual = Bus.SecurityService.ValidateQualificationEvent(
            source, qualification, 'grant'
        )
        if not ok then
            return false, 'security_validation_failed'
        end
        qualification = cleanedQual
    end

    -- 资质必须在配置表中定义
    if QBCore.Config.Qualifications and not QBCore.Config.Qualifications[qualification] then
        return false, 'qualification_not_defined'
    end

    -- 委托 MetadataService 执行实际写入
    local success = Bus.MetadataService.GrantQualification(targetCitizenId, qualification)
    if not success then
        return false, 'player_not_found'
    end

    return true, nil
end

---撤销资质 (经 SecurityService 校验)
---@param source number 操作者 source
---@param targetCitizenId string 目标玩家 citizenid
---@param qualification string 资质标识
---@return boolean success, string|nil errorReason
function QualificationService.RevokeQual(source, targetCitizenId, qualification)
    -- SecurityService 校验
    if Bus and Bus.SecurityService then
        local ok, cleanedQual = Bus.SecurityService.ValidateQualificationEvent(
            source, qualification, 'revoke'
        )
        if not ok then
            return false, 'security_validation_failed'
        end
        qualification = cleanedQual
    end

    local success = Bus.MetadataService.RevokeQualification(targetCitizenId, qualification)
    if not success then
        return false, 'player_not_found_or_qual_not_held'
    end

    return true, nil
end

---获取玩家全部资质列表 (带标签信息)
---@param Player table QBCore Player 对象
---@return table { {id, label, category}, ... }
function QualificationService.GetQuals(Player)
    local result = {}
    if not Player or not Player.PlayerData then return result end

    local metadata = Player.PlayerData.metadata
    if not metadata or not metadata.qualifications then return result end

    local configQuals = QBCore.Config.Qualifications or {}

    for qualId, _ in pairs(metadata.qualifications) do
        local def = configQuals[qualId]
        result[#result + 1] = {
            id = qualId,
            label = def and def.label or qualId,
            category = def and def.category or 'uncategorized',
        }
    end

    return result
end

---获取某个分类下玩家拥有的全部资质
---@param Player table
---@param category string 分类名 (如 'aviation', 'medical', 'weapon', 'vehicle')
---@return table { {id, label}, ... }
function QualificationService.GetQualsByCategory(Player, category)
    local allQuals = QualificationService.GetQuals(Player)
    local result = {}
    for _, qual in ipairs(allQuals) do
        if qual.category == category then
            result[#result + 1] = qual
        end
    end
    return result
end

---获取拥有某项资质的所有在线玩家 source 列表
---@param qualification string
---@return table {source_id, ...}
function QualificationService.GetPlayersWithQual(qualification)
    return Bus.MetadataService.GetPlayersByQualification(qualification)
end

---获取与某项技能兼容的职业列表 (用于 UI 提示: "拥有此资质可加入以下职业")
---@param qualification string
---@return table { {job, label}, ... }
function QualificationService.GetCompatibleJobs(qualification)
    local result = {}
    local configQuals = QBCore.Config.Qualifications or {}
    local def = configQuals[qualification]

    if def and def.compatibleJobs then
        for _, jobName in ipairs(def.compatibleJobs) do
            local jobInfo = QBCore.Shared.Jobs[jobName]
            result[#result + 1] = {
                job = jobName,
                label = jobInfo and jobInfo.label or jobName,
            }
        end
    end

    return result
end

-- ── 批量评估: 三位一体 AND 逻辑 ────────────────────────────────────

---完整的三位一体判定: 检查玩家是否满足 [职业 AND 等级 AND 资质] 组合条件
---@param Player table
---@param jobName string|nil 需要的职业 (nil = 不限)
---@param minRank number|nil 最低组织等级 (nil = 不限)
---@param qualifications table|nil 需要的资质列表 (nil = 不限)
---@return boolean, string|nil failReason
function QualificationService.EvaluateTrinityAccess(Player, jobName, minRank, qualifications)
    if not Player or not Player.PlayerData then
        return false, 'invalid_player'
    end

    local playerData = Player.PlayerData

    -- 维度 1: 职业
    if jobName and playerData.job.name ~= jobName then
        return false, 'wrong_job'
    end

    -- 维度 2: 组织等级
    if minRank and playerData.job.grade.level < minRank then
        return false, 'insufficient_rank'
    end

    -- 维度 3: 资质
    if qualifications then
        if type(qualifications) == 'table' and #qualifications > 0 then
            if not QualificationService.HasAllQuals(Player, qualifications) then
                return false, 'missing_qualification'
            end
        end
    end

    return true, nil
end

-- ── 自注册 ────────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if not _G.Bus then _G.Bus = {} end
        _G.Bus.QualificationService = QualificationService
        print('[QualificationService] Registered to _G.Bus.QualificationService')
    end
end)

if not _G.Bus then _G.Bus = {} end
_G.Bus.QualificationService = QualificationService
