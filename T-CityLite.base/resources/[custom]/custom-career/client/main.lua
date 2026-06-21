-- client/main.lua — custom-career 客户端

local function GetPlayerIdentity()
    return LocalPlayer.state.career_identity
end
exports('GetPlayerIdentity', GetPlayerIdentity)

AddStateBagChangeHandler('career_identity', ('player:%s'):format(GetPlayerServerId()),
    function(bagName, key, value, reserved, replicated)
        if value then
            TriggerEvent('custom-career:client:IdentityUpdated', value)
        end
    end)

-- /mycareer 客户端快捷显示
-- ⚠️ 生产环境 enableDebugLogs 为 false，杜绝 F8 信息泄露
local enableClientDebug = GetConvar('debug_client', 'false') == 'true'
local function ClientDebugPrint(msg, ...)
    if enableClientDebug then
        print(string.format('^5[DEBUG:career]^7 %s', ... and string.format(msg, ...) or msg))
    end
end

RegisterCommand('mycareer', function()
    local id = GetPlayerIdentity()
    if not id then
        ClientDebugPrint('身份信息未加载')
        return
    end
    ClientDebugPrint('职业: %s | 组织: %s | 等级: %s | 阶层: %s',
        id.job_label, id.org_label, id.job_grade_name, id.rank_tier)
    if id.gang_name then
        ClientDebugPrint('帮派: %s [%s] 等级: %s', id.gang_label, id.gang_name, id.gang_grade_name)
    end
end, false)
