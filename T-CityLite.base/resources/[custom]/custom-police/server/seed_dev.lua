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
