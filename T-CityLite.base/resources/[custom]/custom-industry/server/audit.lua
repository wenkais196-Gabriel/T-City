-- server/audit.lua — 组织金库操作审计。
--
-- 只写 citizenid（actor_cid）、金额、动作与结果码；payload 里不放姓名、车牌、
-- 坐标、聊天内容等 PII。审计失败**不**回滚业务：钱已经按 Treasury 的规则落地，
-- 这里只负责留痕；写不进去时打印一行，避免把成功交易误报成失败。

IndustryAudit = {}

local MAX_ORG_LEN = 64
local MAX_ACTION_LEN = 48
local MAX_ACTOR_LEN = 64

--- payload 只允许数字与白名单字符，避免手工拼 JSON 时被调用方注入。
---@return string json
function IndustryAudit.Payload(amount, result, ref)
    local safeResult = tostring(result or 'unknown'):gsub('[^%w_%-%.]', '_')
    local safeRef = tostring(ref or ''):gsub('[^%w:_%-%.]', '_')
    local value = tonumber(amount) or 0
    -- JSON 里要的是数字，不是展示串：整数 tostring 成 "1000"，小数成 "1.5"，
    -- 两者都是合法 JSON；这里不做金额格式化（唯一实现是 core-framework 的 FormatMoney）。
    return ('{"amount":%s,"result":"%s","ref":"%s"}'):format(
        tostring(value), safeResult, safeRef)
end

---@param orgId string
---@param actorCid string|nil 控制台操作为 nil
---@param action string 例如 fund.deposit / fund.withdraw / fund.grant
---@param payload string 由 Payload() 生成
---@return boolean ok
function IndustryAudit.Write(orgId, actorCid, action, payload)
    if type(orgId) ~= 'string' or orgId == '' or #orgId > MAX_ORG_LEN then return false end
    if type(action) ~= 'string' or action == '' or #action > MAX_ACTION_LEN then return false end
    if actorCid ~= nil and (type(actorCid) ~= 'string' or #actorCid > MAX_ACTOR_LEN) then
        actorCid = nil
    end
    if type(payload) ~= 'string' or payload == '' then payload = '{}' end

    local id, err
    if actorCid then
        id, err = Db.Insert(
            'INSERT INTO industry_audit (org_id, actor_cid, action, payload) VALUES (?, ?, ?, ?)',
            { orgId, actorCid, action, payload })
    else
        id, err = Db.Insert(
            'INSERT INTO industry_audit (org_id, actor_cid, action, payload) VALUES (?, NULL, ?, ?)',
            { orgId, action, payload })
    end

    if id or err == 'no_insert_id' then return true end
    print(('[custom-industry] audit write failed org=%s action=%s err=%s'):format(
        orgId, action, tostring(err)))
    return false
end
