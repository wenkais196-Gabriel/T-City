-- server/org_id.lua — 组织 id 的唯一校验。
--
-- S1–S4 各自拷过一份 `local function validOrg` + `MAX_ORG_LEN` + `ORG_PATTERN`（共 4 份，
-- 连常量都一样），复用预算闸门（test_reuse_budget）因此变红。S4 合并到这里。
--
-- 规则：非空、≤64 字符、只允许 字母/数字/下划线/连字符。

IndustryOrgId = {
    MaxLength = 64,
    Pattern = '^[%w_%-]+$',
}

---@param orgId any
---@return boolean
function IndustryOrgId.IsValid(orgId)
    return type(orgId) == 'string'
        and #orgId > 0
        and #orgId <= IndustryOrgId.MaxLength
        and orgId:match(IndustryOrgId.Pattern) ~= nil
end
