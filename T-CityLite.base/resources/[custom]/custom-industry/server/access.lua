-- server/access.lua — 组织权限判定的唯一实现。
--
-- S1 的 /orgfund* 与 S2 的 /orgbuild /orghire /orgfacility 共用这一份判定；
-- 不要在命令文件里复制第二份（复制出来的判定迟早会在一个文件里改、另一个没改）。
--
-- 组织与 job/gang 的映射来自 Config.Industry.OrgWhitelist（见 config.lua）。

IndustryAccess = {}

--- 玩家是否属于 orgId 且达到 Grade4。
---@param Player table QBCore 玩家对象
---@param orgId string 组织名（例如 mining_co / cartel）
---@return boolean
function IndustryAccess.IsOrgBoss(Player, orgId)
    local def = Config.Industry.OrgWhitelist[orgId]
    if not def then return false end

    local data = Player.PlayerData
    local level = 0
    if def.kind == 'job' then
        local job = data.job
        if not job or job.name ~= def.name then return false end
        level = tonumber(job.grade and job.grade.level) or 0
    elseif def.kind == 'gang' then
        local gang = data.gang
        if not gang or gang.name ~= def.name then return false end
        level = tonumber(gang.grade and gang.grade.level) or 0
    else
        return false
    end

    return level >= (Config.Industry.BossGrade or 4)
end
