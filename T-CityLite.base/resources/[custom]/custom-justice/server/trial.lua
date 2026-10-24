-- trial.lua — 审判系统: 法官开庭 / 认罪协议 → 量刑

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 通知 / 鉴权小工具
-- ==============================================================

--- 发客户端通知。优先复用 production-freeze 的 _L 词条；新词条尚未写入
--- locale 时退回到 fallback，避免把 "[judge_online]" 这种 key 直接甩给玩家。
local function notify(src, key, kind, fallback, ...)
    local text
    if _L then
        text = _L(src, key, ...)
        if text == ('[%s]'):format(key) then text = nil end
    end
    TriggerClientEvent('QBCore:Notify', src, text or fallback or key, kind or 'primary')
end

local function notifyResolveError(src, err)
    if err == 'case_closed' then
        notify(src, 'justice_case_closed', 'error')
    else
        notify(src, 'justice_case_not_found', 'error')
    end
end

--- 把判决回写到关联的警情报告（police_reports.justice_case_id）。
--- 尽力而为：编码或 DB 失败只打印警告，不影响内存判决与入狱流程。
local function persistVerdict(caseId, verdict, status)
    local ok, encoded = pcall(json.encode, verdict)
    if not ok or type(encoded) ~= 'string' then
        print(('[justice-trial] ⚠️ 判决编码失败，跳过回写: %s'):format(tostring(caseId)))
        return
    end
    -- RegisterCommand callbacks are not guaranteed to be yieldable, so the
    -- await runs in its own thread: the caller never waits on the DB and a
    -- failure can only warn.
    CreateThread(function()
        local wrote, result = pcall(function()
            return MySQL.update.await(
                'UPDATE police_reports SET justice_verdict = ?, justice_status = ? WHERE justice_case_id = ?',
                { encoded, status, tostring(caseId) })
        end)
        if not wrote then
            print(('[justice-trial] ⚠️ 判决回写失败 (%s): %s'):format(tostring(caseId), tostring(result)))
        end
    end)
end

--- 用 QBCore.Functions.GetPlayers() + 每个玩家的 job 判断当前是否有在线法官。
local function hasOnlineJudge()
    local players = QBCore.Functions.GetPlayers()
    for i = 1, #players do
        local Player = QBCore.Functions.GetPlayer(players[i])
        if Player and Player.PlayerData.job and Player.PlayerData.job.name == 'judge' then
            return true
        end
    end
    return false
end

--- 法官开庭后的通知（沿用原审判文案）。ResolveCase 本身不发通知，由命令层调用。
local function announceTrialVerdict(caseId, verdict, judgeSrc)
    local case = JusticeService.GetCase(caseId)
    if not case then return end

    -- 通知嫌疑人判决结果
    if case.suspect and case.suspect.src and GetPlayerPing(case.suspect.src) >= 0 then
        TriggerClientEvent('justice:client:verdictReceived', case.suspect.src, verdict)
    end

    -- 通知律师
    for _, lawyer in ipairs(case.lawyers or {}) do
        if GetPlayerPing(lawyer.src) >= 0 then
            notify(lawyer.src, 'justice_verdict_lawyer', 'primary', nil,
                caseId, verdict.finalMinutes, verdict.baseMinutes,
                verdict.lawyerReduction + verdict.firstOffenseReduction)
        end
    end

    -- 通知法官
    notify(judgeSrc, 'justice_verdict_judge', 'success', nil,
        case.suspect.name, verdict.finalMinutes, verdict.fine)

    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('审判判决',
            ('案件 %s | %s → %d分钟 (原始%d) | 法官: %s | 律师: %s'):format(
                caseId, case.suspect.name, verdict.finalMinutes, verdict.baseMinutes,
                GetPlayerName(judgeSrc), verdict.hasLawyer and '是' or '否'))
    end
end

--- 认罪协议后的通知：只通知操作警员与嫌疑人。
local function announcePleaVerdict(caseId, verdict, officerSrc)
    local case = JusticeService.GetCase(caseId)
    if not case then return end

    if case.suspect and case.suspect.src and GetPlayerPing(case.suspect.src) >= 0 then
        TriggerClientEvent('justice:client:verdictReceived', case.suspect.src, verdict)
    end

    -- 复用法官判决文案：对警员展示嫌疑人、刑期与罚款。
    notify(officerSrc, 'justice_verdict_judge', 'success', nil,
        case.suspect.name, verdict.finalMinutes, verdict.fine)

    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('认罪协议',
            ('案件 %s | %s → %d分钟 (基准%d, 60%%) | 警官: %s'):format(
                caseId, case.suspect.name, verdict.finalMinutes, verdict.baseMinutes,
                GetPlayerName(officerSrc)))
    end
end

-- ==============================================================
-- 统一量刑入口: ResolveCase
-- ==============================================================
-- mode='trial': 律师辩护 -30%、初犯 -20%、最低 5 分钟（保持原有行为）
-- mode='plea' : 不适用律师/初犯减免，final = max(5, floor(base * 0.6))
-- 本函数只计算、落库（内存案件）、送监；客户端通知由命令层负责。
---@param caseId string
---@param opts table { mode='trial'|'plea', actorSrc=number, judgeName=string }
---@return table|nil verdict, string|nil error
function JusticeService.ResolveCase(caseId, opts)
    opts = type(opts) == 'table' and opts or {}
    local mode = opts.mode
    if mode ~= 'trial' and mode ~= 'plea' then return nil, 'invalid_mode' end

    local case = JusticeService.GetCase(caseId)
    if not case then return nil, 'case_not_found' end
    if case.status == 'sentenced' or case.status == 'closed' then
        return nil, 'case_closed'
    end

    -- 基础刑期 / 罚款 / 罪名标签
    local baseMinutes = 0
    local baseFine = 0
    local crimeLabels = {}
    for _, crimeId in ipairs(case.crimes) do
        local crime = Config.Justice.Crimes[crimeId]
        if crime then
            baseMinutes = baseMinutes + crime.baseMinutes
            baseFine = baseFine + crime.fine
            crimeLabels[#crimeLabels + 1] = crime.label
        end
    end

    local hasLawyer = #case.lawyers > 0
    local lawyerReduction = 0
    local firstOffenseReduction = 0
    local finalMinutes

    if mode == 'plea' then
        -- 认罪协议：无律师/初犯减免，直接按基准刑期的 60% 量刑。
        finalMinutes = math.max(5, math.floor(baseMinutes * 0.6))
    else
        if hasLawyer then
            lawyerReduction = math.floor(baseMinutes * Config.Justice.Reductions.lawyer_defense.rate)
        end
        firstOffenseReduction = math.floor(baseMinutes * Config.Justice.Reductions.first_offense.rate)
        finalMinutes = math.max(5, baseMinutes - lawyerReduction - firstOffenseReduction)
    end

    local judgeName = opts.judgeName
    if not judgeName and opts.actorSrc then
        judgeName = GetPlayerName(opts.actorSrc)
    end
    if not judgeName then judgeName = 'System' end

    local verdict = {
        caseId = caseId,
        suspectName = case.suspect.name,
        judgeName = judgeName,
        crimeLabels = crimeLabels,
        baseMinutes = baseMinutes,
        lawyerReduction = lawyerReduction,
        firstOffenseReduction = firstOffenseReduction,
        finalMinutes = finalMinutes,
        fine = baseFine,
        hasLawyer = hasLawyer,
        mode = mode,
    }

    -- 记录判决（SetVerdict 会把状态置为 sentenced），随后关闭案件。
    JusticeService.SetVerdict(caseId, verdict)

    -- 入狱/改判由服务端执行（嫌疑人客户端无权调用 imprison）。判决覆盖
    -- 当前剩余刑期（set），而不是在过去剩余刑期上追加。
    if case.suspect.citizenid then
        JusticeService.Imprison(case.suspect.citizenid, finalMinutes, case.crimes, {
            replace = true,
            caseId = caseId,
            reason = ('判决: %s'):format(table.concat(crimeLabels, ',')),
            createdBy = opts.actorCitizenid,
        })
    end

    case.status = 'closed'

    -- justice cases live in memory only; mirror the verdict onto the linked
    -- police report so the MDT can still show it after the case is gone.
    -- Best effort and placed after the sentence, so a DB failure cannot alter
    -- the in-memory verdict or the jail time.
    persistVerdict(caseId, verdict, case.status)
    return verdict
end

-- ==============================================================
-- 事件: 法官开庭审判（兼容旧客户端调用）
-- ==============================================================

RegisterNetEvent('justice:server:startTrial', function(caseId)
    local src = source
    local Judge = QBCore.Functions.GetPlayer(src)
    if not Judge or Judge.PlayerData.job.name ~= 'judge' then
        notify(src, 'justice_judge_only', 'error')
        return
    end

    local verdict, err = JusticeService.ResolveCase(caseId, {
        mode = 'trial',
        actorSrc = src,
        judgeName = GetPlayerName(src),
    })
    if not verdict then
        notifyResolveError(src, err)
        return
    end

    announceTrialVerdict(caseId, verdict, src)
end)

-- ==============================================================
-- 命令: /trial <caseId> — 仅法官
-- ==============================================================

QBCore.Commands.Add('trial', '开庭审判案件 (法官)', {
    { name = 'caseId', help = '案件ID' },
}, true, function(source, args)
    local src = source
    local Judge = QBCore.Functions.GetPlayer(src)
    if not Judge or Judge.PlayerData.job.name ~= 'judge' then
        notify(src, 'justice_judge_only', 'error')
        return
    end

    local caseId = args and args[1] and tostring(args[1]) or ''
    local verdict, err = JusticeService.ResolveCase(caseId, {
        mode = 'trial',
        actorSrc = src,
        judgeName = GetPlayerName(src),
    })
    if not verdict then
        notifyResolveError(src, err)
        return
    end

    announceTrialVerdict(caseId, verdict, src)
end, 'user')

-- ==============================================================
-- 命令: /plea <caseId> — 仅 police grade>=2，且当前无在线法官
-- ==============================================================

QBCore.Commands.Add('plea', '认罪协议 (无在线法官时，警察 grade 2+)', {
    { name = 'caseId', help = '案件ID' },
}, true, function(source, args)
    local src = source
    local Officer = QBCore.Functions.GetPlayer(src)
    if not Officer then return end

    local job = Officer.PlayerData.job
    local grade = tonumber(job and job.grade and job.grade.level) or 0
    if not job or job.name ~= 'police' or grade < 2 then
        notify(src, 'justice_police_only', 'error',
            '认罪协议需要警察警佐（grade 2）及以上')
        return
    end

    -- 有法官在线时必须走 /trial，警察不能代替法官结案。
    if hasOnlineJudge() then
        notify(src, 'judge_online', 'error', '有法官在线，不能使用认罪协议')
        return
    end

    local caseId = args and args[1] and tostring(args[1]) or ''
    local verdict, err = JusticeService.ResolveCase(caseId, {
        mode = 'plea',
        actorSrc = src,
        judgeName = GetPlayerName(src),
    })
    if not verdict then
        notifyResolveError(src, err)
        return
    end

    announcePleaVerdict(caseId, verdict, src)
end, 'user')

-- ==============================================================
-- 命令: 法官/律师查看案件列表
-- ==============================================================
QBCore.Commands.Add('cases', '查看待审案件 (法官/律师)', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local job = Player.PlayerData.job.name
    if job ~= 'judge' and job ~= 'lawyer' then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_lawyer_judge_only'), 'error')
        return
    end

    local cases = JusticeService.GetActiveCases()
    local pendingCount = 0
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 215, 0 },
        args = { _L(source, 'justice_pending_cases'), '' }
    })

    for caseId, case in pairs(cases) do
        if case.status ~= 'closed' then
            pendingCount = pendingCount + 1
            local crimeLabels = {}
            for _, cid in ipairs(case.crimes) do
                local crime = Config.Justice.Crimes[cid]
                if crime then crimeLabels[#crimeLabels + 1] = crime.label end
            end
            TriggerClientEvent('chat:addMessage', source, {
                color = { 200, 200, 200 },
                args = { '  ', ('%s | %s | Charges: %s | Lawyer: %s'):format(
                    caseId, case.suspect.name,
                    table.concat(crimeLabels, ','),
                    #case.lawyers > 0 and _L(source, 'justice_assigned') or _L(source, 'justice_pending')) }
            })
        end
    end

    if pendingCount == 0 then
        TriggerClientEvent('QBCore:Notify', source, _L(source, 'justice_no_pending'), 'primary')
    end
end, 'user')

print('[justice-trial] 👨‍⚖️  审判系统已加载')
