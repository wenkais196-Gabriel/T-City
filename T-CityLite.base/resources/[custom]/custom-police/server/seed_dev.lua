-- server/seed_dev.lua — 真机验收用的"造数据"后门（默认关、只接受控制台）。
--
-- 为什么需要它：司法链的写入路径（MDT → CreateCase / RegisterArrest）只有玩家在
-- 手机/平板上点才能触发，而自动化没有可靠的输入通道。验收 AC-P1-01/04 要的是
-- "案卷真的落库、重启后还在"，所以给一条能直接调 **同一批导出** 的命令：
-- 它不是第二条写入路径，只是替玩家按了一次按钮。
--
-- 门控：`police_seed_dev_enabled` 默认 0；只接受 source == 0（控制台/RCON）。

RegisterCommand('police_case_seed', function(source, args)
    if source ~= 0 then return end
    if GetConvar('police_seed_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_case_seed 已关闭（setr police_seed_dev_enabled 1 打开）')
        return
    end

    local officerSrc = tonumber(args and args[1])
    local suspectCid = tostring(args and args[2] or '')
    local charges = tostring(args and args[3] or 'robbery')
    if not officerSrc or suspectCid == '' then
        print('[custom-police] 用法: police_case_seed <officerSrc> <suspectCitizenId> [charges]')
        return
    end

    local okCase, caseResult = pcall(function()
        return exports['custom-police']:CreateCase(officerSrc, {
            title = 'SEED 逮捕登记',
            summary = ('由 police_case_seed 生成（charges=%s）'):format(charges),
        })
    end)
    if not okCase or type(caseResult) ~= 'table' or not caseResult.id then
        print(('[custom-police] seed: CreateCase failed (%s)'):format(tostring(caseResult)))
        return
    end

    local okArrest, arrestResult = pcall(function()
        return exports['custom-police']:RegisterArrest(officerSrc, {
            citizenid = suspectCid,
            charges = charges,
            case_id = caseResult.id,
        })
    end)

    print(('[custom-police] seed: case id=%s no=%s arrest=%s'):format(
        tostring(caseResult.id), tostring(caseResult.case_no),
        okArrest and tostring(arrestResult and arrestResult.id or '?') or tostring(arrestResult)))
end, true)

--- 司法链的另一半：走 custom-justice 自己的 registerArrest（律师通知/内存案卷都在那边）。
--- 用法：police_justice_seed <suspectSrc> <officerSrc> <charges>
RegisterCommand('police_justice_seed', function(source, args)
    if source ~= 0 then return end
    if GetConvar('police_seed_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_justice_seed 已关闭（setr police_seed_dev_enabled 1 打开）')
        return
    end
    local suspectSrc = tonumber(args and args[1])
    local officerSrc = tonumber(args and args[2])
    local charges = tostring(args and args[3] or 'robbery')
    if not suspectSrc or not officerSrc then
        print('[custom-police] 用法: police_justice_seed <suspectSrc> <officerSrc> <charges>')
        return
    end
    local crimes = {}
    for id in charges:gmatch('[^,]+') do crimes[#crimes + 1] = id end
    -- 先走 justice 的导出，拿得到 caseId 才是"真的建了案卷"；事件那条只负责通知。
    local suspect = QBCore.Functions.GetPlayer(suspectSrc)
    local suspectCid = suspect and suspect.PlayerData and suspect.PlayerData.citizenid
    local ok, caseId = pcall(function()
        return exports['custom-justice']:OpenCase(suspectCid, officerSrc, crimes)
    end)
    TriggerEvent('justice:server:registerArrest', suspectSrc, crimes, officerSrc)
    print(('[custom-police] justice seed: suspect=%s officer=%s charges=%s openCase=%s (%s)'):format(
        tostring(suspectCid), tostring(officerSrc), charges,
        tostring(ok and caseId or 'error'), tostring(ok and 'ok' or caseId)))
end, true)

--- 判决回写的验证入口：police_verdict_seed <caseId> <guilty|acquitted> [minutes]
--- 走的是司法侧同一条导出（RecordCaseVerdict），不是另一条写库路径。
RegisterCommand('police_verdict_seed', function(source, args)
    if source ~= 0 then return end
    if GetConvar('police_seed_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_verdict_seed 已关闭（setr police_seed_dev_enabled 1 打开）')
        return
    end
    local caseId = tonumber(args and args[1])
    local verdict = tostring(args and args[2] or 'guilty')
    local minutes = tonumber(args and args[3]) or 0
    if not caseId then
        print('[custom-police] 用法: police_verdict_seed <caseId> <guilty|acquitted> [minutes]')
        return
    end
    local ok, result = pcall(function()
        return exports['custom-police']:RecordCaseVerdict(caseId, verdict, minutes)
    end)
    print(('[custom-police] verdict seed: case=%s verdict=%s minutes=%s -> %s'):format(
        tostring(caseId), verdict, tostring(minutes),
        ok and tostring(result and result.affected_rows or '?') or tostring(result)))
end, true)

-- 车机/手机读的是 GetIncidentsPublic（坐标已按 D5 偏移）。
-- 这个命令让控制台能直接看到"客户端会拿到什么"，验证投影与 D5 不需要进游戏。
RegisterCommand('police_incidents_public', function(src, args)
    if src ~= 0 then return end
    if GetConvar('police_seed_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_incidents_public 已关闭（setr police_seed_dev_enabled 1 打开）')
        return
    end
    local target = tonumber(args and args[1]) or 1
    local limit = tonumber(args and args[2]) or 3
    local list = exports['custom-police']:GetIncidentsPublic(target, limit) or {}
    print(('[custom-police] public incidents: %d'):format(#list))
    for _, row in ipairs(list) do
        print(('  #%s %s p%s %s @ %.1f,%.1f'):format(
            tostring(row.id), tostring(row.code), tostring(row.priority),
            tostring(row.status), tonumber(row.x) or 0, tonumber(row.y) or 0))
    end
end, false)

-- 批量造同一 code 的警情：用来验证通知预算层的合并（真机 911 有冷却，连发不了）。
-- 门控同 police_case_seed：police_seed_dev_enabled=1 且只接受控制台。
RegisterCommand('police_incident_seed', function(src, args)
    if src ~= 0 then return end
    if GetConvar('police_seed_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_incident_seed 已关闭（setr police_seed_dev_enabled 1 打开）')
        return
    end
    local code = (args and args[1]) or '10-31'
    local times = math.min(tonumber(args and args[2]) or 1, 10)
    local title = (args and args[3]) or '种子警情'
    local created = 0
    -- 第 4 个参数是 ref：给了 ref 就按 ref 合并（AC-P2-05），坐标怎么漂都合到一张单
    local ref = (args and args[4]) or nil
    -- 第 5–7 个参数可选：x y z。为什么需要它：真机验收（到场判定、世界痕迹）
    -- 必须在**真实地面坐标**上跑 —— 写死 (100…,200,30) 落在山坡虚空里，
    -- 客户端到场检测按垂直距离判（ARRIVE_VERTICAL），z=30 与地面差 70 m 永远不翻 on_scene。
    local seedX = tonumber(args and args[5])
    local seedY = tonumber(args and args[6])
    local seedZ = tonumber(args and args[7])
    local lastId, lastCount, merged = nil, nil, 0
    for i = 1, times do
        local ok, incident = pcall(function()
            -- 没有 ref 时每张单坐标错开 120 m：否则会被 p0 的"同 code + 同地点"合并掉，
            -- 那样测不到通知预算层（那是"多张单、同一个 code"才走的分支）。
            return exports['custom-police']:CreateIncidentFromSystem('seed', {
                code = code,
                title = title,
                ref = ref,
                x = seedX or (ref and (100.0 + i * 15.0) or (100.0 + i * 120.0)),
                y = seedY or 200.0,
                z = seedZ or 30.0,
                priority = 1,
            })
        end)
        if ok and incident then
            created = created + 1
            lastId = incident.id
            lastCount = incident.merge_count
            if incident.merged then merged = merged + 1 end
        end
    end
    print(('[custom-police] police_incident_seed code=%s ref=%s created=%d merged=%d last=%s merge_count=%s'):format(
        tostring(code), tostring(ref or '-'), created, merged, tostring(lastId), tostring(lastCount)))
end, false)

-- AC-P2-10：建单延迟。50 起并存时 P95 要 < 50 ms。
-- 只读计时，不改任何别的东西；用同一个 code 且坐标全散开，避免走合并分支。
RegisterCommand('police_incident_bench', function(src, args)
    if src ~= 0 then return end
    if GetConvar('police_seed_dev_enabled', '0') ~= '1' then
        print('[custom-police] police_incident_bench 已关闭（setr police_seed_dev_enabled 1 打开）')
        return
    end
    local n = math.min(tonumber(args and args[1]) or 50, 200)
    local samples = {}
    for i = 1, n do
        local started = GetGameTimer()
        pcall(function()
            return exports['custom-police']:CreateIncidentFromSystem('bench', {
                code = '10-98', title = ('bench #%d'):format(i),
                x = 500.0 + i * 7.0, y = -800.0 - i * 3.0, z = 30.0, priority = 2,
            })
        end)
        samples[#samples + 1] = GetGameTimer() - started
    end
    table.sort(samples)
    local function pct(p)
        local index = math.max(1, math.ceil(#samples * p))
        return samples[math.min(index, #samples)] or 0
    end
    print(('[custom-police] incident_bench n=%d p50=%dms p95=%dms max=%dms'):format(
        #samples, pct(0.50), pct(0.95), samples[#samples] or 0))
end, false)
