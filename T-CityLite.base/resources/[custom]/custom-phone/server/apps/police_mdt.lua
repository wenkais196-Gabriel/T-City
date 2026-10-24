-- server/apps/police_mdt.lua — first registry app (police only, on duty).
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

PhoneApps.Register({
    id = 'police_mdt',
    label = 'MDT',
    icon = '🛡️',
    audience = { jobs = { 'police' }, onduty = true },
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
            local okUnits, unitRes = pcall(function() return exports['custom-police']:GetUnits() end)
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
        units = function(_source)
            local ok, res = pcall(function() return exports['custom-police']:GetUnits() end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.units or {}, count = res.count or 0 }
        end,
        incidents = function(_source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:GetIncidents(params and params.status)
            end)
            if not ok or type(res) ~= 'table' then return { rows = {}, count = 0 } end
            return { rows = res.incidents or {}, count = res.count or 0 }
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
            local ok, res = pcall(function()
                return exports['custom-police']:SetUnitStatusForSource(source, params.status)
            end)
            return ok and res == true
        end,
        assign = function(source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:AssignUnit(source, params.incident_id, params.citizenid)
            end)
            return ok and res ~= false
        end,
        create_case = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:CreateCase(source, params) end)
            return ok and res ~= false
        end,
        create_bolo = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:CreateBolo(source, params) end)
            return ok and res ~= false
        end,
        request_warrant = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:RequestWarrant(source, params) end)
            return ok and res ~= false
        end,
        decide_warrant = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:DecideWarrant(source, params) end)
            return ok and res ~= false
        end,
        register_arrest = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:RegisterArrest(source, params) end)
            return ok and res ~= false
        end,
        arrest_submit = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:ArrestSubmit(source, params) end)
            if not ok or type(res) ~= 'table' or res.ok ~= true then return false end
            return res
        end,
        report_submit = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:ReportSubmit(source, params) end)
            if not ok or type(res) ~= 'table' then return false end
            return res
        end,
        -- Server-authoritative NPC backup: custom-police owns the permission,
        -- cooldown, two-unit cap and audit; the phone only forwards the result.
        -- Rejections ({ ok = false, error = ... }) are passed through so the
        -- MDT can localise cooldown/limit/not_police instead of "action_failed".
        request_backup = function(source, _params)
            local ok, res = pcall(function() return exports['custom-police']:RequestBackup(source) end)
            if not ok or type(res) ~= 'table' then return false end
            return res
        end,
        register_evidence = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:RegisterEvidence(source, params) end)
            return ok and res ~= false
        end,
        issue_citation = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:IssueCitation(source, params) end)
            return ok and res ~= false
        end,
        create_report = function(source, params)
            local ok, res = pcall(function() return exports['custom-police']:CreateReport(source, params) end)
            return ok and res ~= false
        end,
        enroute = function(source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:SetIncidentStatus(source, params.incident_id, 'enroute')
            end)
            return ok and res ~= false
        end,
        on_scene = function(source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:SetIncidentStatus(source, params.incident_id, 'on_scene')
            end)
            return ok and res ~= false
        end,
        clear = function(source, params)
            local ok, res = pcall(function()
                return exports['custom-police']:SetIncidentStatus(source, params.incident_id, params.status or 'cleared')
            end)
            return ok and res ~= false
        end,
        alert = function(source, params)
            local message = type(params.message) == 'string' and params.message:sub(1, 200) or ''
            if not message:match('%S') then return false end
            local sender = core().Functions.GetPlayer(source)
            local senderName = 'Dispatch'
            if sender and type(sender.PlayerData.charinfo) == 'table' then
                local info = sender.PlayerData.charinfo
                senderName = ('%s %s'):format(tostring(info.firstname or ''), tostring(info.lastname or ''))
            end
            local title = ('MDT Alert — %s'):format(senderName:sub(1, 40))
            local sent = 0
            for _, officer in ipairs(onDutyPolice()) do
                MySQL.Async.insert(
                    'INSERT INTO phone_notifications (citizenid, title, content) VALUES (?, ?, ?)',
                    { officer.citizenid, title:sub(1, 200), message },
                    function() end
                )
                TriggerClientEvent('phone:client:newNotification', officer.source, {
                    id = 0,
                    title = title:sub(1, 200),
                    content = message,
                    timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                    is_read = false,
                })
                sent = sent + 1
            end
            return { sent = sent }
        end,
    },
})

print('[custom-phone][apps] registered police_mdt')
