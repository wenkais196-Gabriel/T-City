-- server/forensics.lua — L2 后勤：现场化验（蓝图 §6.2「法医采样」）。
--
-- 设计取舍（很关键）：**不做 UPDATE**。采样立刻写一条证据行（"已送检"），
-- 60 秒后再写**第二条**（"结果：阳性/阴性"）。两份都是 append-only 的证据，
-- 时间线天然可读，也不需要给 police_evidence 加列或改 schema。
--
-- 证据必须挂在案卷上（owner 的插入校验要求 case_id/incident_id/report_id 之一），
-- 所以这里要求调用方带 caseId —— 故意的：没有案卷的"化验"没有意义。

local KIND_LABEL = {
    gsr = '枪击残留（GSR）采样',
    drug = '毒品快检采样',
    blood = '血迹采样',
}

local COOLDOWN_SECONDS = 20
local LAB_DELAY_MS = 60000
local cooldown = {}   -- [cid] = os.time()

local function audit(cid, action, target, detail)
    if type(PoliceAudit) ~= 'table' then return false end
    local ok, result = pcall(function()
        return PoliceAudit.Write(cid, action, target, detail)
    end)
    if not ok or not result then
        print(('[custom-police] forensic audit failed: %s (%s)'):format(tostring(action), tostring(target)))
        return false
    end
    return true
end

--- 化验结果：GSR/毒品是阳性/阴性，血迹是"待比对"。
local function labResult(kind)
    if kind == 'blood' then return '样本已入库，DNA 待比对' end
    return (math.random() < 0.5) and '阳性' or '阴性'
end

RegisterNetEvent('police:server:forensicSample', function(kind, caseId)
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'evidence.register') then return end
    if not data.job or data.job.onduty ~= true then return end
    if type(kind) ~= 'string' or not KIND_LABEL[kind] then return end
    local case = tonumber(caseId)
    if not case then return end

    local cid = type(data.citizenid) == 'string' and data.citizenid or ''
    if cid == '' then return end
    if os.time() - (cooldown[cid] or 0) < COOLDOWN_SECONDS then return end
    cooldown[cid] = os.time()

    local label = KIND_LABEL[kind]
    local sample = exports['custom-police']:RegisterEvidence(src, {
        label = label,
        description = '已送检，约 60 秒出结果',
        case_id = case,
    })
    if type(sample) ~= 'table' or not sample.exhibit_no then
        TriggerClientEvent('QBCore:Notify', src, '采样入卷失败', 'error')
        return
    end
    if not audit(cid, 'forensic.sample', sample.exhibit_no, label) then
        print(('[custom-police] forensic.sample audit failed: %s'):format(tostring(sample.exhibit_no)))
    end

    SetTimeout(LAB_DELAY_MS, function()
        -- 警官可能已经下线：那就只写审计，不硬塞一条没有主人的证据。
        local still = QBCore.Functions.GetPlayer(src)
        if not still or not still.PlayerData or still.PlayerData.citizenid ~= cid then
            if not audit(cid, 'forensic.result_skipped', sample.exhibit_no, 'officer_offline') then
                print('[custom-police] forensic.result_skipped audit failed')
            end
            return
        end
        local result = labResult(kind)
        local row = exports['custom-police']:RegisterEvidence(src, {
            label = ('%s · 结果'):format(label),
            description = ('%s（样本 %s）'):format(result, tostring(sample.exhibit_no)),
            case_id = case,
        })
        if type(row) == 'table' and row.exhibit_no then
            if not audit(cid, 'forensic.result', row.exhibit_no, result) then
                print(('[custom-police] forensic.result audit failed: %s'):format(tostring(row.exhibit_no)))
            end
            TriggerClientEvent('QBCore:Notify', src, ('化验结果：%s'):format(result), 'primary')
        else
            if not audit(cid, 'forensic.result_failed', sample.exhibit_no, 'db') then
                print('[custom-police] forensic.result_failed audit failed')
            end
        end
    end)
end)
