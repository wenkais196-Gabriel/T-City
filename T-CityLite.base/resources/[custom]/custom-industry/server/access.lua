-- server/access.lua — 组织权限判定的唯一实现。
--
-- S1 的 /orgfund* 与 S2 的 /orgbuild /orghire /orgfacility 共用这一份判定；
-- 不要在命令文件里复制第二份（复制出来的判定迟早会在一个文件里改、另一个没改）。
--
-- 组织与 job/gang 的映射来自 Config.Industry.OrgWhitelist（见 config.lua）。

IndustryAccess = {}

--- 玩家是否属于 orgId，以及在该组织里的职级。
--- 不限职级：离线补产在玩家上线时按「组织成员」触发，不能要求 Boss。
---@param Player table QBCore 玩家对象
---@param orgId string 组织名（例如 mining_co / cartel）
---@return boolean member
---@return number level 0 when not a member
function IndustryAccess.OrgMembership(Player, orgId)
    local def = Config.Industry.OrgWhitelist[orgId]
    if not def or not Player or not Player.PlayerData then return false, 0 end

    local data = Player.PlayerData
    if def.kind == 'job' then
        local job = data.job
        if not job or job.name ~= def.name then return false, 0 end
        return true, tonumber(job.grade and job.grade.level) or 0
    end
    if def.kind == 'gang' then
        local gang = data.gang
        if not gang or gang.name ~= def.name then return false, 0 end
        return true, tonumber(gang.grade and gang.grade.level) or 0
    end

    return false, 0
end

--- 玩家是否属于 orgId 且达到 Grade4。
---@param Player table QBCore 玩家对象
---@param orgId string 组织名（例如 mining_co / cartel）
---@return boolean
function IndustryAccess.IsOrgBoss(Player, orgId)
    local member, level = IndustryAccess.OrgMembership(Player, orgId)
    return member and level >= (Config.Industry.BossGrade or 4)
end
