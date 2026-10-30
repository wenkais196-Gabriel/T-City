-- server/records.lua — police_cases / police_arrests / police_reports 的唯一写者
--
-- 收口前这三张表的写入点散在 p1（报告）、p2_system（案卷 + 报告 + 逮捕）、p3_cases（案卷 + 逮捕 + 判决）：
--
--   police_cases     p2.L854 INSERT + UPDATE case_no   |  p3.L49 INSERT + UPDATE case_no（几行一模一样）
--   police_arrests   p2.Sys.Jail 三列                  |  p3.RegisterArrest 五列（同一张表两种列集合）
--   police_reports   p1 五列 | p2 十四列（逮捕）| p2 十二列（报告）| p3 只 UPDATE 判决字段
--
-- 共同隐患是**参数数组在中间出现 nil**：`{ incidentId, caseId, actor.citizenid, ... }` 里
-- caseId 多半是 nil，oxmysql 在洞处截断 → 参数少于占位符 → MariaDB 报语法错 →
-- InsertId() 拿到错误字符串 → 调用方返回 db_error。也就是说"不带案卷建报告"这条路是坏的
-- （与审计、证据登记同一个 bug 家族，见 server/audit.lua 与 server/p2_evidence.lua 的头注释）。
--
-- 所以这里：列集合按需拼接，不存在的字段写 SQL 的 NULL 或干脆不出现，参数数组永不留洞。
-- 审计仍留在调用方（不同入口记的 action/detail 不同）；这里只管行。

PoliceRecords = PoliceRecords or {}

local MAX_TITLE = 120
local MAX_SUMMARY = 1000
local MAX_BODY = 2000
local MAX_CHARGES = 500
local MAX_TEXT = 120

local function trim(value)
    return type(value) == 'string' and value:match('^%s*(.-)%s*$') or ''
end

local function clip(value, limit)
    local text = trim(value)
    if text == '' then return nil end
    return text:sub(1, limit)
end

local function insertRow(sql, values)
    local ok, result = pcall(function() return MySQL.insert.await(sql, values) end)
    if not ok or type(result) == 'string' then
        if not ok then
            print(('[custom-police] records insert failed: %s'):format(tostring(result):sub(1, 160)))
        end
        return nil
    end
    local id = InsertId(result)
    return (id and id > 0) and tonumber(id) or nil
end

--- 按需拼接的 INSERT。`head` 必须是字面量（例如 'INSERT INTO police_arrests'）：
--- 架构闸门按字面量找"谁在写这张表"，表名只以变量形式出现的话扫描器完全看不见。
--- `fields` 是 { column, value } 列表，nil 值一律跳过。
local function insertInto(head, fields)
    local columns, placeholders, values = {}, {}, {}
    for _, pair in ipairs(fields) do
        local column, value = pair[1], pair[2]
        if value ~= nil then
            columns[#columns + 1] = column
            placeholders[#placeholders + 1] = '?'
            values[#values + 1] = value
        end
    end
    local sql = ('%s (%s) VALUES (%s)'):format(
        head, table.concat(columns, ', '), table.concat(placeholders, ', '))
    return insertRow(sql, values)
end

--- 建案卷（展品号式的 case_no 依赖自增 id，插入后补写）。
---@param actorCid string
---@param params table { title, summary?, lead_citizenid? }
---@return number|nil id, string|nil case_no, string|nil reason
function PoliceRecords.InsertCase(actorCid, params)
    if type(params) ~= 'table' then return nil, nil, 'invalid_params' end
    local title = clip(params.title, MAX_TITLE)
    if not title or #title < 3 then return nil, nil, 'invalid_title' end

    local id = insertInto('INSERT INTO police_cases', {
        { 'title', title },
        { 'summary', clip(params.summary, MAX_SUMMARY) },
        { 'lead_citizenid', clip(params.lead_citizenid, 50) },
        { 'created_by', actorCid },
    })
    if not id then return nil, nil, 'db_error' end

    local number = ('CASE-%s-%06d'):format(os.date('%Y'), id)
    local ok = pcall(function()
        return MySQL.update.await('UPDATE police_cases SET case_no = ? WHERE id = ?', { number, id })
    end)
    if not ok then
        print(('[custom-police] case_no write failed for #%s'):format(tostring(id)))
    end
    return id, number
end

--- 登记一次逮捕。`incident_id`/`case_id` 只在提供时出现。
---@param officerCid string
---@param params table { citizenid, charges, incident_id?, case_id? }
---@return number|nil id, string|nil reason
function PoliceRecords.InsertArrest(officerCid, params)
    if type(params) ~= 'table' then return nil, 'invalid_params' end
    local target = clip(params.citizenid, 50)
    if not target then return nil, 'invalid_citizen' end
    local charges = clip(params.charges, MAX_CHARGES)
    if not charges or #charges < 3 then return nil, 'invalid_charges' end

    local id = insertInto('INSERT INTO police_arrests', {
        { 'citizenid', target },
        { 'officer_citizenid', officerCid },
        { 'charges', charges },
        { 'incident_id', tonumber(params.incident_id) },
        { 'case_id', tonumber(params.case_id) },
    })
    if not id then return nil, 'db_error' end
    return id
end

--- 写一条报告（逮捕/普通报告共用；kind 决定语义，status 由调用方给）。
---@param actorCid string
---@param params table 见下方字段列表
---@return number|nil id, string|nil reason
function PoliceRecords.InsertReport(actorCid, params)
    if type(params) ~= 'table' then return nil, 'invalid_params' end
    local title = clip(params.title, MAX_TITLE)
    if not title or #title < 3 then return nil, 'invalid_title' end

    local id = insertInto('INSERT INTO police_reports', {
        { 'title', title },
        { 'body', clip(params.body, MAX_BODY) },
        { 'author_citizenid', actorCid },
        { 'officer_citizenid', clip(params.officer_citizenid, 50) or actorCid },
        { 'kind', clip(params.kind, 20) },
        { 'status', clip(params.status, 20) },
        { 'incident_id', tonumber(params.incident_id) },
        { 'case_id', tonumber(params.case_id) },
        { 'subject_citizenid', clip(params.subject_citizenid, 50) },
        { 'location', clip(params.location, MAX_TEXT) },
        { 'charges', clip(params.charges, MAX_CHARGES) },
        { 'is_bolo', params.is_bolo },
        { 'bolo_kind', clip(params.bolo_kind, 40) },
        { 'bolo_target', clip(params.bolo_target, 64) },
    })
    if not id then return nil, 'db_error' end
    return id
end

--- 把报告挂到案卷 / 司法案子上。
---@param reportId number
---@param params table { case_id?, justice_case_id? }
---@return boolean ok
function PoliceRecords.LinkReport(reportId, params)
    local id = tonumber(reportId)
    if not id or type(params) ~= 'table' then return false end

    local sets, values = {}, {}
    local caseId = tonumber(params.case_id)
    -- justice_case_id 可能是字符串（custom-justice 的 "CASE-0001"），原样传；case_id 是数字列
    local justiceId = params.justice_case_id
    if caseId then
        sets[#sets + 1] = 'case_id = ?'
        values[#values + 1] = caseId
    end
    if justiceId then
        sets[#sets + 1] = 'justice_case_id = ?'
        values[#values + 1] = justiceId
    end
    if #sets == 0 then return false end
    values[#values + 1] = id

    local ok, result = pcall(function()
        return MySQL.update.await(
            ('UPDATE police_reports SET %s WHERE id = ?'):format(table.concat(sets, ', ')), values)
    end)
    return ok and type(result) ~= 'string'
end

--- 把判决写到案卷本身（court_status + sentence_minutes）。
--- 与 `RecordVerdict`（按 justice_case_id 更报告）互补：报告可能不存在，案卷一定在。
---@param caseId number|string
---@param courtStatus string
---@param minutes number|nil
---@return boolean ok, number affectedRows
function PoliceRecords.RecordCaseVerdict(caseId, courtStatus, minutes)
    local id = tonumber(caseId)
    if not id then return false, 0 end
    local status = type(courtStatus) == 'string' and courtStatus:sub(1, 24) or ''
    if status == '' then return false, 0 end
    local minutesValue = tonumber(minutes)
    if minutesValue then
        minutesValue = math.max(0, math.floor(minutesValue))
    end
    local ok, result = pcall(function()
        return MySQL.update.await(
            'UPDATE police_cases SET court_status = ?, sentence_minutes = ? WHERE id = ?',
            { status, minutesValue, id })
    end)
    if not ok or type(result) == 'string' then return false, 0 end
    if type(result) == 'table' then
        return true, tonumber(result.affectedRows) or tonumber(result.affected_rows) or 0
    end
    return true, tonumber(result) or 0
end

--- 记录司法判决（只更新判决字段，不动报告正文）。
---@param justiceCaseId number
---@param verdict string
---@param status string
---@return boolean ok, number affectedRows
function PoliceRecords.RecordVerdict(justiceCaseId, verdict, status)
    -- justice_case_id 是 VARCHAR(32)：字符串 "CASE-0001" 与数字都要原样传
    local id = tostring(justiceCaseId or '')
    if id == '' then return false, 0 end
    local ok, result = pcall(function()
        return MySQL.update.await(
            'UPDATE police_reports SET justice_verdict = ?, justice_status = ? WHERE justice_case_id = ?',
            { verdict, status, id })
    end)
    if not ok or type(result) == 'string' then return false, 0 end
    if type(result) == 'table' then
        return true, tonumber(result.affectedRows) or tonumber(result.affected_rows) or 0
    end
    return true, tonumber(result) or 0
end
