-- client/forensics.lua — /sample <gsr|drug|blood> <caseId>
--
-- 现场采样：把"这片血迹/这枪开过没"变成案卷里的证据行。
-- 归属/权限/化验延迟全在 server/forensics.lua。

local KINDS = { gsr = true, drug = true, blood = true }

RegisterCommand('sample', function(_, args)
    local kind = tostring(args and args[1] or ''):lower()
    local caseId = tonumber(args and args[2])
    if not KINDS[kind] or not caseId then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('用法：/sample gsr|drug|blood <案卷ID>')
        EndTextCommandThefeedPostTicker(false, true)
        return
    end
    TriggerServerEvent('police:server:forensicSample', kind, caseId)
end, false)
