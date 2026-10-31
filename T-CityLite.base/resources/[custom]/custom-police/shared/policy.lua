-- shared/policy.lua — one capability table for every police-side permission.
-- Job + onduty are necessary but not sufficient: rank gates are checked here,
-- server-side, and every caller must go through PolicePolicy.Can.
-- 警情自动结算的几何/时间参数。**客户端检测与服务端裁定共用这一份**：
-- 客户端按 ARRIVE_RADIUS 触发，服务端按 SERVER_RADIUS_GRACE 复算，
-- 两边写死各自的数字就等于给作弊开了口子（客户端改半径就能隔街"到场"）。
PoliceIncidentRules = {
    ARRIVE_RADIUS = 30.0,        -- 客户端触发半径（米，3D）
    ARRIVE_VERTICAL = 15.0,      -- 垂直容差（楼顶/高架/地下车库不误判）
    SERVER_RADIUS_GRACE = 35.0,  -- 服务端复算宽容（1 tick 的位置差）
    MANUAL_RADIUS = 100.0,       -- 手动补录的宽容（自动检测失灵时的出口）
    RESET_MULTIPLIER = 1.5,      -- 离开 45 米才重置（滞回，边界不抖动）
    DWELL_TICKS = 2,             -- 连续命中 2 次才算（开车路过不算）
    ARRIVE_MAX_SPEED = 2.0,      -- 到场时速度上限（m/s）：开过去不算到场（AC-P2-04）
    POLL_INTERVAL = 1000,        -- 轮询间隔（毫秒，与任务 checkpoint 一致）
    NONCE_TTL_MS = 30000,        -- 到场 nonce 有效期
}

PolicePolicy = {}

local CAPS = {
    ['units.view']      = { minGrade = 1 },
    ['incident.create'] = { minGrade = 0 },
    ['incident.assign'] = { minGrade = 2 },
    ['incident.update'] = { minGrade = 1 },
    ['incident.claim']  = { minGrade = 1 },
    ['incident.arrive'] = { minGrade = 1 },
    ['incident.clear']  = { minGrade = 1 },
    ['lookup.citizen']  = { minGrade = 1 },
    ['lookup.vehicle']  = { minGrade = 1 },
    ['citation.issue']  = { minGrade = 1 },
    ['citation.view']   = { minGrade = 1 },
    ['report.create']   = { minGrade = 1 },
    ['report.view']     = { minGrade = 1 },
    ['evidence.register'] = { minGrade = 1 },
    ['evidence.view']     = { minGrade = 1 },
    ['case.create']       = { minGrade = 2 },
    ['case.view']         = { minGrade = 1 },
    ['bolo.create']       = { minGrade = 2 },
    ['bolo.view']         = { minGrade = 1 },
    ['warrant.request']   = { minGrade = 2 },
    ['warrant.approve']   = { minGrade = 3 },
    ['warrant.view']      = { minGrade = 1 },
    ['arrest.create']     = { minGrade = 1 },
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
