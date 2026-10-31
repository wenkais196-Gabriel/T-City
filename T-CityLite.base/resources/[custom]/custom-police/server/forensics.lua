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
    -- 指纹 / DNA 不靠"阳性阴性"判断，靠比对现场在场的人
    fingerprint = '现场指纹样本',
    dna = '现场 DNA 样本',
}

--- 需要比对而不是化验的类型
local MATCH_KINDS = { fingerprint = true, dna = true }

--- 采样时把 30 m 内在场玩家记成候选（比对只认这些人）。
--- 这不是"猜"：比对结果就是"样本对得上现场某人"。
local function snapshotCandidates(officerSrc)
    local out = {}
    local ped = GetPlayerPed(officerSrc)
    if not ped or ped == 0 then return out end
    local origin = GetEntityCoords(ped)
    for _, src in ipairs(GetPlayers()) do
        local p = tonumber(src)
        local other = GetPlayerPed(p)
        if other and other ~= 0 then
            local Player = QBCore.Functions.GetPlayer(p)
            local cid = Player and Player.PlayerData and Player.PlayerData.citizenid
            if type(cid) == 'string' and cid ~= '' and #(GetEntityCoords(other) - origin) <= 30.0 then
                out[#out + 1] = cid
                if #out >= 10 then break end
            end
        end
    end
    return out
end

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
    if MATCH_KINDS[kind] then return '样本已入库，等待与嫌疑人比对' end
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
    local description = '已送检，约 60 秒出结果'
    if MATCH_KINDS[kind] then
        local candidates = snapshotCandidates(src)
        -- 候选名单就在证据描述里：比对时只认这张名单上的人，不认"警员说的名字"
        description = ('现场候选 %d 人：%s'):format(#candidates, table.concat(candidates, ','))
        if #candidates == 0 then description = '现场候选 0 人（采集时无人靠近）' end
    end
    local sample = exports['custom-police']:RegisterEvidence(src, {
        label = label,
        description = description,
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

--- 指纹 / DNA 比对入口：真正的比对在 p2_evidence（police_evidence 的唯一写者）。
QBCore.Functions.CreateCallback('police:server:compareSample', function(source, cb, evidenceId, citizenid)
    local src = tonumber(source) or 0
    local Player = QBCore.Functions.GetPlayer(src)
    local data = Player and Player.PlayerData
    if not data or not PolicePolicy.Can(data, 'evidence.register') then
        cb({ ok = false, reason = 'off_duty' }); return
    end
    if not data.job or data.job.onduty ~= true then
        cb({ ok = false, reason = 'off_duty' }); return
    end
    local ok, result, why = pcall(function()
        return exports['custom-police']:CompareSample(src, evidenceId, citizenid)
    end)
    if not ok then cb({ ok = false, reason = 'compare_failed' }); return end
    if type(result) ~= 'table' then cb({ ok = false, reason = tostring(why or 'compare_failed') }); return end
    if not audit(data.citizenid, 'forensic.compare', tostring(evidenceId),
            result.match and ('match:' .. tostring(citizenid)) or 'no_match') then
        cb({ ok = false, reason = 'audit_unavailable' }); return
    end
    cb({ ok = true, match = result.match == true, subject_citizenid = result.subject_citizenid })
end)
