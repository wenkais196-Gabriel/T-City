-- shared/policy.lua — one capability table for every police-side permission.
-- Job + onduty are necessary but not sufficient: rank gates are checked here,
-- server-side, and every caller must go through PolicePolicy.Can.
PolicePolicy = {}

local CAPS = {
    ['units.view']      = { minGrade = 1 },
    ['incident.create'] = { minGrade = 0 },
    ['incident.assign'] = { minGrade = 2 },
    ['incident.update'] = { minGrade = 1 },
    ['lookup.citizen']  = { minGrade = 1 },
    ['lookup.vehicle']  = { minGrade = 1 },
    ['audit.view']      = { minGrade = 3 },
}

function PolicePolicy.Grade(data)
    local grade = data and data.job and data.job.grade
    return type(grade) == 'table' and tonumber(grade.level) or 0
end

function PolicePolicy.IsPolice(data)
    return data ~= nil and type(data.job) == 'table' and data.job.name == 'police'
end

---@return boolean ok, string|nil reason
function PolicePolicy.Can(data, capability)
    if not PolicePolicy.IsPolice(data) then return false, 'not_police' end
    if data.job.onduty ~= true then return false, 'not_on_duty' end
    local rule = CAPS[capability]
    if not rule then return false, 'unknown_capability' end
    if PolicePolicy.Grade(data) < rule.minGrade then return false, 'rank_too_low' end
    return true, nil
end

function PolicePolicy.Capabilities()
    local list = {}
    for name, rule in pairs(CAPS) do list[#list + 1] = { name = name, minGrade = rule.minGrade } end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

return PolicePolicy
