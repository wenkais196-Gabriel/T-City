-- server/apps/police_mdt.lua — first registry app (police only).
-- The app stays visible off duty so a 10-7 officer can open the MDT and go
-- 10-8 again; every query/action still re-authorises through PolicePolicy.
local function core()
    if type(_G.QBCore) == 'table' then return _G.QBCore end
    local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(value) == 'table' then _G.QBCore = value return value end
    return nil
end

local function onDutyPolice()
    local qb = core()
    local result = {}
    if not qb then return result end
    for _, source in ipairs(qb.Functions.GetPlayers()) do
        local Player = qb.Functions.GetPlayer(source)
        local data = Player and Player.PlayerData
        if data and type(data.job) == 'table' and data.job.name == 'police' and data.job.onduty == true then
            local info = type(data.charinfo) == 'table' and data.charinfo or {}
            result[#result + 1] = {
                source = source,
                citizenid = data.citizenid,
                name = ('%s %s'):format(tostring(info.firstname or '?'), tostring(info.lastname or '?')),
                grade = type(data.job.grade) == 'table' and tonumber(data.job.grade.level) or 0,
            }
        end
    end
    table.sort(result, function(a, b) return tostring(a.citizenid) < tostring(b.citizenid) end)
    return result
end

-- Action results are normalised here instead of being collapsed to a boolean.
-- custom-police owns the business decision; this layer only flattens its
-- `true` / `false, code` / `{ ok, error }` shapes into the stable contract used
-- by `PhoneApps.Action`, which turns { ok = false, error } into
-- success=false/error for the MDT. `unknown_capability` is an internal policy
-- table bug, so it is folded into the user-facing `forbidden` code.
local function errorCode(value)
    if type(value) ~= 'string' or value == '' then return 'rejected' end
    if value == 'unknown_capability' then return 'forbidden' end
    return value
end

---@param name string action name, for the server log
---@param fn function export call returning true | false, code | table
---@return table { ok = true, ... } | { ok = false, error = code, detail? }
local function structured(name, fn)
    local ok, res, reason, detail = pcall(fn)
    if not ok then
        print(('[custom-phone][apps] police_mdt %s export failed: %s'):format(name, tostring(res)))
        return { ok = false, error = 'export_error' }
    end
    if res == true then return { ok = true } end
    if res == false or res == nil then
        local result = { ok = false, error = errorCode(reason) }
        if detail ~= nil then result.detail = tostring(detail) end
        return result
    end
    if type(res) == 'table' then
        if res.ok == false then
            res.error = errorCode(res.error)
            return res
        end
        if res.ok == nil then res.ok = true end
        return res
    end
    return { ok = true, data = res }
end

PhoneApps.Register({
    id = 'police_mdt',
    label = 'MDT',
    icon = '🛡️',
    audience = { jobs = { 'police' } },
    queries = {
        -- Identity of the caller for the "Me" page. The audit section is
        -- rendered from this grade (Lieutenant+ = grade >= 3).
        me = function(source)
            local qb = core()
            local Player = qb and qb.Functions and qb.Functions.GetPlayer(source)
            local data = Player and Player.PlayerData
            if type(data) ~= 'table' then return { rows = {}, count = 0 } end
            local job = type(data.job) == 'table' and data.job or {}
            local grade = 0
            if type(job.grade) == 'table' then grade = tonumber(job.grade.level) or 0
            else grade = tonumber(job.grade) or 0 end
            local metadata = type(data.metadata) == 'table' and data.metadata or {}
            local status = (job.onduty == true) and 'available' or 'off_duty'
            local okUnits, unitRes = pcall(function() return exports['custom-police']:GetUnits(source) end)
            if okUnits and type(unitRes) == 'table' then
                for _, unit in ipairs(unitRes.units or {}) do
                    if unit.citizenid == data.citizenid then status = unit.status break end
                end
            end
            return {
                rows = { {
                    citizenid = data.citizenid,
                    callsign = tostring(metadata.callsign or ''),
                    grade = grade,
                    status = status,
                } },
                count = 1,
            }
        end,
        units = function(source)
            local ok, res = pcall(function() return exports['custom-police']:GetUnits(source) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.units or {}, count = res.count or 0 }
        end,
        incidents = function(source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:GetIncidents(source, params and params.status)
            end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.incidents or {}, count = res.count or 0 }
        end,
        -- P6-4 草稿箱：agent 解析出的 call 卡（status='draft'），服务端已做 TTL 与审计
        drafts = function(source)
            local ok, res = pcall(function() return exports['custom-police']:ListDrafts(source) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        citizen = function(_source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:LookupCitizen(_source, params and params.citizenid)
            end)
            if not ok or type(res) ~= 'table' or res == false then
                return { rows = {}, count = 0 }
            end
            return { rows = { res }, count = 1 }
        end,
        vehicle = function(_source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:LookupVehicle(_source, params and params.plate)
            end)
            if not ok or type(res) ~= 'table' or res == false then
                return { rows = {}, count = 0 }
            end
            return { rows = { res }, count = 1 }
        end,
        citations = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetCitations(source, params) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        reports = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetReports(source, params) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        evidence = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetEvidence(source, params) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        case_detail = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetCaseDetail(source, params and params.case_id) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = { res }, count = 1 }
        end,
        cases = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetCases(source, params) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        bolos = function(source)
            local ok, res = pcall(function() return exports['custom-police']:GetBolos(source) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        warrants = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetWarrants(source, params) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        -- P3-3：把"刚才盘过谁"带进逮捕表单
        last_inspection = function(source)
            local ok, res = pcall(function() return exports['custom-police']:GetLastInspection(source) end)
            if not ok or type(res) ~= 'table' then return { empty = true } end
            return res
        end,
        arrests = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:GetArrests(source, params) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        charges = function(_source)
            local ok, res = pcall(function() return exports['custom-police']:GetCharges() end)
            if not ok or type(res) ~= 'table' or type(res.charges) ~= 'table' then
                return { rows = {}, count = 0 }
            end
            return { rows = res.charges, count = #res.charges }
        end,
        evidence_chain = function(source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:GetEvidenceChain(source, params and params.evidence_id)
            end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        audit = function(source)
            local ok, res = pcall(function() return exports['custom-police']:GetAudit(source) end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.rows or {}, count = res.count or 0 }
        end,
        officers = function(_source)
            local rows = {}
            for _, officer in ipairs(onDutyPolice()) do
                rows[#rows + 1] = {
                    name = officer.name,
                    grade = officer.grade,
                    citizenid = officer.citizenid,
                }
            end
            return { rows = rows, count = #rows, updated_at = os.time() }
        end,
    },
    actions = {
        set_status = function(source, params)
            return structured('set_status', function()
                return exports['custom-police']:SetUnitStatusForSource(source, params.status)
            end)
        end,
        adopt_draft = function(source, params)
            return structured('adopt_draft', function()
                return exports['custom-police']:AdoptDraft(source, params.incident_id)
            end)
        end,
        discard_draft = function(source, params)
            return structured('discard_draft', function()
                return exports['custom-police']:DiscardDraft(source, params.incident_id)
            end)
        end,
        assign = function(source, params)
            return structured('assign', function()
                return exports['custom-police']:AssignUnit(source, params.incident_id, params.citizenid)
            end)
        end,
        -- 申领：assign + enroute + 推路线，一步到位（服务端唯一入口）
        claim = function(source, params)
            return structured('claim', function()
                return exports['custom-police']:ClaimIncident(source, params.incident_id)
            end)
        end,
        -- 自动检测失灵时的人工补录：服务端仍按 ped 坐标校验（宽容 100m）
        arrive_manual = function(source, params)
            return structured('arrive_manual', function()
                return exports['custom-police']:ArriveIncident(
                    source, params.incident_id, nil, { manual = true })
            end)
        end,
        enroute = function(source, params)
            return structured('enroute', function()
                return exports['custom-police']:SetIncidentStatus(source, params.incident_id, 'enroute')
            end)
        end,
        on_scene = function(source, params)
            return structured('on_scene', function()
                return exports['custom-police']:SetIncidentStatus(source, params.incident_id, 'on_scene')
            end)
        end,
        clear = function(source, params)
            return structured('clear', function()
                return exports['custom-police']:SetIncidentStatus(
                    source, params.incident_id, params.status or 'cleared')
            end)
        end,

        -- No export backs the alert: the MDT fans it out to every on-duty
        -- officer through the phone's own Notify export. Empty text is a local
        -- validation failure, not a permission decision.
        alert = function(source, params)
            return structured('alert', function()
                local message = type(params.message) == 'string' and params.message:sub(1, 200) or ''
                if not message:match('%S') then return false, 'invalid_message' end
                local qb = core()
                local sender = qb and qb.Functions.GetPlayer(source)
                local senderName = 'Dispatch'
                if sender and type(sender.PlayerData.charinfo) == 'table' then
                    local info = sender.PlayerData.charinfo
                    senderName = ('%s %s'):format(tostring(info.firstname or ''), tostring(info.lastname or ''))
                end
                local title = ('MDT Alert — %s'):format(senderName:sub(1, 40))
                local sent = 0
                for _, officer in ipairs(onDutyPolice()) do
                    -- Same-resource owner export: persistence + push + app_id
                    -- allowlist live in server/main.lua (FIT-02). `source` skips
                    -- the citizenid lookup because the officer is online here.
                    local called, delivered = pcall(function()
                        return exports['custom-phone']:Notify(officer.citizenid, title, message, nil, {
                            source = officer.source,
                        })
                    end)
                    if called and delivered then sent = sent + 1 end
                end
                return { ok = true, sent = sent }
            end)
        end,

        issue_citation = function(source, params)
            return structured('issue_citation', function()
                return exports['custom-police']:IssueCitation(source, params)
            end)
        end,
        create_report = function(source, params)
            return structured('create_report', function()
                return exports['custom-police']:CreateReport(source, params)
            end)
        end,
        register_evidence = function(source, params)
            return structured('register_evidence', function()
                return exports['custom-police']:RegisterEvidence(source, params)
            end)
        end,
        create_case = function(source, params)
            return structured('create_case', function()
                return exports['custom-police']:CreateCase(source, params)
            end)
        end,
        create_bolo = function(source, params)
            return structured('create_bolo', function()
                return exports['custom-police']:CreateBolo(source, params)
            end)
        end,
        request_warrant = function(source, params)
            return structured('request_warrant', function()
                return exports['custom-police']:RequestWarrant(source, params)
            end)
        end,
        decide_warrant = function(source, params)
            return structured('decide_warrant', function()
                return exports['custom-police']:DecideWarrant(source, params)
            end)
        end,
        register_arrest = function(source, params)
            return structured('register_arrest', function()
                return exports['custom-police']:RegisterArrest(source, params)
            end)
        end,

        -- params (including idempotency_key) is forwarded untouched; the
        -- police resource owns key validation and the replay cache.
        arrest_submit = function(source, params)
            return structured('arrest_submit', function()
                return exports['custom-police']:ArrestSubmit(source, params)
            end)
        end,

        -- Same pass-through as arrest_submit: idempotency_key reaches the
        -- server so a retried report does not create a second row.
        report_submit = function(source, params)
            return structured('report_submit', function()
                return exports['custom-police']:ReportSubmit(source, params)
            end)
        end,

        -- Server-authoritative NPC backup: custom-police owns the permission,
        -- cooldown, two-unit cap and audit; the phone only forwards the result.
        request_backup = function(source, params)
            -- params.tier：1 = 一辆车，2 = 两辆车（响应级别）。不给就用服务端 convar。
            local tier = type(params) == 'table' and tonumber(params.tier) or nil
            return structured('request_backup', function()
                return exports['custom-police']:RequestBackup(source, tier)
            end)
        end,
    },
})

print('[custom-phone][apps] registered police_mdt')
